defmodule SpectreMnemonic.Engine.MultiEngineTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.HotStore
  alias SpectreMnemonic.Engine.PartitionExecutor
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Persistence.StoreWriter

  defmodule ViaRegistry do
  end

  defmodule OfflineEmbedding do
    def embed(_input, _opts), do: {:error, :embedding_offline}
  end

  test "two engines with the same public namespace keep memory and storage separate" do
    root = Path.join(System.tmp_dir!(), "mnemonic-multi-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    engine_a =
      start_supervised!(
        {Engine,
         name: __MODULE__.EngineA,
         storage_id: "customer-a",
         namespace: "shared-public-name",
         data_root: root}
      )

    engine_b =
      start_supervised!(
        {Engine,
         name: __MODULE__.EngineB,
         storage_id: "customer-b",
         namespace: "shared-public-name",
         data_root: root}
      )

    assert {:ok, packet_a} =
             SpectreMnemonic.remember("alpha remembers apricots",
               engine: __MODULE__.EngineA,
               scope: {:customer, "42"}
             )

    assert {:ok, packet_b} =
             SpectreMnemonic.remember("beta remembers blueberries",
               engine: __MODULE__.EngineB,
               scope: {:customer, "42"}
             )

    assert packet_a.root.namespace == "shared-public-name"
    assert packet_b.root.namespace == "shared-public-name"

    assert {:ok, recall_a} =
             SpectreMnemonic.recall("apricots blueberries",
               engine: engine_a,
               scope: {:customer, "42"}
             )

    assert Enum.any?(recall_a.moments, &String.contains?(&1.text, "apricots"))
    refute Enum.any?(recall_a.moments, &String.contains?(&1.text, "blueberries"))

    assert {:ok, recall_b} =
             SpectreMnemonic.recall("apricots blueberries",
               engine: engine_b,
               scope: {:customer, "42"}
             )

    assert Enum.any?(recall_b.moments, &String.contains?(&1.text, "blueberries"))
    refute Enum.any?(recall_b.moments, &String.contains?(&1.text, "apricots"))

    {:ok, runtime_a} = Engine.resolve(__MODULE__.EngineA)
    {:ok, runtime_b} = Engine.resolve(__MODULE__.EngineB)

    refute runtime_a.config.internal_namespace == runtime_b.config.internal_namespace
    refute runtime_a.config.data_root == runtime_b.config.data_root

    assert :ok = stop_supervised({Engine, "customer-a"})

    assert {:ok, _packet} =
             SpectreMnemonic.recall("blueberries",
               engine: __MODULE__.EngineB,
               scope: {:customer, "42"}
             )

    assert {:error, {:mnemonic_engine_not_found, __MODULE__.EngineA}} =
             Engine.resolve(__MODULE__.EngineA)

    refute Process.alive?(engine_a)
    assert Process.alive?(engine_b)
  end

  test "engine references support stable refs, pids, names, and via tuples" do
    start_supervised!({Registry, keys: :unique, name: ViaRegistry})
    via = {:via, Registry, {ViaRegistry, :memory}}

    pid =
      start_supervised!(
        {Engine,
         name: via,
         ref: %Ref{id: "via-ref"},
         storage_id: "via-storage",
         namespace: "via-namespace"}
      )

    assert {:ok, runtime_by_ref} = Engine.resolve(%Ref{id: "via-ref"})
    assert {:ok, runtime_by_pid} = Engine.resolve(pid)
    assert {:ok, runtime_by_name} = Engine.resolve(via)
    assert runtime_by_ref == runtime_by_pid
    assert runtime_by_pid == runtime_by_name
  end

  test "one storage identity cannot have two live owners in the VM" do
    first =
      start_supervised!(
        {Engine,
         name: __MODULE__.StorageOwner, storage_id: "unique-storage-owner", namespace: "owner-one"}
      )

    assert {:error, reason} =
             Engine.start_link(
               name: __MODULE__.DuplicateStorageOwner,
               storage_id: "unique-storage-owner",
               namespace: "owner-two"
             )

    assert inspect(reason) =~ "mnemonic_engine_already_started"
    assert Process.alive?(first)
  end

  test "stopping an engine terminates its active partition and store executors" do
    engine =
      start_supervised!(
        {Engine, storage_id: "executor-lifecycle", namespace: "executor-lifecycle-namespace"}
      )

    {:ok, runtime} = Engine.resolve(engine)
    parent = self()

    partition_task =
      Task.async(fn ->
        key =
          {:memory_partition, runtime.config.ref, runtime.config.internal_namespace,
           {:customer, "42"}}

        PartitionExecutor.trans(key, fn ->
          send(parent, {:active_executor, :partition, self()})
          Process.sleep(:infinity)
        end)
      end)

    store_task =
      Task.async(fn ->
        StoreWriter.trans(
          {:lifecycle_store, runtime.config.storage_id},
          fn ->
            send(parent, {:active_executor, :store, self()})
            Process.sleep(:infinity)
          end,
          engine_ref: runtime.config.ref
        )
      end)

    assert_receive {:active_executor, :partition, partition_executor}
    assert_receive {:active_executor, :store, store_executor}

    partition_monitor = Process.monitor(partition_executor)
    store_monitor = Process.monitor(store_executor)

    assert :ok = stop_supervised({Engine, "executor-lifecycle"})
    assert_receive {:DOWN, ^partition_monitor, :process, ^partition_executor, :shutdown}
    assert_receive {:DOWN, ^store_monitor, :process, ^store_executor, :shutdown}

    assert {:error, {:partition_executor_crashed, :shutdown}} = Task.await(partition_task)
    assert {:error, {:store_writer_crashed, :shutdown}} = Task.await(store_task)
  end

  test "restarting RuntimeOwner replaces runtime handles and aborts stale executors" do
    engine =
      start_supervised!(
        {Engine, storage_id: "runtime-owner-restart", namespace: "runtime-owner-restart"}
      )

    {:ok, runtime} = Engine.resolve(engine)
    {:ok, old_tables} = HotStore.tables(runtime.config.ref)
    parent = self()

    partition_task =
      Task.async(fn ->
        key =
          {:memory_partition, runtime.config.ref, runtime.config.internal_namespace,
           {:customer, "restart"}}

        PartitionExecutor.trans(key, fn ->
          send(parent, {:runtime_owner_executor, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:runtime_owner_executor, executor}
    executor_monitor = Process.monitor(executor)

    Process.exit(runtime.owner, :kill)

    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, :shutdown}

    assert {:ok, restarted} = await_runtime(engine, runtime.owner, 100)
    assert restarted.config.ref == runtime.config.ref
    refute restarted.owner == runtime.owner

    assert {:ok, new_tables} = HotStore.tables(restarted.config.ref)

    Enum.each(old_tables, fn {name, old_table} ->
      assert :ets.info(old_table) == :undefined
      refute Map.fetch!(new_tables, name) == old_table
    end)

    assert {:error, {:partition_executor_crashed, :shutdown}} = Task.await(partition_task)

    assert {:ok, _result} =
             SpectreMnemonic.signal("the restarted engine accepts new work", engine: engine)
  end

  test "named engines reject per-call replacement of infrastructure options" do
    pid =
      start_supervised!(
        {Engine,
         storage_id: "locked-config", namespace: "locked-namespace", limits: [max_candidates: 8]}
      )

    {:ok, runtime} = Engine.resolve(pid)

    assert {:ok, packet} =
             SpectreMnemonic.remember("configuration remains engine-owned",
               engine: pid,
               namespace: "attacker-namespace",
               data_root: "/tmp/not-the-engine-root",
               persistent_memory: [stores: []],
               max_candidates: 80
             )

    assert packet.root.namespace == "locked-namespace"
    assert runtime.config.limits.max_candidates == 8
  end

  test "health reports bounded runtime state without exposing memory content" do
    engine =
      start_supervised!({Engine, storage_id: "health-engine", namespace: "health-namespace"})

    assert {:ok, _result} =
             SpectreMnemonic.signal("private phrase must never enter health", engine: engine)

    assert {:ok, health} = SpectreMnemonic.health(engine)
    assert health.running?
    assert health.projection.healthy?
    assert health.queues.store.queue_limit > 0
    assert health.repair_jobs.pending >= 0
    assert health.durable_index.running?
    assert health.stores.local_file.status == :ok
    assert health.stores.local_file.contract == :conformant
    refute inspect(health) =~ "private phrase"
  end

  test "available recall returns diagnostics while strict recall fails closed" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "diagnostic-engine",
         namespace: "diagnostic-namespace",
         embedding: [adapter: OfflineEmbedding]}
      )

    assert {:ok, _result} =
             SpectreMnemonic.signal("lexical fallback remains available", engine: engine)

    assert {:ok, packet} =
             SpectreMnemonic.recall("lexical fallback", engine: engine, consistency: :available)

    assert packet.diagnostics.completeness == :partial
    assert packet.diagnostics.sources.hot_vector == {:degraded, :embedding_offline}
    assert packet.diagnostics.candidates.final >= 1

    assert {:error, {:mnemonic_recall_incomplete, failures}} =
             SpectreMnemonic.recall("lexical fallback",
               engine: engine,
               consistency: :strict,
               required_sources: [:hot_vector]
             )

    assert failures.hot_vector == {:degraded, :embedding_offline}
  end

  defp await_runtime(_engine, _old_owner, 0), do: {:error, :runtime_not_restarted}

  defp await_runtime(engine, old_owner, attempts) do
    case Engine.resolve(engine) do
      {:ok, %{owner: owner} = runtime} when owner != old_owner ->
        {:ok, runtime}

      _missing_or_old ->
        Process.sleep(10)
        await_runtime(engine, old_owner, attempts - 1)
    end
  end
end
