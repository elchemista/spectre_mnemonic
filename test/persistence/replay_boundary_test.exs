defmodule SpectreMnemonic.Persistence.ReplayBoundaryTest do
  use ExUnit.Case, async: true

  alias SpectreMnemonic.Persistence.Replay
  alias SpectreMnemonic.Persistence.Store.Record

  defmodule ListStore do
    def capabilities(_opts), do: [:replay]
    def replay(opts), do: result(Keyword.fetch!(opts, :result))

    defp result({:raise, message}), do: raise(message)
    defp result({:throw, reason}), do: throw(reason)
    defp result(result), do: result
  end

  defmodule FoldStore do
    def capabilities(_opts), do: [:replay_fold]

    def replay_fold(opts, acc, fun) do
      case Keyword.fetch!(opts, :result) do
        {:frames, frames} ->
          fold_frames(frames, acc, fun)

        {:raise, message} ->
          raise message

        {:throw, reason} ->
          throw(reason)

        result ->
          result
      end
    end

    defp fold_frames(frames, acc, fun) do
      Enum.reduce_while(frames, {:ok, acc}, fn frame, {:ok, current} ->
        case fun.(frame, current) do
          {:cont, next} -> {:cont, {:ok, next}}
          {:halt, next} -> {:halt, {:halted, next}}
        end
      end)
    end
  end

  defmodule NoReplay do
    def capabilities(_opts), do: []
  end

  test "checked list and streaming replay reject unavailable and malformed adapter responses" do
    for adapter <- [ListStore, FoldStore],
        {result, reason} <- [
          {{:error, :offline}, :offline},
          {:invalid, {:unexpected_replay_result, :invalid}},
          {{:raise, "adapter failed"}, {RuntimeError, "adapter failed"}},
          {{:throw, :offline}, {:throw, :offline}}
        ] do
      store = %{id: :custom, role: :primary, adapter: adapter, opts: [result: result]}

      assert {:error, [%{store: :custom, reason: ^reason}]} = Replay.checked([store])

      assert {:error, [%{store: :custom, reason: ^reason}]} =
               Replay.checked_fold([store], [], fn record, acc -> {:cont, [record | acc]} end)
    end

    unavailable = %{id: :missing, role: :primary, adapter: NoReplay, opts: []}
    assert {:error, [%{reason: :replay_capability_unavailable}]} = Replay.checked([unavailable])

    assert {:error, [%{reason: :replay_capability_unavailable}]} =
             Replay.checked_fold([unavailable], [], fn _, acc -> {:cont, acc} end)
  end

  test "streaming replay deduplicates records and hides incomplete batches" do
    old = record("same", "old")
    replacement = %{old | id: "updated", payload: %{id: "old", text: "latest"}}
    uncommitted = %{record("pending", "pending") | batch_id: "incomplete"}
    visible = record("visible", "visible")
    frames = Enum.with_index([old, replacement, uncommitted, visible], 1)
    frames = Enum.map(frames, fn {record, seq} -> {seq, 0, record} end)
    store = %{id: :source, adapter: FoldStore, opts: [result: {:frames, frames}]}

    assert {:ok, replayed} =
             Replay.checked_fold([store], [], fn record, acc -> {:cont, [record | acc]} end)

    assert Enum.map(replayed, & &1.id) == ["visible", "updated"]

    assert {:ok, [first]} =
             Replay.checked_fold([store], [], fn record, _acc -> {:halt, [record]} end)

    assert first.id == "updated"

    assert {:ok, [^visible]} =
             Replay.checked_fold(
               [store],
               [],
               fn record, acc -> {:cont, [record | acc]} end,
               &(&1.id == "visible")
             )

    assert {:ok, [^visible]} =
             Replay.fold_visible(
               [visible, %{old | scope: :other}],
               [engine_namespace: visible.namespace, namespace: visible.namespace, scope: :owner],
               [],
               fn
                 record, _acc -> {:halt, [record]}
               end
             )
  end

  test "atomic replay honors committed batches, latest erasure markers and malformed tombstones" do
    now = DateTime.utc_now()
    old = %{record("old-version", "old-version") | inserted_at: nil, dedupe_key: nil}

    fresh = %{
      record("fresh-version", "fresh-version")
      | inserted_at: DateTime.add(now, 1, :second),
        dedupe_key: nil
    }

    marker = %{
      record("erasure-1", "erasure-1")
      | family: :erasure_markers,
        inserted_at: now,
        payload: %{erased_at: now}
    }

    previous_marker = %{
      marker
      | id: "erasure-0",
        dedupe_key: "erasure-0",
        inserted_at: DateTime.add(now, -1, :second)
    }

    committed = %{record("committed", "committed") | batch_id: "batch", scope: :neighbor}

    commit = %{
      record("commit", "commit")
      | family: :batch_commits,
        payload: %{batch_id: "batch"},
        scope: :neighbor
    }

    invalid_tombstone = %{
      record("invalid-tombstone", "invalid-tombstone")
      | family: :tombstones,
        payload: :invalid
    }

    frames = [old, fresh, marker, previous_marker, committed, commit, invalid_tombstone, :invalid]
    store = %{id: :source, role: :primary, adapter: ListStore, opts: [result: {:ok, frames}]}

    assert {:ok, records} =
             Replay.checked_fold(
               [store],
               [],
               fn record, acc ->
                 {:cont, [record | acc]}
               end,
               &(&1.family == :moments)
             )

    assert Enum.sort(Enum.map(records, & &1.id)) == ["committed", "fresh-version"]

    assert Enum.reject(
             Replay.apply_erasure_markers([old, fresh, marker, previous_marker]),
             &(&1.family == :erasure_markers)
           ) == [fresh]
  end

  test "best effort replay skips broken stores and retains the healthy replica" do
    healthy = record("healthy", "healthy")

    fallback = %{
      id: :fallback,
      role: :replica,
      adapter: ListStore,
      opts: [result: {:ok, [healthy]}]
    }

    for adapter <- [ListStore, FoldStore],
        result <- [
          {:error, :offline},
          {:raise, "offline"},
          {:throw, :offline}
        ] do
      broken = %{id: :broken, role: :primary, adapter: adapter, opts: [result: result]}
      assert Replay.records([broken, fallback]) == [healthy]
    end

    assert Replay.records([
             %{id: :unsupported, role: :primary, adapter: NoReplay, opts: []},
             fallback
           ]) == [healthy]
  end

  defp record(id, memory_id) do
    %Record{
      id: id,
      namespace: "replay-boundary",
      scope: :owner,
      family: :moments,
      operation: :put,
      dedupe_key: memory_id,
      payload: %{id: memory_id},
      inserted_at: DateTime.utc_now()
    }
  end
end
