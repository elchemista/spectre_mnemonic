defmodule SpectreMnemonic.Persistence.Store.File do
  @moduledoc """
  Append-only file storage adapter for persistent memory records.

  This keeps the original frame format: magic/version bytes, sequence,
  timestamp, payload length, CRC32, and compressed Erlang term payload. Replay
  stops at the first incomplete or corrupt trailing frame.
  """

  @behaviour SpectreMnemonic.Persistence.Store.Adapter

  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.FramedLog
  alias SpectreMnemonic.Persistence.PathLock
  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.Store.Record

  @typep fold_result(acc) :: {:ok, acc} | {:halted, acc} | {:error, term()}

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec capabilities(keyword()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  def capabilities(_opts),
    do: [:append, :replay, :replay_fold, :event_log, :erase_partition, :verify_erasure]

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec put(SpectreMnemonic.Persistence.Store.Record.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def put(record, opts) do
    # Append first, ask existential questions later. The frame has seq, time,
    # length, and CRC so replay can be grumpy in a useful way.
    root = data_root(opts)
    path = active_path(root)

    PathLock.trans({__MODULE__, Path.expand(root)}, fn ->
      with :ok <- ensure_root(root) do
        append_locked(path, record, opts)
      end
    end)
  end

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec replay(keyword()) :: {:ok, [tuple()]} | {:error, term()}
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

    case replay_snapshot_fold(root, acc, fun) do
      {:ok, acc} -> normalize_fold_result(replay_path_fold(active_path(root), acc, fun))
      {:halted, acc} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Compacts live records into an atomic snapshot and rotates the active segment."
  @spec compact(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def compact(opts \\ []), do: compact(opts, nil)

  @doc false
  @spec compact(keyword(), [Record.t()] | nil) :: {:ok, Path.t()} | {:error, term()}
  def compact(opts, supplied_records) do
    root = data_root(opts)
    retain = Keyword.get(opts, :retain_compacted_segments, 1)
    erase? = Keyword.get(opts, :erase?, false)

    with :ok <- validate_retention(retain) do
      compact_under_path_lock(root, supplied_records, retain, erase?, opts)
    end
  end

  @spec compact_under_path_lock(
          Path.t(),
          [Record.t()] | nil,
          non_neg_integer(),
          boolean(),
          keyword()
        ) :: {:ok, Path.t()} | {:error, term()}
  defp compact_under_path_lock(root, supplied_records, retain, erase?, opts) do
    PathLock.trans({__MODULE__, Path.expand(root)}, fn ->
      with :ok <- ensure_root(root) do
        compact_locked(root, supplied_records, retain, erase?, opts)
      end
    end)
  end

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec erase_partition(binary(), term(), MapSet.t({atom(), binary()}), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def erase_partition(namespace, scope, targets, opts) do
    erase_opts =
      opts
      |> Keyword.put(:retain_compacted_segments, 0)
      |> Keyword.put(:erase?, true)

    with {:ok, path} <- compact(erase_opts),
         :ok <- verify_erased(erase_opts, namespace, scope, targets) do
      {:ok, path}
    end
  end

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec verify_erased(binary(), term(), MapSet.t({atom(), binary()}), keyword()) ::
          :ok | {:error, term()}
  def verify_erased(namespace, scope, targets, opts) when is_binary(namespace),
    do: verify_erased_files(opts, namespace, scope, targets)

  @doc false
  @spec verify_erased(keyword(), binary(), term(), MapSet.t({atom(), binary()})) ::
          :ok | {:error, term()}
  def verify_erased(opts, namespace, scope, targets) when is_list(opts),
    do: verify_erased_files(opts, namespace, scope, targets)

  @doc "Returns the configured data root."
  @spec data_root(keyword()) :: Path.t()
  def data_root(opts \\ []) do
    Keyword.get(opts, :data_root) ||
      Application.get_env(:spectre_mnemonic, :data_root, "mnemonic_data")
  end

  @spec verify_erased_files(keyword(), binary(), term(), MapSet.t({atom(), binary()})) ::
          :ok | {:error, term()}
  defp verify_erased_files(opts, namespace, scope, targets) do
    root = data_root(opts)

    collector = fn frame, acc ->
      collect_erased_survivor(frame, acc, namespace, scope, targets)
    end

    case replay_fold(opts, [], collector) do
      {:ok, survivors} -> verify_erasure_results(survivors, root)
      {:error, _reason} = error -> error
    end
  end

  @spec collect_erased_survivor(
          term(),
          [Record.t()],
          binary(),
          term(),
          MapSet.t({atom(), binary()})
        ) :: {:cont, [Record.t()]}
  defp collect_erased_survivor(frame, acc, namespace, scope, targets) do
    case raw_record(frame) do
      %Record{} = record ->
        if erased_survivor?(record, namespace, scope, targets),
          do: {:cont, [record | acc]},
          else: {:cont, acc}

      _other ->
        {:cont, acc}
    end
  end

  @spec verify_erasure_results([Record.t()], Path.t()) :: :ok | {:error, term()}
  defp verify_erasure_results(survivors, root) do
    case verify_no_survivors(survivors) do
      :ok -> verify_erase_retention(root)
      {:error, _reason} = error -> error
    end
  end

  @spec ensure_root(Path.t()) :: :ok | {:error, term()}
  defp ensure_root(root) do
    with :ok <- File.mkdir_p(Path.join(root, "segments")),
         :ok <- File.mkdir_p(Path.join(root, "snapshots")) do
      File.mkdir_p(Path.join(root, "artifacts"))
    end
  end

  @spec append_locked(Path.t(), Record.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp append_locked(path, record, opts) do
    key = {__MODULE__, :seq, path}

    with {:ok, counter} <- FramedLog.sequence_counter(key, path, opts),
         seq = :atomics.add_get(counter, 1, 1),
         {:ok, frame} <- FileFrame.encode_checked(seq, record),
         :ok <- FramedLog.append(path, frame, opts) do
      :ok = FramedLog.advance_offset(counter, byte_size(frame))
      {:ok, seq}
    end
  end

  @spec compact_locked(Path.t(), [Record.t()] | nil, non_neg_integer(), boolean(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  defp compact_locked(root, supplied_records, retain, erase?, opts) do
    records = supplied_records || compactable_records(root)
    snapshot = snapshot_path(root)
    temporary = snapshot <> ".tmp"

    payload = %{
      version: 1,
      created_at: DateTime.utc_now(),
      records: records
    }

    with :ok <-
           FramedLog.write_file(temporary, :erlang.term_to_binary(payload, [:compressed]), opts),
         :ok <- install_snapshot(snapshot, temporary, opts),
         :ok <- rotate_active_segment(root, opts),
         :ok <- prune_rotated_segments(root, retain, opts),
         :ok <- remove_previous_if_erasing(root, erase?, opts) do
      {:ok, snapshot}
    else
      {:error, reason} ->
        FramedLog.remove(temporary, opts)
        {:error, reason}
    end
  end

  @spec remove_previous_if_erasing(Path.t(), boolean(), keyword()) :: :ok | {:error, term()}
  defp remove_previous_if_erasing(root, true, opts),
    do: FramedLog.remove(previous_snapshot_path(root), opts)

  defp remove_previous_if_erasing(_root, false, _opts), do: :ok

  @spec active_path(Path.t()) :: Path.t()
  defp active_path(root), do: Path.join([root, "segments", "active.smem"])

  @spec snapshot_path(Path.t()) :: Path.t()
  defp snapshot_path(root), do: Path.join([root, "snapshots", "current.term"])

  @spec previous_snapshot_path(Path.t()) :: Path.t()
  defp previous_snapshot_path(root), do: Path.join([root, "snapshots", "previous.term"])

  @spec replay_snapshot_fold(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          fold_result(acc)
        when acc: term()
  defp replay_snapshot_fold(root, acc, fun) do
    case read_snapshot(snapshot_path(root)) do
      {:ok, records} -> fold_snapshot_records(records, acc, fun)
      {:error, _reason} -> replay_previous_and_latest_rotated(root, acc, fun)
    end
  end

  @spec replay_previous_and_latest_rotated(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          fold_result(acc)
        when acc: term()
  defp replay_previous_and_latest_rotated(root, acc, fun) do
    case replay_previous_snapshot(root, acc, fun) do
      {:ok, acc} -> replay_latest_rotated(root, acc, fun)
      {:halted, acc} -> {:halted, acc}
    end
  end

  @spec replay_previous_snapshot(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc} | {:halted, acc}
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
          {:ok, acc} | {:halted, acc}
        when acc: term()
  defp fold_snapshot_records(records, acc, fun) do
    result =
      records
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, acc}, fn {record, seq}, {:ok, acc} ->
        timestamp = snapshot_timestamp(record)

        case fun.({seq, timestamp, record}, acc) do
          {:cont, acc} -> {:cont, {:ok, acc}}
          {:halt, acc} -> {:halt, {:halted, acc}}
        end
      end)

    result
  end

  @spec snapshot_timestamp(term()) :: integer()
  defp snapshot_timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :millisecond)

  defp snapshot_timestamp(_record), do: 0

  @spec replay_latest_rotated(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          fold_result(acc)
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

  @spec install_snapshot(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  defp install_snapshot(snapshot, temporary, opts) do
    previous = Path.join(Path.dirname(snapshot), "previous.term")

    with :ok <- FramedLog.remove(previous, opts),
         :ok <- move_current_to_previous(snapshot, previous, opts) do
      FramedLog.rename(temporary, snapshot, opts)
    end
  end

  @spec move_current_to_previous(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  defp move_current_to_previous(snapshot, previous, opts) do
    case FramedLog.rename(snapshot, previous, opts) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rotate_active_segment(Path.t(), keyword()) :: :ok | {:error, term()}
  defp rotate_active_segment(root, opts) do
    active = active_path(root)
    rotated = Path.join([root, "segments", "compacted-#{System.system_time(:microsecond)}.smem"])

    result =
      case File.stat(active) do
        {:ok, %{size: size}} when size > 0 -> FramedLog.rename(active, rotated, opts)
        {:ok, _empty} -> FramedLog.remove(active, opts)
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end

    with :ok <- result,
         :ok <- FramedLog.write_file(active, "", opts) do
      FramedLog.reset_sequence_counter({__MODULE__, :seq, active})
    end
  end

  @spec prune_rotated_segments(Path.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  defp prune_rotated_segments(root, retain, opts) when is_integer(retain) and retain >= 0 do
    root
    |> rotated_paths()
    |> Enum.reverse()
    |> Enum.drop(retain)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case FramedLog.remove(path, opts) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prune_rotated_segments(_root, _retain, _opts), do: {:error, :invalid_retention}

  @spec validate_retention(term()) :: :ok | {:error, :invalid_retention}
  defp validate_retention(retain) when is_integer(retain) and retain >= 0, do: :ok
  defp validate_retention(_retain), do: {:error, :invalid_retention}

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
    |> apply_erasure_markers()
    |> Enum.sort_by(&record_timestamp/1)
  end

  @spec raw_record(term()) :: Record.t() | nil
  defp raw_record({_sequence, _timestamp, %Record{} = record}), do: record
  defp raw_record(%Record{} = record), do: record
  defp raw_record(_frame), do: nil

  @spec erased_survivor?(Record.t(), binary(), term(), MapSet.t({atom(), binary()})) :: boolean()
  defp erased_survivor?(record, namespace, scope, targets) do
    same_partition = record.namespace == namespace and record.scope == scope
    target = {record.family, payload_id(record.payload)}

    same_partition and
      (record.family != :erasure_markers or MapSet.member?(targets, target))
  end

  @spec verify_no_survivors([Record.t()]) :: :ok | {:error, term()}
  defp verify_no_survivors([]), do: :ok

  defp verify_no_survivors(records) do
    surviving = Enum.map(records, &{&1.family, payload_id(&1.payload), &1.id})
    {:error, {:erasure_bytes_survived, surviving}}
  end

  @spec verify_erase_retention(Path.t()) :: :ok | {:error, term()}
  defp verify_erase_retention(root) do
    previous = previous_snapshot_path(root)
    rotated = rotated_paths(root)

    if not File.exists?(previous) and rotated == [],
      do: :ok,
      else: {:error, {:erasure_retention_survived, previous, rotated}}
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
        case tombstone_target(record.payload) do
          {:ok, {family, id}} -> [{record.namespace, record.scope, family, id}]
          :error -> []
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

  @spec apply_erasure_markers([Record.t()]) :: [Record.t()]
  defp apply_erasure_markers(records) do
    markers =
      records
      |> Enum.filter(&(&1.family == :erasure_markers))
      |> Enum.reduce(%{}, &put_latest_erasure_marker/2)

    Enum.reject(records, &erased_record?(&1, markers))
  end

  @spec put_latest_erasure_marker(Record.t(), map()) :: map()
  defp put_latest_erasure_marker(record, markers) do
    key = {record.namespace, record.scope}

    case Map.fetch(markers, key) do
      :error -> Map.put(markers, key, record)
      {:ok, current} -> Map.put(markers, key, latest_record(record, current))
    end
  end

  @spec latest_record(Record.t(), Record.t()) :: Record.t()
  defp latest_record(candidate, current) do
    if record_timestamp(candidate) >= record_timestamp(current), do: candidate, else: current
  end

  @spec erased_record?(Record.t(), map()) :: boolean()
  defp erased_record?(record, markers) do
    marker = Map.get(markers, {record.namespace, record.scope})

    not is_nil(marker) and record.family != :erasure_markers and erased_by_marker?(record, marker)
  end

  @spec erased_by_marker?(Record.t(), Record.t()) :: boolean()
  defp erased_by_marker?(record, marker) do
    case map_value(marker.payload, :generation) do
      generation when is_binary(generation) ->
        map_value(record.metadata, :erasure_generation) != generation

      _legacy_marker ->
        record_timestamp(record) <= record_timestamp(marker)
    end
  end

  @spec payload_id(term()) :: term()
  defp payload_id(payload) when is_map(payload) do
    Map.get(payload, :id) || Map.get(payload, "id")
  end

  defp payload_id(_payload), do: nil

  @spec map_value(map(), atom()) :: term()
  defp map_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @spec tombstone_target(term()) :: {:ok, {atom(), binary()}} | :error
  defp tombstone_target(payload) when is_map(payload) do
    family = Map.get(payload, :family) || Map.get(payload, "family")
    id = payload_id(payload)

    with {:ok, family} <- normalize_family(family),
         true <- is_binary(id) do
      {:ok, {family, id}}
    else
      _invalid -> :error
    end
  end

  defp tombstone_target(_payload), do: :error

  @spec normalize_family(term()) :: {:ok, atom()} | :error
  defp normalize_family(family) when is_atom(family), do: {:ok, family}
  defp normalize_family(family) when is_binary(family), do: Family.from_string(family)
  defp normalize_family(_family), do: :error

  @spec replay_path(Path.t()) :: [FileFrame.t()]
  defp replay_path(path) do
    {:ok, frames} = replay_path_fold(path, [], fn frame, acc -> {:cont, [frame | acc]} end)
    Enum.reverse(frames)
  end

  @spec replay_path_fold(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          fold_result(acc)
        when acc: term()
  defp replay_path_fold(path, acc, fun) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          FileFrame.read_frames(io, {:ok, acc}, fn frame, {:ok, acc} ->
            case fun.(frame, acc) do
              {:cont, acc} -> {:cont, {:ok, acc}}
              {:halt, acc} -> {:halt, {:halted, acc}}
            end
          end)
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec normalize_fold_result({:ok, term()} | {:halted, term()} | {:error, term()}) ::
          {:ok, term()} | {:error, term()}
  defp normalize_fold_result({:halted, acc}), do: {:ok, acc}
  defp normalize_fold_result(result), do: result
end
