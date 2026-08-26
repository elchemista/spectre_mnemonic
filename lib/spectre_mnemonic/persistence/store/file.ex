defmodule SpectreMnemonic.Persistence.Store.File do
  @moduledoc """
  Append-only file storage adapter for persistent memory records.

  This keeps the original frame format: magic/version bytes, sequence,
  timestamp, payload length, CRC32, and compressed Erlang term payload. Replay
  stops at the first incomplete or corrupt trailing frame.
  """

  @behaviour SpectreMnemonic.Persistence.Store.Adapter

  alias SpectreMnemonic.FailureInjection
  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.FramedLog
  alias SpectreMnemonic.Persistence.FramedStore.Snapshot
  alias SpectreMnemonic.Persistence.Store.Contract
  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.StoreWriter

  @typep fold_result(acc) :: {:ok, acc} | {:halted, acc} | {:error, term()}

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec capabilities(keyword()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  def capabilities(_opts),
    do: [:append, :replay, :replay_fold, :event_log, :erase_partition, :verify_erasure]

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec contract(keyword()) :: Contract.t()
  def contract(_opts) do
    %Contract{
      adapter: __MODULE__,
      schema_versions: [1, 2],
      idempotency_key: :operation_id,
      operation_id: :optional,
      batch_commit: :framed_markers,
      commit_revision: :record,
      replay_fold: true,
      conflict_detection: :digest,
      erase_semantics: :physical,
      health_check: true,
      retry_classification: true,
      transactional: :append_frame,
      max_batch_size: 10_000,
      conformant?: true
    }
  end

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec health(keyword()) :: {:ok, map()} | {:error, term()}
  def health(opts) do
    root = data_root(opts)

    case File.stat(root) do
      {:ok, stat} ->
        {:ok, %{available?: stat.type == :directory, writable?: writable?(root)}}

      {:error, :enoent} ->
        {:ok, %{available?: true, writable?: writable_parent?(root)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec classify_retry(term()) :: :retryable | :permanent | :unknown
  def classify_retry(reason)
      when reason in [:eagain, :ebusy, :emfile, :enfile, :enospc, :estale],
      do: :retryable

  def classify_retry(reason) when reason in [:eacces, :eperm, :erofs, :enotdir], do: :permanent
  def classify_retry(_reason), do: :unknown

  @impl SpectreMnemonic.Persistence.Store.Adapter
  @spec put(SpectreMnemonic.Persistence.Store.Record.t(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def put(record, opts) do
    # Append first, ask existential questions later. The frame has seq, time,
    # length, and CRC so replay can be grumpy in a useful way.
    root = data_root(opts)
    path = active_path(root)

    result =
      StoreWriter.trans(
        {__MODULE__, Path.expand(root)},
        fn ->
          with :ok <- ensure_root(root) do
            append_locked(path, record, opts)
          end
        end,
        opts
      )

    recover_ambiguous_append(result, path, record)
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

    with :ok <- validate_retention(retain),
         {:ok, _sync_mode} <- FramedLog.sync_mode(opts),
         :ok <- ensure_root(root) do
      StoreWriter.trans(
        {__MODULE__, :compaction, Path.expand(root)},
        fn -> compact_serialized(root, supplied_records, retain, erase?, opts) end,
        opts
      )
    end
  end

  @spec compact_serialized(
          Path.t(),
          [Record.t()] | nil,
          non_neg_integer(),
          boolean(),
          keyword()
        ) :: {:ok, Path.t()} | {:error, term()}
  defp compact_serialized(root, supplied_records, retain, erase?, opts) do
    snapshot = snapshot_path(root)

    temporary =
      snapshot <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    with {:ok, _rotated} <- freeze_active_segment(root, opts),
         rotated_through = latest_rotated_name(root),
         :ok <-
           write_compacted_snapshot(
             temporary,
             root,
             supplied_records,
             rotated_through,
             opts
           ),
         :ok <- publish_snapshot(root, snapshot, temporary, retain, erase?, opts) do
      {:ok, snapshot}
    else
      {:error, reason} ->
        FramedLog.remove(temporary, opts)
        {:error, reason}
    end
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

  @spec writable?(Path.t()) :: boolean()
  defp writable?(path) do
    case File.stat(path) do
      {:ok, %{access: access}} -> access in [:write, :read_write]
      {:error, _reason} -> false
    end
  end

  @spec writable_parent?(Path.t()) :: boolean()
  defp writable_parent?(path) do
    parent = path |> Path.expand() |> Path.dirname()
    writable?(parent)
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

    with :ok <-
           FailureInjection.checkpoint(:before_store_commit, opts, %{
             operation_id: record.operation_id,
             commit_id: record.commit_id
           }),
         {:ok, counter} <- FramedLog.sequence_counter(key, path, opts),
         seq = :atomics.add_get(counter, 1, 1),
         {:ok, frame} <- FileFrame.encode_checked(seq, record),
         :ok <- FramedLog.append(path, frame, opts) do
      :ok = FramedLog.advance_offset(counter, byte_size(frame))

      with :ok <-
             FailureInjection.checkpoint(:after_store_commit, opts, %{
               operation_id: record.operation_id,
               commit_id: record.commit_id,
               sequence: seq
             }) do
        {:ok, seq}
      end
    end
  end

  @spec recover_ambiguous_append(term(), Path.t(), Record.t()) :: term()
  defp recover_ambiguous_append(
         {:error, {:store_writer_crashed, _reason}} = error,
         path,
         record
       ) do
    case committed_sequence(path, record) do
      sequence when is_integer(sequence) and sequence > 0 -> {:ok, sequence}
      _missing -> error
    end
  end

  defp recover_ambiguous_append(result, _path, _record), do: result

  @spec committed_sequence(Path.t(), Record.t()) :: pos_integer() | nil
  defp committed_sequence(path, record) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          FileFrame.read_frames(io, nil, fn {sequence, _timestamp, stored}, _acc ->
            if same_commit?(stored, record), do: {:halt, sequence}, else: {:cont, nil}
          end)
        after
          File.close(io)
        end

      {:error, _reason} ->
        nil
    end
  end

  @spec same_commit?(term(), Record.t()) :: boolean()
  defp same_commit?(%Record{} = stored, record) do
    stored = Record.upgrade(stored)

    cond do
      is_binary(record.commit_id) -> stored.commit_id == record.commit_id
      is_binary(record.dedupe_key) -> stored.dedupe_key == record.dedupe_key
      true -> stored.id == record.id
    end
  end

  defp same_commit?(_stored, _record), do: false

  @spec freeze_active_segment(Path.t(), keyword()) ::
          {:ok, Path.t() | nil} | {:error, term()}
  defp freeze_active_segment(root, opts) do
    StoreWriter.trans(
      {__MODULE__, Path.expand(root)},
      fn -> rotate_active_segment(root, opts) end,
      opts
    )
  end

  @spec publish_snapshot(
          Path.t(),
          Path.t(),
          Path.t(),
          non_neg_integer(),
          boolean(),
          keyword()
        ) :: :ok | {:error, term()}
  defp publish_snapshot(root, snapshot, temporary, retain, erase?, opts) do
    StoreWriter.trans(
      {__MODULE__, Path.expand(root)},
      fn ->
        with :ok <- install_snapshot(snapshot, temporary, opts),
             :ok <- prune_rotated_segments(root, retain, opts) do
          remove_previous_if_erasing(root, erase?, opts)
        end
      end,
      opts
    )
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
    case replay_snapshot_path(snapshot_path(root), acc, fun) do
      {:ok, acc, manifest} -> replay_rotated_after(root, cutoff(manifest), acc, fun)
      {:halted, acc, _manifest} -> {:halted, acc}
      {:error, _reason} -> replay_previous_and_latest_rotated(root, acc, fun)
    end
  end

  @spec replay_previous_and_latest_rotated(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          fold_result(acc)
        when acc: term()
  defp replay_previous_and_latest_rotated(root, acc, fun) do
    case replay_previous_snapshot(root, acc, fun) do
      {:ok, acc, manifest} -> replay_rotated_after(root, cutoff(manifest), acc, fun)
      {:halted, acc} -> {:halted, acc}
      {:error, _reason} -> replay_rotated_after(root, nil, acc, fun)
    end
  end

  @spec replay_previous_snapshot(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc, map()} | {:halted, acc} | {:error, term()}
        when acc: term()
  defp replay_previous_snapshot(root, acc, fun) do
    case replay_snapshot_path(previous_snapshot_path(root), acc, fun) do
      {:ok, acc, manifest} -> {:ok, acc, manifest}
      {:halted, acc, _manifest} -> {:halted, acc}
      {:error, _reason} = error -> error
    end
  end

  @spec replay_snapshot_path(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc, map()} | {:halted, acc, map()} | {:error, term()}
        when acc: term()
  defp replay_snapshot_path(path, acc, fun) do
    if framed_snapshot?(path) do
      fold_framed_snapshot(path, acc, fun)
    else
      replay_legacy_snapshot(path, acc, fun)
    end
  end

  @spec replay_legacy_snapshot(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc, map()} | {:halted, acc, map()} | {:error, term()}
        when acc: term()
  defp replay_legacy_snapshot(path, acc, fun) do
    with {:ok, records} <- read_legacy_snapshot(path) do
      legacy_snapshot_result(fold_snapshot_records(records, acc, fun))
    end
  end

  @spec legacy_snapshot_result({:ok, acc} | {:halted, acc}) ::
          {:ok, acc, map()} | {:halted, acc, map()}
        when acc: term()
  defp legacy_snapshot_result({status, result}) when status in [:ok, :halted] do
    {status, result, %{schema_version: 1, rotated_through: nil}}
  end

  @spec fold_framed_snapshot(Path.t(), acc, FileFrame.fold_fun(acc)) ::
          {:ok, acc, map()} | {:halted, acc, map()} | {:error, term()}
        when acc: term()
  defp fold_framed_snapshot(path, acc, fun) do
    callback = fn record, {current, sequence} ->
      next_sequence = sequence + 1

      case fun.({next_sequence, snapshot_timestamp(record), record}, current) do
        {:cont, next} -> {:cont, {next, next_sequence}}
        {:halt, next} -> {:halt, {next, next_sequence}}
      end
    end

    case Snapshot.fold(path, {acc, 0}, callback) do
      {:ok, {result, _sequence}, manifest} -> {:ok, result, manifest}
      {:halted, {result, _sequence}, manifest} -> {:halted, result, manifest}
      {:error, _reason} = error -> error
    end
  end

  @spec framed_snapshot?(Path.t()) :: boolean()
  defp framed_snapshot?(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          :file.read(io, 4) == {:ok, "SMEM"}
        after
          File.close(io)
        end

      {:error, _reason} ->
        false
    end
  end

  @spec read_legacy_snapshot(Path.t()) :: {:ok, [Record.t()]} | {:error, term()}
  defp read_legacy_snapshot(path) do
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

  @spec replay_rotated_after(Path.t(), binary() | nil, acc, FileFrame.fold_fun(acc)) ::
          fold_result(acc)
        when acc: term()
  defp replay_rotated_after(root, rotated_through, acc, fun) do
    root
    |> rotated_paths()
    |> Enum.filter(&rotated_after?(&1, rotated_through))
    |> Enum.reduce_while({:ok, acc}, fn path, {:ok, current} ->
      case replay_path_fold(path, current, fun) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:halted, next} -> {:halt, {:halted, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec cutoff(map()) :: binary() | nil
  defp cutoff(manifest), do: Map.get(manifest, :rotated_through)

  @spec rotated_after?(Path.t(), binary() | nil) :: boolean()
  defp rotated_after?(_path, nil), do: true
  defp rotated_after?(path, cutoff), do: Path.basename(path) > cutoff

  @spec install_snapshot(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  defp install_snapshot(snapshot, temporary, opts) do
    previous = Path.join(Path.dirname(snapshot), "previous.term")

    with :ok <- preserve_valid_current(snapshot, previous, opts) do
      FramedLog.rename(temporary, snapshot, opts)
    end
  end

  @spec preserve_valid_current(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  defp preserve_valid_current(snapshot, previous, opts) do
    if valid_snapshot?(snapshot) do
      with :ok <- FramedLog.remove(previous, opts) do
        move_current_to_previous(snapshot, previous, opts)
      end
    else
      FramedLog.remove(snapshot, opts)
    end
  end

  @spec valid_snapshot?(Path.t()) :: boolean()
  defp valid_snapshot?(path) do
    if framed_snapshot?(path),
      do: match?({:ok, _manifest}, Snapshot.validate(path)),
      else: match?({:ok, _records}, read_legacy_snapshot(path))
  end

  @spec move_current_to_previous(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  defp move_current_to_previous(snapshot, previous, opts) do
    case FramedLog.rename(snapshot, previous, opts) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rotate_active_segment(Path.t(), keyword()) ::
          {:ok, Path.t() | nil} | {:error, term()}
  defp rotate_active_segment(root, opts) do
    active = active_path(root)
    rotated = Path.join([root, "segments", "compacted-#{System.system_time(:microsecond)}.smem"])

    rotation =
      case File.stat(active) do
        {:ok, %{size: size}} when size > 0 ->
          case FramedLog.rename(active, rotated, opts) do
            :ok -> {:ok, rotated}
            {:error, _reason} = error -> error
          end

        {:ok, _empty} ->
          case FramedLog.remove(active, opts) do
            :ok -> {:ok, nil}
            {:error, _reason} = error -> error
          end

        {:error, :enoent} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, reason}
      end

    with {:ok, rotated_path} <- rotation,
         :ok <- FramedLog.write_file(active, "", opts) do
      :ok = FramedLog.reset_sequence_counter({__MODULE__, :seq, active})
      {:ok, rotated_path}
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

  @spec latest_rotated_name(Path.t()) :: binary() | nil
  defp latest_rotated_name(root) do
    case List.last(rotated_paths(root)) do
      nil -> nil
      path -> Path.basename(path)
    end
  end

  @spec write_compacted_snapshot(
          Path.t(),
          Path.t(),
          [Record.t()] | nil,
          binary() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  defp write_compacted_snapshot(path, root, supplied_records, rotated_through, opts) do
    state = new_compaction_state()

    try do
      collector = fn frame, current ->
        case raw_record(frame) do
          %Record{} = record -> {:cont, absorb_compaction_record(record, current)}
          nil -> {:cont, current}
        end
      end

      with {:ok, state} <- replay_snapshot_fold(root, state, collector),
           state <- Enum.reduce(List.wrap(supplied_records), state, &absorb_compaction_record/2),
           :ok <- filter_compaction_records(state) do
        Snapshot.write_table(path, state.records, %{rotated_through: rotated_through}, opts)
      end
    after
      delete_compaction_state(state)
    end
  end

  defp new_compaction_state do
    %{
      position: 0,
      records: :ets.new(:compaction_records, [:ordered_set, :private, :compressed]),
      dedupe: :ets.new(:compaction_dedupe, [:set, :private]),
      commits: :ets.new(:compaction_commits, [:set, :private]),
      tombstones: :ets.new(:compaction_tombstones, [:set, :private]),
      markers: :ets.new(:compaction_erasure_markers, [:set, :private])
    }
  end

  defp delete_compaction_state(state) do
    state
    |> Map.drop([:position])
    |> Enum.each(fn {_name, table} ->
      if :ets.info(table) != :undefined, do: :ets.delete(table)
    end)

    :ok
  end

  defp absorb_compaction_record(%Record{} = record, state) do
    position = state.position + 1
    ordered_key = {record_timestamp(record), position}
    dedupe_key = {record.dedupe_key || record.id, record.family}

    case :ets.lookup(state.dedupe, dedupe_key) do
      [{^dedupe_key, previous_key}] -> :ets.delete(state.records, previous_key)
      [] -> :ok
    end

    :ets.insert(state.records, {ordered_key, record})
    :ets.insert(state.dedupe, {dedupe_key, ordered_key})
    %{state | position: position}
  end

  defp filter_compaction_records(state) do
    fold_compaction_records(state.records, fn
      _key, %Record{family: :batch_commits} = record ->
        if batch = compact_batch_id(record), do: :ets.insert(state.commits, {batch, true})

      _key, _record ->
        :ok
    end)

    fold_compaction_records(state.records, fn _key, record ->
      if compact_batch_committed?(record, state.commits) do
        collect_compaction_tombstone(record, state.tombstones)
        collect_compaction_marker(record, state.markers)
      end
    end)

    fold_compaction_records(state.records, fn key, record ->
      if not compact_record_visible?(record, state) do
        :ets.delete(state.records, key)
      end
    end)

    :ok
  end

  defp fold_compaction_records(table, fun),
    do: fold_compaction_records(table, :ets.first(table), fun)

  defp fold_compaction_records(_table, :"$end_of_table", _fun), do: :ok

  defp fold_compaction_records(table, key, fun) do
    next = :ets.next(table, key)

    case :ets.lookup(table, key) do
      [{^key, %Record{} = record}] -> fun.(key, record)
      [] -> :ok
    end

    fold_compaction_records(table, next, fun)
  end

  defp collect_compaction_tombstone(%Record{family: :tombstones} = record, tombstones) do
    case tombstone_target(record.payload) do
      {:ok, {family, id}} ->
        :ets.insert(tombstones, {{record.namespace, record.scope, family, id}, true})

      :error ->
        :ok
    end
  end

  defp collect_compaction_tombstone(_record, _tombstones), do: :ok

  defp collect_compaction_marker(%Record{family: :erasure_markers} = record, markers) do
    key = {record.namespace, record.scope}

    case :ets.lookup(markers, key) do
      [] -> :ets.insert(markers, {key, record})
      [{^key, current}] -> :ets.insert(markers, {key, latest_record(record, current)})
    end

    :ok
  end

  defp collect_compaction_marker(_record, _markers), do: :ok

  defp compact_record_visible?(%Record{family: :tombstones}, _state), do: false

  defp compact_record_visible?(%Record{} = record, state) do
    compact_batch_committed?(record, state.commits) and
      not compact_tombstoned?(record, state.tombstones) and
      not compact_erased?(record, state.markers)
  end

  defp compact_batch_committed?(%Record{batch_id: nil}, _commits), do: true

  defp compact_batch_committed?(%Record{batch_id: batch}, commits),
    do: :ets.member(commits, batch)

  defp compact_tombstoned?(record, tombstones) do
    :ets.member(
      tombstones,
      {record.namespace, record.scope, record.family, payload_id(record.payload)}
    )
  end

  defp compact_erased?(%Record{family: :erasure_markers}, _markers), do: false

  defp compact_erased?(record, markers) do
    key = {record.namespace, record.scope}

    case :ets.lookup(markers, key) do
      [{^key, marker}] -> erased_by_marker?(record, marker)
      [] -> false
    end
  end

  defp compact_batch_id(%Record{payload: payload}) when is_map(payload),
    do: map_value(payload, :batch_id)

  defp compact_batch_id(_record), do: nil

  @spec raw_record(term()) :: Record.t() | nil
  defp raw_record({_sequence, _timestamp, %Record{} = record}), do: Record.upgrade(record)
  defp raw_record(%Record{} = record), do: Record.upgrade(record)
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

  @spec record_timestamp(Record.t()) :: integer()
  defp record_timestamp(%Record{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp record_timestamp(_record), do: 0

  @spec latest_record(Record.t(), Record.t()) :: Record.t()
  defp latest_record(candidate, current) do
    if record_timestamp(candidate) >= record_timestamp(current), do: candidate, else: current
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
