defmodule SpectreMnemonic.Persistence.Store.File do
  @moduledoc """
  Append-only file storage adapter for persistent memory records.

  This keeps the original frame format: magic/version bytes, sequence,
  timestamp, payload length, CRC32, and compressed Erlang term payload. Replay
  stops at the first incomplete or corrupt trailing frame.
  """

  @behaviour SpectreMnemonic.Persistence.Store.Adapter

  @magic "SMEM"
  @version 1
  @header_bytes byte_size(@magic) + 1 + 8 + 8 + 4 + 4

  @impl true
  @spec capabilities(keyword()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  def capabilities(_opts), do: [:append, :replay, :replay_fold, :event_log]

  @impl true
  @spec put(SpectreMnemonic.Persistence.Store.Record.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def put(record, opts) do
    root = data_root(opts)
    ensure_root!(root)
    path = active_path(root)
    seq = next_seq(path)
    payload = :erlang.term_to_binary(record, [:compressed])
    crc = :erlang.crc32(payload)
    timestamp = System.system_time(:millisecond)

    frame =
      <<@magic, @version, seq::unsigned-64, timestamp::signed-64, byte_size(payload)::32, crc::32,
        payload::binary>>

    case File.write(path, frame, [:append, :binary]) do
      :ok -> {:ok, seq}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec replay(keyword()) :: {:ok, [tuple()]}
  def replay(opts) do
    with {:ok, frames} <- replay_fold(opts, [], fn frame, acc -> {:cont, [frame | acc]} end) do
      {:ok, Enum.reverse(frames)}
    end
  end

  @impl true
  @spec replay_fold(keyword(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def replay_fold(opts, acc, fun) when is_function(fun, 2) do
    opts
    |> data_root()
    |> active_path()
    |> replay_path_fold(acc, fun)
  end

  @doc "Compacts current replayable records into a snapshot file."
  @spec compact(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def compact(opts \\ []) do
    root = data_root(opts)
    ensure_root!(root)
    records = replay_path(active_path(root))
    snapshot = Path.join([root, "snapshots", "snapshot-#{System.system_time(:millisecond)}.term"])

    case File.write(snapshot, :erlang.term_to_binary(records, [:compressed])) do
      :ok -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the configured data root."
  @spec data_root(keyword()) :: Path.t()
  def data_root(opts \\ []) do
    Keyword.get(opts, :data_root) ||
      Application.get_env(:spectre_mnemonic, :data_root, "mnemonic_data")
  end

  @spec ensure_root!(Path.t()) :: :ok
  defp ensure_root!(root) do
    File.mkdir_p!(Path.join(root, "segments"))
    File.mkdir_p!(Path.join(root, "snapshots"))
    File.mkdir_p!(Path.join(root, "artifacts"))
  end

  @spec active_path(Path.t()) :: Path.t()
  defp active_path(root), do: Path.join([root, "segments", "active.smem"])

  @spec next_seq(Path.t()) :: pos_integer()
  defp next_seq(path) do
    key = {__MODULE__, :seq, path}

    current =
      case :persistent_term.get(key, :missing) do
        :missing -> initial_seq(path)
        seq -> seq
      end

    seq = current + 1
    :persistent_term.put(key, seq)
    seq
  end

  @spec initial_seq(Path.t()) :: non_neg_integer()
  defp initial_seq(path) do
    {:ok, seq} =
      replay_path_fold(path, 0, fn {seq, _timestamp, _payload}, _acc -> {:cont, seq} end)

    seq
  end

  @spec replay_path(Path.t()) :: [tuple()]
  defp replay_path(path) do
    {:ok, frames} = replay_path_fold(path, [], fn frame, acc -> {:cont, [frame | acc]} end)
    Enum.reverse(frames)
  end

  @spec replay_path_fold(Path.t(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp replay_path_fold(path, acc, fun) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, read_frames(io, acc, fun)}
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec read_frames(File.io_device(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) :: acc
        when acc: term()
  defp read_frames(io, acc, fun) do
    case IO.binread(io, @header_bytes) do
      <<@magic, @version, seq::unsigned-64, timestamp::signed-64, len::32, crc::32>> ->
        read_payload(io, seq, timestamp, len, crc, acc, fun)

      incomplete_or_unknown when is_binary(incomplete_or_unknown) ->
        acc

      :eof ->
        acc

      {:error, _reason} ->
        acc
    end
  end

  @spec read_payload(
          File.io_device(),
          pos_integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          acc,
          (tuple(), acc -> {:cont, acc} | {:halt, acc})
        ) :: acc
        when acc: term()
  defp read_payload(io, seq, timestamp, len, crc, acc, fun) do
    case IO.binread(io, len) do
      payload when is_binary(payload) and byte_size(payload) == len ->
        read_complete_payload(io, seq, timestamp, payload, crc, acc, fun)

      _incomplete_or_error ->
        acc
    end
  end

  @spec read_complete_payload(
          File.io_device(),
          pos_integer(),
          integer(),
          binary(),
          non_neg_integer(),
          acc,
          (tuple(), acc -> {:cont, acc} | {:halt, acc})
        ) :: acc
        when acc: term()
  defp read_complete_payload(io, seq, timestamp, payload, crc, acc, fun) do
    if :erlang.crc32(payload) == crc do
      frame = {seq, timestamp, :erlang.binary_to_term(payload)}
      continue_frame(io, frame, acc, fun)
    else
      acc
    end
  end

  @spec continue_frame(File.io_device(), tuple(), acc, (tuple(), acc ->
                                                          {:cont, acc} | {:halt, acc})) ::
          acc
        when acc: term()
  defp continue_frame(io, frame, acc, fun) do
    case fun.(frame, acc) do
      {:cont, acc} -> read_frames(io, acc, fun)
      {:halt, acc} -> acc
    end
  end
end
