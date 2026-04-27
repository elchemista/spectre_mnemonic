defmodule SpectreMnemonic.Store.FileStorage do
  @moduledoc """
  Append-only file storage adapter for persistent memory records.

  This keeps the original frame format: magic/version bytes, sequence,
  timestamp, payload length, CRC32, and compressed Erlang term payload. Replay
  stops at the first incomplete or corrupt trailing frame.
  """

  @behaviour SpectreMnemonic.Store.Adapter

  @magic "SMEM"
  @version 1

  @impl true
  @spec capabilities(keyword()) :: [SpectreMnemonic.Store.Adapter.capability()]
  def capabilities(_opts), do: [:append, :replay, :event_log]

  @impl true
  @spec put(SpectreMnemonic.Store.Record.t(), keyword()) ::
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
    root = data_root(opts)
    {:ok, replay_path(active_path(root))}
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
    replay_path(path)
    |> List.last({0, nil, nil})
    |> elem(0)
    |> Kernel.+(1)
  end

  @spec replay_path(Path.t()) :: [tuple()]
  defp replay_path(path) do
    case File.read(path) do
      {:ok, binary} -> read_frames(binary, [])
      {:error, :enoent} -> []
      {:error, _reason} -> []
    end
  end

  @spec read_frames(binary(), [tuple()]) :: [tuple()]
  defp read_frames(
         <<@magic, @version, seq::unsigned-64, timestamp::signed-64, len::32, crc::32,
           rest::binary>>,
         acc
       )
       when byte_size(rest) >= len do
    <<payload::binary-size(len), tail::binary>> = rest

    if :erlang.crc32(payload) == crc do
      read_frames(tail, [{seq, timestamp, :erlang.binary_to_term(payload)} | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp read_frames(_incomplete_or_unknown, acc), do: Enum.reverse(acc)
end
