defmodule SpectreMnemonic.Persistence.FramedLog do
  @moduledoc false

  require Logger

  alias SpectreMnemonic.Persistence.Store.FileFrame

  @type sync_mode :: :always | :data | :none
  @counter_table :mnemonic_framed_log_counters

  @spec recover_tail(Path.t(), keyword()) ::
          {:ok, FileFrame.scan_result()} | {:error, term()}
  def recover_tail(path, opts \\ []) do
    scan_opts = Keyword.take(opts, [:magic, :version])

    with {:ok, scan} <- FileFrame.scan_path(path, scan_opts) do
      case scan.status do
        :clean ->
          {:ok, scan}

        {:invalid_tail, reason} when reason in [:incomplete_header, :incomplete_payload] ->
          repair_torn_tail(path, scan, opts)

        {:invalid_tail, reason} ->
          {:error,
           {:corrupt_framed_log,
            %{path: path, offset: scan.valid_bytes, reason: reason, file_bytes: scan.file_bytes}}}
      end
    end
  end

  @spec append(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def append(path, bytes, opts \\ []) do
    existed? = File.exists?(path)

    with {:ok, mode} <- sync_mode(opts),
         {:ok, io} <- File.open(path, [:append, :binary, :raw]) do
      write_result = write_and_sync(io, bytes, mode)
      close_result = File.close(io)
      finish_append(path, mode, existed?, write_result, close_result)
    end
  end

  @spec finish_append(
          Path.t(),
          sync_mode(),
          boolean(),
          :ok | {:error, term()},
          :ok | {:error, term()}
        ) :: :ok | {:error, term()}
  defp finish_append(path, mode, existed?, write_result, close_result) do
    with :ok <- prefer_operation_error(write_result, close_result) do
      if existed?, do: :ok, else: sync_directory(Path.dirname(path), mode)
    end
  end

  @spec write_file(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write_file(path, bytes, opts \\ []) do
    with {:ok, mode} <- sync_mode(opts),
         {:ok, io} <- File.open(path, [:write, :binary, :raw]) do
      write_result = write_and_sync(io, bytes, mode)
      close_result = File.close(io)

      with :ok <- prefer_operation_error(write_result, close_result) do
        sync_directory(Path.dirname(path), mode)
      end
    end
  end

  @spec rename(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def rename(source, destination, opts \\ []) do
    with {:ok, mode} <- sync_mode(opts),
         :ok <- File.rename(source, destination),
         :ok <- sync_directory(Path.dirname(destination), mode) do
      source_directory = Path.dirname(source)

      if source_directory == Path.dirname(destination),
        do: :ok,
        else: sync_directory(source_directory, mode)
    end
  end

  @spec remove(Path.t(), keyword()) :: :ok | {:error, term()}
  def remove(path, opts \\ []) do
    with {:ok, mode} <- sync_mode(opts) do
      case File.rm(path) do
        :ok -> sync_directory(Path.dirname(path), mode)
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec sync_file(Path.t(), keyword()) :: :ok | {:error, term()}
  def sync_file(path, opts \\ []) do
    with {:ok, mode} <- sync_mode(opts),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      sync_result = sync_io(io, mode)
      close_result = File.close(io)
      prefer_operation_error(sync_result, close_result)
    end
  end

  @spec sync_mode(keyword()) :: {:ok, sync_mode()} | {:error, term()}
  def sync_mode(opts) do
    configured =
      Keyword.get_lazy(opts, :sync, fn ->
        Application.get_env(:spectre_mnemonic, :persistence_sync, :always)
      end)

    case configured do
      :always -> {:ok, :always}
      true -> {:ok, :always}
      :data -> {:ok, :data}
      :none -> {:ok, :none}
      false -> {:ok, :none}
      invalid -> {:error, {:invalid_sync_mode, invalid}}
    end
  end

  @spec sequence_counter(term(), Path.t(), keyword()) ::
          {:ok, :atomics.atomics_ref()} | {:error, term()}
  def sequence_counter(key, path, opts \\ []) do
    ensure_counter_table()

    case take_legacy_sequence(key) do
      {:ok, minimum_sequence} ->
        recover_and_install_counter(key, path, opts, minimum_sequence)

      :missing ->
        case :ets.lookup(@counter_table, key) do
          [{^key, counter}] ->
            ensure_counter_matches_file(key, path, counter, opts)

          [] ->
            recover_and_install_counter(key, path, opts, 0)
        end
    end
  end

  @doc false
  @spec reset_sequence_counter(term()) :: :ok
  def reset_sequence_counter(key) do
    ensure_counter_table()
    :ets.delete(@counter_table, key)
    :persistent_term.erase(key)
    :ok
  end

  @spec advance_offset(:atomics.atomics_ref(), non_neg_integer()) :: :ok
  def advance_offset(counter, bytes) when is_integer(bytes) and bytes >= 0 do
    :atomics.add(counter, 2, bytes)
    :ok
  end

  @spec repair_torn_tail(Path.t(), FileFrame.scan_result(), keyword()) ::
          {:ok, FileFrame.scan_result()} | {:error, term()}
  defp repair_torn_tail(path, scan, opts) do
    with {:ok, mode} <- sync_mode(opts),
         {:ok, io} <- File.open(path, [:read, :write, :binary, :raw]) do
      repair_result = truncate_and_sync(io, scan.valid_bytes, mode)
      close_result = File.close(io)

      with :ok <- prefer_operation_error(repair_result, close_result),
           :ok <- sync_directory(Path.dirname(path), mode) do
        Logger.warning(
          "repaired torn framed-log tail path=#{inspect(path)} " <>
            "removed_bytes=#{scan.file_bytes - scan.valid_bytes} " <>
            "reason=#{inspect(elem(scan.status, 1))}"
        )

        {:ok, %{scan | file_bytes: scan.valid_bytes, status: :clean}}
      end
    end
  end

  @spec ensure_counter_matches_file(term(), Path.t(), :atomics.atomics_ref(), keyword()) ::
          {:ok, :atomics.atomics_ref()} | {:error, term()}
  defp ensure_counter_matches_file(key, path, counter, opts) do
    info = :atomics.info(counter)
    sequence = :atomics.get(counter, 1)

    with {:ok, file_bytes} <- file_size(path) do
      if info.size >= 2 and :atomics.get(counter, 2) == file_bytes do
        {:ok, counter}
      else
        recover_and_install_counter(key, path, opts, sequence)
      end
    end
  end

  @spec recover_and_install_counter(term(), Path.t(), keyword(), non_neg_integer()) ::
          {:ok, :atomics.atomics_ref()} | {:error, term()}
  defp recover_and_install_counter(key, path, opts, minimum_sequence) do
    with {:ok, scan} <- recover_tail(path, opts) do
      counter = :atomics.new(2, signed: false)
      :ok = :atomics.put(counter, 1, max(scan.last_sequence, minimum_sequence))
      :ok = :atomics.put(counter, 2, scan.valid_bytes)
      :ets.insert(@counter_table, {key, counter})
      {:ok, counter}
    end
  end

  @spec take_legacy_sequence(term()) :: {:ok, non_neg_integer()} | :missing
  defp take_legacy_sequence(key) do
    value = :persistent_term.get(key, :missing)
    :persistent_term.erase(key)

    case value do
      {:atomics, counter} -> {:ok, :atomics.get(counter, 1)}
      sequence when is_integer(sequence) and sequence >= 0 -> {:ok, sequence}
      _missing_or_invalid -> :missing
    end
  end

  @spec ensure_counter_table :: :ok
  defp ensure_counter_table do
    case :ets.whereis(@counter_table) do
      :undefined ->
        try do
          :ets.new(@counter_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

          :ok
        rescue
          ArgumentError -> :ok
        end

      _table ->
        :ok
    end
  end

  @spec file_size(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, :enoent} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec truncate_and_sync(File.io_device(), non_neg_integer(), sync_mode()) ::
          :ok | {:error, term()}
  defp truncate_and_sync(io, offset, mode) do
    with {:ok, ^offset} <- :file.position(io, offset),
         :ok <- :file.truncate(io) do
      sync_io(io, mode)
    end
  end

  @spec write_and_sync(File.io_device(), iodata(), sync_mode()) :: :ok | {:error, term()}
  defp write_and_sync(io, bytes, mode) do
    with :ok <- :file.write(io, bytes) do
      sync_io(io, mode)
    end
  end

  @spec sync_io(File.io_device(), sync_mode()) :: :ok | {:error, term()}
  defp sync_io(_io, :none), do: :ok
  defp sync_io(io, :data), do: :file.datasync(io)
  defp sync_io(io, :always), do: :file.sync(io)

  @spec sync_directory(Path.t(), sync_mode()) :: :ok | {:error, term()}
  defp sync_directory(_directory, :none), do: :ok

  defp sync_directory(directory, _mode) do
    # OTP's `:directory` mode maps to an actual directory descriptor. Syncing
    # it is what makes rename/unlink metadata durable, not merely atomic.
    case File.open(directory, [:read, :raw, :directory]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = File.close(io)
        prefer_operation_error(sync_result, close_result)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec prefer_operation_error(:ok | {:error, term()}, :ok | {:error, term()}) ::
          :ok | {:error, term()}
  defp prefer_operation_error({:error, _reason} = error, _close_result), do: error
  defp prefer_operation_error(:ok, close_result), do: close_result
end
