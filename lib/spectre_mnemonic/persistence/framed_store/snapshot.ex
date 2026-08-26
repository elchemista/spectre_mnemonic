defmodule SpectreMnemonic.Persistence.FramedStore.Snapshot do
  @moduledoc false

  alias SpectreMnemonic.FailureInjection
  alias SpectreMnemonic.Persistence.FramedLog
  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.Store.Record

  @schema_version 2

  @type manifest :: %{
          required(:schema_version) => 2,
          required(:created_at) => DateTime.t(),
          required(:record_count) => non_neg_integer(),
          optional(:rotated_through) => binary() | nil
        }

  @doc false
  @spec write(Path.t(), [Record.t()], map(), keyword()) :: :ok | {:error, term()}
  def write(path, records, metadata, opts)
      when is_list(records) and is_map(metadata) and is_list(opts) do
    manifest = %{
      schema_version: @schema_version,
      created_at: DateTime.utc_now(),
      record_count: length(records),
      rotated_through: Map.get(metadata, :rotated_through)
    }

    with :ok <- FramedLog.write_file(path, "", opts),
         {:ok, io} <- File.open(path, [:append, :binary, :raw]) do
      write_result = write_frames(io, manifest, records, opts)
      close_result = File.close(io)

      with :ok <- prefer_write_error(write_result, close_result) do
        FramedLog.sync_file(path, opts)
      end
    end
  end

  @doc false
  @spec write_table(Path.t(), :ets.tid(), map(), keyword()) :: :ok | {:error, term()}
  def write_table(path, table, metadata, opts) when is_map(metadata) and is_list(opts) do
    manifest = %{
      schema_version: @schema_version,
      created_at: DateTime.utc_now(),
      record_count: :ets.info(table, :size),
      rotated_through: Map.get(metadata, :rotated_through)
    }

    with :ok <- FramedLog.write_file(path, "", opts),
         {:ok, io} <- File.open(path, [:append, :binary, :raw]) do
      write_result = write_table_frames(io, manifest, table, opts)
      close_result = File.close(io)

      with :ok <- prefer_write_error(write_result, close_result) do
        FramedLog.sync_file(path, opts)
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_snapshot_table}
  end

  @doc false
  @spec fold(Path.t(), acc, (Record.t(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc, manifest()} | {:halted, acc, manifest()} | {:error, term()}
        when acc: term()
  def fold(path, acc, fun) when is_function(fun, 2) do
    with {:ok, manifest} <- validate(path),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        result =
          FileFrame.read_frames(io, {:running, acc}, fn
            {_seq, _timestamp, {:snapshot_record, %Record{} = record}}, {:running, current} ->
              case fun.(Record.upgrade(record), current) do
                {:cont, next} -> {:cont, {:running, next}}
                {:halt, next} -> {:halt, {:halted, next}}
              end

            _metadata_frame, state ->
              {:cont, state}
          end)

        case result do
          {:running, result_acc} -> {:ok, result_acc, manifest}
          {:halted, result_acc} -> {:halted, result_acc, manifest}
        end
      after
        File.close(io)
      end
    end
  end

  @doc false
  @spec validate(Path.t()) :: {:ok, manifest()} | {:error, term()}
  def validate(path) do
    with {:ok, %{status: :clean, file_bytes: bytes}} when bytes > 0 <- FileFrame.scan_path(path),
         {:ok, state} <- validation_fold(path),
         {:ok, manifest} <- validate_state(state) do
      {:ok, manifest}
    else
      {:ok, %{status: {:invalid_tail, reason}}} -> {:error, {:invalid_snapshot_tail, reason}}
      {:ok, %{file_bytes: 0}} -> {:error, :invalid_snapshot}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  @spec write_frames(File.io_device(), manifest(), [Record.t()], keyword()) ::
          :ok | {:error, term()}
  defp write_frames(io, manifest, records, opts) do
    with :ok <- write_frame(io, 1, {:snapshot_manifest, manifest}, 0),
         {:ok, state} <- write_records(io, records, opts) do
      trailer = snapshot_trailer(state)
      write_frame(io, state.sequence, {:snapshot_trailer, trailer}, 0)
    end
  end

  @spec write_table_frames(File.io_device(), manifest(), :ets.tid(), keyword()) ::
          :ok | {:error, term()}
  defp write_table_frames(io, manifest, table, opts) do
    with :ok <- write_frame(io, 1, {:snapshot_manifest, manifest}, 0),
         {:ok, state} <- write_table_records(io, table, opts) do
      trailer = snapshot_trailer(state)
      write_frame(io, state.sequence, {:snapshot_trailer, trailer}, 0)
    end
  end

  @spec snapshot_trailer(map()) :: map()
  defp snapshot_trailer(state) do
    %{
      schema_version: @schema_version,
      record_count: state.count,
      digest_algorithm: :sha256,
      digest: :crypto.hash_final(state.hash)
    }
  end

  @spec write_records(File.io_device(), [Record.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  defp write_records(io, records, opts) do
    initial = %{sequence: 2, count: 0, hash: :crypto.hash_init(:sha256)}

    Enum.reduce_while(records, {:ok, initial}, fn record, {:ok, state} ->
      with :ok <-
             FailureInjection.checkpoint(:snapshot_record, opts, %{
               record_index: state.count + 1
             }),
           :ok <- write_frame(io, state.sequence, {:snapshot_record, record}, timestamp(record)) do
        next = %{
          sequence: state.sequence + 1,
          count: state.count + 1,
          hash: :crypto.hash_update(state.hash, digest_bytes(record))
        }

        {:cont, {:ok, next}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec write_table_records(File.io_device(), :ets.tid(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp write_table_records(io, table, opts) do
    initial = %{sequence: 2, count: 0, hash: :crypto.hash_init(:sha256)}
    write_table_record(table, :ets.first(table), io, initial, opts)
  end

  defp write_table_record(_table, :"$end_of_table", _io, state, _opts), do: {:ok, state}

  defp write_table_record(table, key, io, state, opts) do
    next = :ets.next(table, key)

    case :ets.lookup(table, key) do
      [{^key, %Record{} = record}] ->
        with :ok <-
               FailureInjection.checkpoint(:snapshot_record, opts, %{
                 record_index: state.count + 1
               }),
             :ok <- write_frame(io, state.sequence, {:snapshot_record, record}, timestamp(record)) do
          state = %{
            sequence: state.sequence + 1,
            count: state.count + 1,
            hash: :crypto.hash_update(state.hash, digest_bytes(record))
          }

          write_table_record(table, next, io, state, opts)
        end

      _invalid ->
        {:error, :invalid_snapshot_table_record}
    end
  end

  @spec write_frame(File.io_device(), pos_integer(), term(), integer()) ::
          :ok | {:error, term()}
  defp write_frame(io, sequence, payload, timestamp) do
    with {:ok, frame} <- FileFrame.encode_checked(sequence, payload, timestamp) do
      :file.write(io, frame)
    end
  end

  @spec validation_fold(Path.t()) :: {:ok, map()} | {:error, term()}
  defp validation_fold(path) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        initial = %{
          stage: :manifest,
          expected_sequence: 1,
          manifest: nil,
          trailer: nil,
          count: 0,
          hash: :crypto.hash_init(:sha256),
          invalid: nil
        }

        {:ok, FileFrame.read_frames(io, initial, &validate_frame/2)}
      after
        File.close(io)
      end
    end
  end

  @spec validate_frame(FileFrame.t(), map()) :: {:cont, map()}
  defp validate_frame(_frame, %{invalid: reason} = state) when not is_nil(reason),
    do: {:cont, state}

  defp validate_frame(
         {1, _timestamp, {:snapshot_manifest, %{schema_version: @schema_version} = manifest}},
         %{stage: :manifest, expected_sequence: 1} = state
       ) do
    {:cont, %{state | stage: :records, expected_sequence: 2, manifest: manifest}}
  end

  defp validate_frame(
         {sequence, _timestamp, {:snapshot_record, %Record{} = record}},
         %{stage: :records, expected_sequence: sequence} = state
       ) do
    {:cont,
     %{
       state
       | expected_sequence: sequence + 1,
         count: state.count + 1,
         hash: :crypto.hash_update(state.hash, digest_bytes(Record.upgrade(record)))
     }}
  end

  defp validate_frame(
         {sequence, _timestamp,
          {:snapshot_trailer, %{schema_version: @schema_version} = trailer}},
         %{stage: :records, expected_sequence: sequence} = state
       ) do
    {:cont, %{state | stage: :complete, expected_sequence: sequence + 1, trailer: trailer}}
  end

  defp validate_frame(_frame, state), do: {:cont, %{state | invalid: :invalid_frame_order}}

  @spec validate_state(map()) :: {:ok, manifest()} | {:error, term()}
  defp validate_state(%{stage: :complete, invalid: nil} = state) do
    digest = :crypto.hash_final(state.hash)
    manifest_count = Map.get(state.manifest, :record_count)
    trailer_count = Map.get(state.trailer, :record_count)
    trailer_digest = Map.get(state.trailer, :digest)

    cond do
      manifest_count != state.count -> {:error, :snapshot_record_count_mismatch}
      trailer_count != state.count -> {:error, :snapshot_record_count_mismatch}
      trailer_digest != digest -> {:error, :snapshot_digest_mismatch}
      Map.get(state.trailer, :digest_algorithm) != :sha256 -> {:error, :snapshot_digest_invalid}
      true -> {:ok, state.manifest}
    end
  end

  defp validate_state(%{invalid: reason}) when not is_nil(reason), do: {:error, reason}
  defp validate_state(_state), do: {:error, :snapshot_incomplete}

  @spec digest_bytes(Record.t()) :: binary()
  defp digest_bytes(record), do: :erlang.term_to_binary(record, [:deterministic])

  @spec timestamp(Record.t()) :: integer()
  defp timestamp(%Record{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :millisecond)

  defp timestamp(_record), do: 0

  @spec prefer_write_error(:ok | {:error, term()}, :ok | {:error, term()}) ::
          :ok | {:error, term()}
  defp prefer_write_error({:error, _reason} = error, _close_result), do: error
  defp prefer_write_error(:ok, close_result), do: close_result
end
