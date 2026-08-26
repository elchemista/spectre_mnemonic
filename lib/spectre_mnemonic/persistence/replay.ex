defmodule SpectreMnemonic.Persistence.Replay do
  @moduledoc false

  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Config
  alias SpectreMnemonic.Persistence.RecordBuilder
  alias SpectreMnemonic.Persistence.Store.Record

  @type store :: Config.store()
  @type state :: %{position: non_neg_integer(), records: map()}

  @spec records([store()]) :: [Record.t()]
  def records(stores) do
    stores
    |> Enum.reduce(new_state(), &replay_store_into/2)
    |> state_records()
    |> committed_batches()
    |> apply_tombstones()
    |> apply_erasure_markers()
    |> hide_batch_markers()
  end

  @spec checked([store()]) :: {:ok, [Record.t()]} | {:error, [map()]}
  def checked(stores) do
    stores
    |> Enum.reduce_while({:ok, new_state()}, fn store, {:ok, state} ->
      case replay_store_into_checked(store, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, [failure(store, reason)]}}
      end
    end)
    |> case do
      {:ok, state} ->
        records =
          state
          |> state_records()
          |> committed_batches()
          |> apply_tombstones()
          |> apply_erasure_markers()

        {:ok, records}

      {:error, failures} ->
        {:error, failures}
    end
  end

  @doc false
  @spec checked_fold(
          [store()],
          acc,
          (Record.t(), acc -> {:cont, acc} | {:halt, acc}),
          (Record.t() -> boolean())
        ) :: {:ok, acc} | {:error, [map()]}
        when acc: term()
  def checked_fold(stores, acc, fun, filter \\ fn _record -> true end)
      when is_list(stores) and is_function(fun, 2) and is_function(filter, 1) do
    state = new_fold_state()

    try do
      stores
      |> Enum.reduce_while({:ok, state}, fn store, {:ok, current} ->
        case replay_store_into_fold_checked(store, current) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, [failure(store, reason)]}}
        end
      end)
      |> case do
        {:ok, complete} -> fold_visible_state(complete, acc, fun, filter)
        {:error, failures} -> {:error, failures}
      end
    after
      delete_fold_state(state)
    end
  end

  @spec fold_visible(
          [Record.t()],
          keyword(),
          acc,
          (Record.t(), acc -> {:cont, acc} | {:halt, acc})
        ) :: {:ok, acc}
        when acc: term()
  def fold_visible(records, opts, acc, fun) do
    records
    |> Enum.filter(&Scope.match?(&1, opts))
    |> Enum.reduce_while(acc, fn record, current ->
      case fun.(record, current) do
        {:cont, next} -> {:cont, next}
        {:halt, next} -> {:halt, next}
      end
    end)
    |> then(&{:ok, &1})
  end

  @spec committed_batches([Record.t()]) :: [Record.t()]
  def committed_batches(records) do
    committed =
      records
      |> Enum.filter(&(&1.family == :batch_commits))
      |> Enum.map(&batch_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(records, fn record ->
      is_nil(record.batch_id) or MapSet.member?(committed, record.batch_id)
    end)
  end

  @spec hide_batch_markers([Record.t()]) :: [Record.t()]
  def hide_batch_markers(records),
    do: Enum.reject(records, &(&1.family in [:batch_begins, :batch_commits]))

  @spec apply_erasure_markers([Record.t()]) :: [Record.t()]
  def apply_erasure_markers(records) do
    markers =
      records
      |> Enum.filter(&(&1.family == :erasure_markers))
      |> Enum.reduce(%{}, &put_latest_erasure_marker/2)

    Enum.reject(records, &erased_record?(&1, markers))
  end

  defp replay_store_into_checked(store, state) do
    capabilities = Config.safe_capabilities(store)

    cond do
      replay_fold_supported?(store, capabilities) -> replay_store_fold_checked(store, state)
      replay_list_supported?(store, capabilities) -> replay_store_list_checked(store, state)
      true -> {:error, :replay_capability_unavailable}
    end
  end

  defp replay_store_into_fold_checked(store, state) do
    capabilities = Config.safe_capabilities(store)

    cond do
      replay_fold_supported?(store, capabilities) -> replay_store_into_ets(store, state)
      replay_list_supported?(store, capabilities) -> replay_list_into_ets(store, state)
      true -> {:error, :replay_capability_unavailable}
    end
  end

  defp replay_store_into_ets(store, state) do
    case store.adapter.replay_fold(store.opts, state, fn frame, current ->
           {:cont, absorb_fold_frame(frame, current)}
         end) do
      {:ok, next} -> {:ok, next}
      {:halted, next} -> {:ok, next}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_replay_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp replay_list_into_ets(store, state) do
    case store.adapter.replay(store.opts) do
      {:ok, frames} when is_list(frames) ->
        {:ok, Enum.reduce(frames, state, &absorb_fold_frame/2)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_replay_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp replay_store_fold_checked(store, state) do
    case store.adapter.replay_fold(store.opts, state, fn frame, acc ->
           {:cont, absorb_frame(frame, acc)}
         end) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_replay_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp replay_store_list_checked(store, state) do
    case store.adapter.replay(store.opts) do
      {:ok, frames} when is_list(frames) -> {:ok, Enum.reduce(frames, state, &absorb_frame/2)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_replay_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp failure(store, reason), do: %{store: store.id, role: store.role, reason: reason}
  defp new_state, do: %{position: 0, records: %{}}

  defp replay_store_into(store, state) do
    capabilities = Config.safe_capabilities(store)

    cond do
      replay_fold_supported?(store, capabilities) -> replay_store_fold(store, state)
      replay_list_supported?(store, capabilities) -> replay_store_list(store, state)
      true -> state
    end
  end

  defp replay_fold_supported?(store, capabilities),
    do: :replay_fold in capabilities and function_exported?(store.adapter, :replay_fold, 3)

  defp replay_list_supported?(store, capabilities),
    do: :replay in capabilities and function_exported?(store.adapter, :replay, 1)

  defp replay_store_fold(store, state) do
    case store.adapter.replay_fold(store.opts, state, fn frame, acc ->
           {:cont, absorb_frame(frame, acc)}
         end) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  rescue
    _exception -> state
  catch
    _kind, _reason -> state
  end

  defp replay_store_list(store, state) do
    case store.adapter.replay(store.opts) do
      {:ok, frames} -> Enum.reduce(frames, state, &absorb_frame/2)
      {:error, _reason} -> state
    end
  rescue
    _exception -> state
  catch
    _kind, _reason -> state
  end

  defp absorb_frame(frame, state) do
    case frame_record(frame) do
      %Record{} = record ->
        position = state.position + 1

        %{
          position: position,
          records: Map.put(state.records, record.dedupe_key, {position, record})
        }

      _other ->
        state
    end
  end

  defp new_fold_state do
    %{
      position: 0,
      records: :ets.new(:replay_records, [:ordered_set, :private, :compressed]),
      dedupe: :ets.new(:replay_dedupe, [:set, :private])
    }
  end

  defp delete_fold_state(state) do
    Enum.each([state.records, state.dedupe], fn table ->
      if :ets.info(table) != :undefined, do: :ets.delete(table)
    end)

    :ok
  end

  defp absorb_fold_frame(frame, state) do
    case frame_record(frame) do
      %Record{} = record ->
        position = state.position + 1
        key = fold_dedupe_key(record)

        case :ets.lookup(state.dedupe, key) do
          [{^key, previous_position}] -> :ets.delete(state.records, previous_position)
          [] -> :ok
        end

        :ets.insert(state.records, {position, record})
        :ets.insert(state.dedupe, {key, position})
        %{state | position: position}

      _other ->
        state
    end
  end

  defp fold_dedupe_key(%Record{dedupe_key: key}) when not is_nil(key), do: {:dedupe, key}

  defp fold_dedupe_key(%Record{} = record),
    do: {:record, record.namespace, record.scope, record.family, record.id}

  defp fold_visible_state(state, acc, fun, filter) do
    visibility = new_visibility_state()

    try do
      :ok = collect_committed_batches(state.records, visibility.commits)
      :ok = collect_lifecycle(state.records, visibility)

      fold_ordered(state.records, acc, fn record, current ->
        if fold_record_visible?(record, visibility) and filter.(record) do
          fun.(record, current)
        else
          {:cont, current}
        end
      end)
    after
      delete_visibility_state(visibility)
    end
  end

  defp new_visibility_state do
    %{
      commits: :ets.new(:replay_commits, [:set, :private]),
      tombstones: :ets.new(:replay_tombstones, [:set, :private]),
      markers: :ets.new(:replay_erasure_markers, [:set, :private])
    }
  end

  defp delete_visibility_state(visibility) do
    Enum.each(visibility, fn {_name, table} -> :ets.delete(table) end)
    :ok
  end

  defp collect_committed_batches(records, commits) do
    _result =
      fold_ordered(records, :ok, fn
        %Record{family: :batch_commits} = record, :ok ->
          if id = batch_id(record), do: :ets.insert(commits, {id, true})
          {:cont, :ok}

        _record, :ok ->
          {:cont, :ok}
      end)

    :ok
  end

  defp collect_lifecycle(records, visibility) do
    _result =
      fold_ordered(records, :ok, fn record, :ok ->
        if fold_batch_committed?(record, visibility.commits) do
          collect_tombstone(record, visibility.tombstones)
          collect_erasure_marker(record, visibility.markers)
        end

        {:cont, :ok}
      end)

    :ok
  end

  defp collect_tombstone(%Record{family: :tombstones} = record, tombstones) do
    case RecordBuilder.tombstone_target(record.payload) do
      {:ok, {family, id}} ->
        :ets.insert(tombstones, {{record.namespace, record.scope, family, id}, true})

      :error ->
        :ok
    end
  end

  defp collect_tombstone(_record, _tombstones), do: :ok

  defp collect_erasure_marker(%Record{family: :erasure_markers} = record, markers) do
    key = {record.namespace, record.scope}

    case :ets.lookup(markers, key) do
      [] -> :ets.insert(markers, {key, record})
      [{^key, current}] -> :ets.insert(markers, {key, latest_record(record, current)})
    end

    :ok
  end

  defp collect_erasure_marker(_record, _markers), do: :ok

  defp fold_record_visible?(record, visibility) do
    fold_batch_committed?(record, visibility.commits) and
      not fold_tombstoned?(record, visibility.tombstones) and
      not fold_erased?(record, visibility.markers)
  end

  defp fold_batch_committed?(%Record{batch_id: nil}, _commits), do: true
  defp fold_batch_committed?(%Record{batch_id: id}, commits), do: :ets.member(commits, id)

  defp fold_tombstoned?(%Record{} = record, tombstones) do
    id = RecordBuilder.payload_id(record.payload)
    :ets.member(tombstones, {record.namespace, record.scope, record.family, id})
  end

  defp fold_erased?(%Record{family: :erasure_markers}, _markers), do: false

  defp fold_erased?(%Record{} = record, markers) do
    key = {record.namespace, record.scope}

    case :ets.lookup(markers, key) do
      [{^key, marker}] -> erased_by_marker?(record, marker)
      [] -> false
    end
  end

  defp fold_ordered(table, acc, fun), do: fold_ordered(table, :ets.first(table), acc, fun)

  defp fold_ordered(_table, :"$end_of_table", acc, _fun), do: {:ok, acc}

  defp fold_ordered(table, key, acc, fun) do
    next = :ets.next(table, key)

    case :ets.lookup(table, key) do
      [{^key, record}] ->
        case fun.(record, acc) do
          {:cont, next_acc} -> fold_ordered(table, next, next_acc, fun)
          {:halt, next_acc} -> {:ok, next_acc}
        end

      [] ->
        fold_ordered(table, next, acc, fun)
    end
  end

  defp state_records(state) do
    state.records
    |> Map.values()
    |> Enum.sort_by(fn {position, _record} -> position end)
    |> Enum.map(fn {_position, record} -> record end)
  end

  defp frame_record({_sequence, _timestamp, %Record{} = record}), do: Record.upgrade(record)

  defp frame_record({_sequence, _timestamp, {family, payload}}),
    do: RecordBuilder.build(family, :put, payload, [])

  defp frame_record(%Record{} = record), do: Record.upgrade(record)
  defp frame_record(other), do: other

  defp batch_id(%Record{payload: payload}) when is_map(payload),
    do: Map.get(payload, :batch_id, Map.get(payload, "batch_id"))

  defp batch_id(_record), do: nil

  defp apply_tombstones(records) do
    forgotten =
      records
      |> Enum.filter(&(&1.family == :tombstones))
      |> Enum.flat_map(fn record ->
        case RecordBuilder.tombstone_target(record.payload) do
          {:ok, {family, id}} -> [{record.namespace, record.scope, family, id}]
          :error -> []
        end
      end)
      |> MapSet.new()

    Enum.reject(records, fn record ->
      payload_id = RecordBuilder.payload_id(record.payload)

      record.family != :tombstones and
        MapSet.member?(forgotten, {record.namespace, record.scope, record.family, payload_id})
    end)
  end

  defp put_latest_erasure_marker(marker, markers) do
    key = {marker.namespace, marker.scope}

    case Map.fetch(markers, key) do
      :error -> Map.put(markers, key, marker)
      {:ok, current} -> Map.put(markers, key, latest_record(marker, current))
    end
  end

  defp latest_record(candidate, current) do
    if record_time(candidate) >= record_time(current), do: candidate, else: current
  end

  defp erased_record?(record, markers) do
    marker = Map.get(markers, {record.namespace, record.scope})
    not is_nil(marker) and record.family != :erasure_markers and erased_by_marker?(record, marker)
  end

  defp erased_by_marker?(record, marker) do
    case RecordBuilder.map_value(marker.payload, :generation) do
      generation when is_binary(generation) ->
        RecordBuilder.map_value(record.metadata, :erasure_generation) != generation

      _legacy_marker ->
        record_time(record) <= record_time(marker)
    end
  end

  defp record_time(%Record{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp record_time(_record), do: 0
end
