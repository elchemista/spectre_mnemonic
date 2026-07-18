defmodule SpectreMnemonic.Persistence.Store.File do
  @moduledoc """
  Append-only file storage adapter for persistent memory records.

  This keeps the original frame format: magic/version bytes, sequence,
  timestamp, payload length, CRC32, and compressed Erlang term payload. Replay
  stops at the first incomplete or corrupt trailing frame.
  """

  @behaviour SpectreMnemonic.Persistence.Store.Adapter

  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.Store.Record

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec capabilities(keyword()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  def capabilities(_opts), do: [:append, :replay, :replay_fold, :event_log]

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec put(SpectreMnemonic.Persistence.Store.Record.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def put(record, opts) do
    # Append first, ask existential questions later. The frame has seq, time,
    # length, and CRC so replay can be grumpy in a useful way.
    root = data_root(opts)
    ensure_root!(root)
    path = active_path(root)
    seq = next_seq(path)
    frame = FileFrame.encode(seq, record)

    case File.write(path, frame, [:append, :binary]) do
      :ok -> {:ok, seq}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec replay(keyword()) :: {:ok, [tuple()]}
  def replay(opts) do
    with {:ok, frames} <- replay_fold(opts, [], fn frame, acc -> {:cont, [frame | acc]} end) do
      {:ok, Enum.reverse(frames)}
    end
  end

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec replay_fold(keyword(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def replay_fold(opts, acc, fun) when is_function(fun, 2) do
    root = data_root(opts)

    with {:ok, acc} <- replay_snapshot_fold(root, acc, fun) do
      replay_path_fold(active_path(root), acc, fun)
    end
  end

  @doc "Compacts live records into an atomic snapshot and rotates the active segment."
  @spec compact(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def compact(opts \\ []), do: compact(opts, nil)

  @doc false
  @spec compact(keyword(), [Record.t()] | nil) :: {:ok, Path.t()} | {:error, term()}
  def compact(opts, supplied_records) do
    root = data_root(opts)
    ensure_root!(root)
    records = supplied_records || compactable_records(root)
    snapshot = snapshot_path(root)
    temporary = snapshot <> ".tmp"

    payload = %{
      version: 1,
      created_at: DateTime.utc_now(),
      records: records
    }

    with :ok <- File.write(temporary, :erlang.term_to_binary(payload, [:compressed]), [:binary]),
         :ok <- install_snapshot(snapshot, temporary),
         :ok <- rotate_active_segment(root),
         :ok <- prune_rotated_segments(root, Keyword.get(opts, :retain_compacted_segments, 1)) do
      {:ok, snapshot}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
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

  @spec snapshot_path(Path.t()) :: Path.t()
  defp snapshot_path(root), do: Path.join([root, "snapshots", "current.term"])

  @spec previous_snapshot_path(Path.t()) :: Path.t()
  defp previous_snapshot_path(root), do: Path.join([root, "snapshots", "previous.term"])

  @spec replay_snapshot_fold(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp replay_snapshot_fold(root, acc, fun) do
    case read_snapshot(snapshot_path(root)) do
      {:ok, records} -> fold_snapshot_records(records, acc, fun)
      {:error, _reason} -> replay_previous_and_latest_rotated(root, acc, fun)
    end
  end

  @spec replay_previous_and_latest_rotated(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp replay_previous_and_latest_rotated(root, acc, fun) do
    with {:ok, acc} <- replay_previous_snapshot(root, acc, fun) do
      replay_latest_rotated(root, acc, fun)
    end
  end

  @spec replay_previous_snapshot(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc}
        when acc: term()
  defp replay_previous_snapshot(root, acc, fun) do
    case read_snapshot(previous_snapshot_path(root)) do
      {:ok, records} -> fold_snapshot_records(records, acc, fun)
      {:error, _reason} -> {:ok, acc}
    end
  end

  @spec read_snapshot(Path.t()) :: {:ok, [Record.t()]} | {:error, term()}
  defp read_snapshot(path) do
    with {:ok, binary} <- File.read(path),
         %{version: 1, records: records} <- :erlang.binary_to_term(binary, [:safe]),
         true <- is_list(records) do
      {:ok, records}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_snapshot}
    end
  rescue
    _exception -> {:error, :invalid_snapshot}
  end

  @spec fold_snapshot_records([Record.t()], acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc}
        when acc: term()
  defp fold_snapshot_records(records, acc, fun) do
    result =
      records
      |> Enum.with_index(1)
      |> Enum.reduce_while(acc, fn {record, seq}, acc ->
        timestamp = snapshot_timestamp(record)

        case fun.({seq, timestamp, record}, acc) do
          {:cont, acc} -> {:cont, acc}
          {:halt, acc} -> {:halt, acc}
        end
      end)

    {:ok, result}
  end

  @spec snapshot_timestamp(term()) :: integer()
  defp snapshot_timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :millisecond)

  defp snapshot_timestamp(_record), do: 0

  @spec replay_latest_rotated(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp replay_latest_rotated(root, acc, fun) do
    root
    |> rotated_paths()
    |> List.last()
    |> case do
      nil -> {:ok, acc}
      path -> replay_path_fold(path, acc, fun)
    end
  end

  @spec install_snapshot(Path.t(), Path.t()) :: :ok | {:error, term()}
  defp install_snapshot(snapshot, temporary) do
    previous = Path.join(Path.dirname(snapshot), "previous.term")

    with :ok <- remove_if_present(previous),
         :ok <- move_current_to_previous(snapshot, previous) do
      File.rename(temporary, snapshot)
    end
  end

  @spec move_current_to_previous(Path.t(), Path.t()) :: :ok | {:error, term()}
  defp move_current_to_previous(snapshot, previous) do
    case File.rename(snapshot, previous) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remove_if_present(Path.t()) :: :ok | {:error, term()}
  defp remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rotate_active_segment(Path.t()) :: :ok | {:error, term()}
  defp rotate_active_segment(root) do
    active = active_path(root)
    rotated = Path.join([root, "segments", "compacted-#{System.system_time(:microsecond)}.smem"])

    result =
      case File.stat(active) do
        {:ok, %{size: size}} when size > 0 -> File.rename(active, rotated)
        {:ok, _empty} -> File.rm(active)
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end

    with :ok <- result,
         :ok <- File.write(active, "", [:binary]) do
      :persistent_term.erase({__MODULE__, :seq, active})
      :ok
    end
  end

  @spec prune_rotated_segments(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp prune_rotated_segments(root, retain) when is_integer(retain) and retain >= 0 do
    root
    |> rotated_paths()
    |> Enum.reverse()
    |> Enum.drop(retain)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prune_rotated_segments(_root, _retain), do: {:error, :invalid_retention}

  @spec rotated_paths(Path.t()) :: [Path.t()]
  defp rotated_paths(root) do
    [root, "segments", "compacted-*.smem"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.sort()
  end

  @spec compactable_records(Path.t()) :: [Record.t()]
  defp compactable_records(root) do
    snapshot_records =
      case read_snapshot(snapshot_path(root)) do
        {:ok, records} -> records
        {:error, _reason} -> recovery_records(root)
      end

    active_records =
      root
      |> active_path()
      |> replay_path()
      |> Enum.flat_map(fn
        {_seq, _timestamp, %Record{} = record} -> [record]
        _other -> []
      end)

    (snapshot_records ++ active_records)
    |> Enum.reduce(%{}, fn record, acc -> Map.put(acc, record.dedupe_key, record) end)
    |> Map.values()
    |> apply_tombstones()
    |> Enum.sort_by(&record_timestamp/1)
  end

  @spec recovery_records(Path.t()) :: [Record.t()]
  defp recovery_records(root) do
    previous =
      case read_snapshot(previous_snapshot_path(root)) do
        {:ok, records} -> records
        {:error, _reason} -> []
      end

    rotated =
      root
      |> rotated_paths()
      |> List.last()
      |> case do
        nil -> []
        path -> records_from_path(path)
      end

    previous ++ rotated
  end

  @spec records_from_path(Path.t()) :: [Record.t()]
  defp records_from_path(path) do
    path
    |> replay_path()
    |> Enum.flat_map(fn
      {_seq, _timestamp, %Record{} = record} -> [record]
      _other -> []
    end)
  end

  @spec record_timestamp(Record.t()) :: integer()
  defp record_timestamp(%Record{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp record_timestamp(_record), do: 0

  @spec apply_tombstones([Record.t()]) :: [Record.t()]
  defp apply_tombstones(records) do
    forgotten =
      records
      |> Enum.filter(&(&1.family == :tombstones))
      |> Enum.flat_map(fn record ->
        case record.payload do
          %{family: family, id: id} -> [{record.namespace, record.scope, family, id}]
          _other -> []
        end
      end)
      |> MapSet.new()

    Enum.reject(records, fn record ->
      record.family == :tombstones or
        MapSet.member?(
          forgotten,
          {record.namespace, record.scope, record.family, payload_id(record.payload)}
        )
    end)
  end

  @spec payload_id(term()) :: term()
  defp payload_id(%{id: id}), do: id
  defp payload_id(_payload), do: nil

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

  @spec replay_path(Path.t()) :: [FileFrame.t()]
  defp replay_path(path) do
    {:ok, frames} = replay_path_fold(path, [], fn frame, acc -> {:cont, [frame | acc]} end)
    Enum.reverse(frames)
  end

  @spec replay_path_fold(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp replay_path_fold(path, acc, fun) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, FileFrame.read_frames(io, acc, fun)}
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
