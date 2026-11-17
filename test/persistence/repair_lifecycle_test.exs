defmodule SpectreMnemonic.Persistence.RepairLifecycleTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Durable.Index, as: DurableIndex

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.PrimaryWriter
  alias SpectreMnemonic.Persistence.RepairJob
  alias SpectreMnemonic.Persistence.RepairQueue
  alias SpectreMnemonic.Persistence.Runtime
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Recall.Index, as: RecallIndex

  defmodule Replica do
    def put(record, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:replica_attempt, record.id})

      case Keyword.fetch!(opts, :result) do
        {:raise, message} -> raise message
        {:throw, reason} -> throw(reason)
        result -> result
      end
    end
  end

  test "bounded replica retries complete or retain their error without crashing the queue" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "bounded-repair",
         namespace: "bounded-repair",
         persistent_memory: [repair: [base_backoff: 1, max_attempts: 1]]}
      )

    {:ok, runtime} = Engine.resolve(engine)

    for {result, expected} <- [
          {:ok, nil},
          {{:ok, :stored}, nil},
          {:invalid, {:unexpected_adapter_result, :invalid}},
          {{:raise, "replica failed"}, {RuntimeError, "replica failed"}},
          {{:throw, :replica_offline}, {:throw, :replica_offline}}
        ] do
      id = inspect(result)

      job = %RepairJob{
        id: id,
        commit_id: id,
        target_store: :replica,
        record: %Record{id: id, storage_id: runtime.config.storage_id},
        store: %{adapter: Replica, opts: [test_pid: self(), result: result]}
      }

      assert :ok = RepairQueue.enqueue(job)
      assert :ok = RepairQueue.failed(runtime.config.storage_id, id, :replica, :offline)
      assert_receive {:replica_attempt, ^id}, 1_000
      retried = Enum.find(RepairQueue.jobs(), &(&1.id == id))
      assert retried.attempts == 1
      assert retried.last_error == expected
      assert retried.status == if(is_nil(expected), do: :completed, else: :pending)
    end

    assert %{total: 5, completed: 2, pending: 3} = RepairQueue.summary(runtime.config.storage_id)
    assert {:ok, %{repair_jobs: %{total: 5}}} = Engine.health(engine)
  end

  test "retired engines expose unavailable queues and never write into the default engine" do
    engine =
      start_supervised!({Engine, storage_id: "retired-storage", namespace: "retired-engine"})

    {:ok, runtime} = Engine.resolve(engine)
    ref = runtime.config.ref
    assert {:ok, ^runtime} = Engine.resolve_internal_namespace(runtime.config.internal_namespace)
    assert {:ok, ^runtime} = Engine.resolve_storage_id(runtime.config.storage_id)
    assert :ok = stop_supervised({Engine, runtime.config.storage_id})

    assert %{running?: false, queue_depth: 0} = PrimaryWriter.status(ref)
    assert {:error, :mnemonic_engine_required} = PrimaryWriter.call(ref, :ignored, 1_000, [])
    assert %{running?: false, operation: :unavailable} = Runtime.status(ref)
    assert {:error, :mnemonic_engine_required} = Runtime.call(ref, :ignored, 1_000)
    assert :ok = Runtime.invalidate(ref)
    assert %{total: 0, pending: 0, completed: 0} = RepairQueue.summary(runtime.config.storage_id)
    assert :ok = RepairQueue.delivered(runtime.config.storage_id, "missing", :replica)
    assert :ok = RepairQueue.failed(nil, "missing", :replica, :offline)

    assert {:error, _} =
             SpectreMnemonic.signal("must not use default storage", engine: ref, persist?: true)

    assert {:error, _} = Manager.get(:moments, "missing", engine: engine)
    assert {:error, _} = Manager.append(:moments, %{id: "must-not-write"}, engine: engine)
    assert DurableIndex.server(ref) == nil
    assert DurableIndex.server(engine_ref: ref) == nil

    assert %{running?: false, documents: 0} =
             DurableIndex.status(runtime.config.internal_namespace)

    assert {:error, :durable_index_unavailable} =
             DurableIndex.search_diagnosed("private", engine_ref: ref)

    assert {:ok, []} = DurableIndex.search("private", engine_ref: ref)
    assert :ok = DurableIndex.rebuild(engine_ref: ref)
    assert RecallIndex.tables(engine_ref: ref) == nil

    assert Focus.moments() == []
  end
end
