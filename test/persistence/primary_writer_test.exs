defmodule SpectreMnemonic.Persistence.PrimaryWriterTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Context
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.RepairQueue
  alias SpectreMnemonic.Persistence.Store.File, as: FileStore

  defmodule BlockingPrimary do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl true
    def capabilities(_opts), do: [:append, :replay]

    @impl true
    def put(_record, opts) do
      gate = Keyword.fetch!(opts, :gate)

      case :atomics.compare_exchange(gate, 1, 0, 1) do
        :ok ->
          ref = Keyword.fetch!(opts, :ref)
          send(Keyword.fetch!(opts, :test_pid), {:primary_entered, ref, self()})

          receive do
            {:release_primary, ^ref} -> :ok
          after
            2_000 -> {:error, :primary_release_timeout}
          end

        _already_entered ->
          :ok
      end
    end

    @impl true
    def replay(_opts), do: {:ok, []}
  end

  defmodule FailingReplica do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl true
    def capabilities(_opts), do: [:append]

    @impl true
    def put(_record, _opts), do: {:error, :replica_offline}
  end

  test "different engines commit through independent primary writers" do
    gate_a = :atomics.new(1, signed: false)
    gate_b = :atomics.new(1, signed: false)
    engine_a = start_engine("writer-a", gate_a, :writer_a)
    engine_b = start_engine("writer-b", gate_b, :writer_b)

    task_a = append_async(engine_a, "a")
    task_b = append_async(engine_b, "b")

    assert_receive {:primary_entered, :writer_a, writer_a}
    assert_receive {:primary_entered, :writer_b, writer_b}
    refute writer_a == writer_b

    send(writer_a, {:release_primary, :writer_a})
    send(writer_b, {:release_primary, :writer_b})

    assert {:ok, _receipt} = Task.await(task_a, 1_000)
    assert {:ok, _receipt} = Task.await(task_b, 1_000)
  end

  test "primary-writer admission is bounded per engine" do
    gate = :atomics.new(1, signed: false)
    engine = start_engine("writer-bounded", gate, :bounded, max_store_queue: 1)

    first = append_async(engine, "first")
    assert_receive {:primary_entered, :bounded, writer}

    queued = for index <- 1..4, do: append_async(engine, "queued-#{index}")
    Process.sleep(25)
    send(writer, {:release_primary, :bounded})

    results = Enum.map([first | queued], &Task.await(&1, 1_000))

    assert Enum.any?(results, &match?({:error, {:queue_full, :store}}, &1))
    assert Enum.any?(results, &match?({:ok, _receipt}, &1))
  end

  test "durable repair jobs rehydrate after the in-memory queue is lost" do
    root =
      Path.join(System.tmp_dir!(), "mnemonic-repair-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    engine =
      start_supervised!(
        {Engine,
         storage_id: "durable-repair-queue",
         namespace: "durable-repair-queue",
         data_root: root,
         stores: [
           [id: :primary, adapter: FileStore, role: :primary, opts: []],
           [id: :backup, adapter: FailingReplica, role: :replica, opts: []]
         ]}
      )

    assert {:ok, receipt} =
             Context.with([engine: engine], fn opts ->
               Manager.append(:knowledge, %{id: "repair-me", text: "durable repair"}, opts)
             end)

    assert receipt.repair_required?

    assert eventually(fn ->
             Enum.any?(RepairQueue.jobs(), &(&1.commit_id == receipt.commit_id))
           end)

    assert :ok = RepairQueue.reset()
    assert RepairQueue.jobs() == []

    {:ok, runtime} = Engine.resolve(engine)
    assert :ok = RepairQueue.restore(runtime.config)

    assert eventually(fn ->
             Enum.any?(RepairQueue.jobs(), fn job ->
               job.commit_id == receipt.commit_id and job.target_store == :backup
             end)
           end)
  end

  test "a StoreWriter crash before append cannot create a committed record" do
    test_pid = self()

    injector = fn
      :before_store_commit, context ->
        send(test_pid, {:store_crash_before_commit, self(), context.commit_id})
        exit(:store_crashed_before_commit)

      _point, _context ->
        :ok
    end

    {engine, root} = file_engine("store-crash-before", injector)
    on_exit(fn -> File.rm_rf(root) end)

    result =
      Context.with([engine: engine, operation_id: "store-crash-before-op"], fn opts ->
        Manager.append(:knowledge, %{id: "before", text: "must not commit"}, opts)
      end)

    assert {:error, _reason} = result
    assert_receive {:store_crash_before_commit, executor, commit_id}
    assert is_binary(commit_id)
    refute Process.alive?(executor)

    assert {:ok, []} =
             Context.with([engine: engine], fn opts -> Manager.replay(opts) end)
  end

  test "a StoreWriter crash after append is recovered as an unambiguous commit" do
    test_pid = self()
    gate = :atomics.new(1, signed: false)

    injector = fn
      :after_store_commit, context ->
        case :atomics.compare_exchange(gate, 1, 0, 1) do
          :ok ->
            send(test_pid, {:store_crash_after_commit, self(), context.commit_id})
            exit(:store_crashed_after_commit)

          _already_injected ->
            :ok
        end

      _point, _context ->
        :ok
    end

    {engine, root} = file_engine("store-crash-after", injector)
    on_exit(fn -> File.rm_rf(root) end)

    write = fn ->
      Context.with([engine: engine, operation_id: "store-crash-after-op"], fn opts ->
        Manager.append(:knowledge, %{id: "after", text: "committed once"}, opts)
      end)
    end

    assert {:ok, receipt} = write.()
    assert receipt.status == :committed
    assert_receive {:store_crash_after_commit, executor, commit_id}
    assert receipt.commit_id == commit_id
    refute Process.alive?(executor)

    assert {:ok, retried} = write.()
    assert retried.idempotent?
    assert retried.commit_id == receipt.commit_id

    assert {:ok, records} =
             Context.with([engine: engine], fn opts -> Manager.replay(opts) end)

    assert Enum.count(records, &(&1.commit_id == receipt.commit_id)) == 1
  end

  defp start_engine(storage_id, gate, ref, extra_opts \\ []) do
    stores = [
      [
        id: :blocking_primary,
        adapter: BlockingPrimary,
        role: :primary,
        opts: [gate: gate, ref: ref, test_pid: self()]
      ]
    ]

    start_supervised!(
      {Engine,
       [
         storage_id: storage_id,
         namespace: "primary-writer-test",
         stores: stores,
         limits: Keyword.take(extra_opts, [:max_store_queue])
       ]}
    )
  end

  defp append_async(engine, id) do
    Task.async(fn ->
      Context.with([engine: engine], fn opts ->
        Manager.append(:knowledge, %{id: id, text: "primary #{id}"}, opts)
      end)
    end)
  end

  defp file_engine(storage_id, injector) do
    root =
      Path.join(System.tmp_dir!(), "mnemonic-#{storage_id}-#{System.unique_integer([:positive])}")

    engine =
      start_supervised!(
        {Engine,
         storage_id: storage_id,
         namespace: storage_id,
         data_root: root,
         stores: [
           [
             id: :primary,
             adapter: FileStore,
             role: :primary,
             opts: [data_root: root, failure_injector: injector]
           ]
         ]}
      )

    {engine, root}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
