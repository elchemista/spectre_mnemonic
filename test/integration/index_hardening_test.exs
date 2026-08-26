defmodule SpectreMnemonic.Integration.IndexHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Durable.Documents
  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Recall.Index, as: RecallIndex

  @namespace "spectre_mnemonic_test"

  test "active index public fallbacks replace labels, delete safely, and survive a stopped child" do
    Application.put_env(:spectre_mnemonic, :embedding, index: [enabled: false])
    vector = Vector.normalize_to_f32_binary([1.0, 0.0])
    signature = <<0b1000_0000>>

    pid = RecallIndex.server(@namespace)
    assert is_pid(pid)
    refute Process.whereis(RecallIndex)
    assert :ok = RecallIndex.upsert(%{not: :indexable})
    assert {:ok, []} = RecallIndex.query(%{vector: nil})

    assert {:ok, []} =
             RecallIndex.query(%{vector: vector, binary_signature: signature}, overfetch: 0)

    moment = %Moment{
      id: "replaceable-vector",
      namespace: @namespace,
      scope: nil,
      vector: vector,
      binary_signature: signature,
      embedding: nil,
      inserted_at: DateTime.utc_now()
    }

    assert :ok = RecallIndex.upsert(moment)
    assert :ok = RecallIndex.upsert(moment)

    assert {:ok, [%{id: "replaceable-vector"}]} =
             RecallIndex.query(%{vector: vector, binary_signature: signature}, overfetch: 1)

    assert :ok = RecallIndex.delete(moment.id)
    assert :ok = RecallIndex.delete("already-missing")
    assert {:ok, []} = RecallIndex.query(%{vector: vector, binary_signature: signature})

    {:ok, runtime} = SpectreMnemonic.Engine.resolve(SpectreMnemonic.DefaultEngine)
    child_id = {RecallIndex, runtime.config.ref}
    :ok = Supervisor.terminate_child(runtime.engine_pid, child_id)

    on_exit(fn ->
      if RecallIndex.server(@namespace) == nil do
        {:ok, _pid} = Supervisor.restart_child(runtime.engine_pid, child_id)
      end
    end)

    assert :ok = RecallIndex.upsert(moment)
    assert :ok = RecallIndex.delete(moment.id)
    assert :ok = RecallIndex.reset()
    assert {:ok, []} = RecallIndex.query(%{vector: vector})
    {:ok, _pid} = Supervisor.restart_child(runtime.engine_pid, child_id)
  end

  test "active vector fallback ranks only the requested partition with bounded overfetch" do
    Application.put_env(:spectre_mnemonic, :embedding, index: [enabled: false])
    alpha = {:tenant, "vector-alpha"}
    beta = {:tenant, "vector-beta"}
    vector = Vector.normalize_to_f32_binary([1.0, 0.0])
    signature = <<0b1000_0000>>

    for index <- 1..2_000 do
      insert_vector_entry("beta-#{index}", index, @namespace, beta, vector, signature)
    end

    for index <- 1..8 do
      insert_vector_entry("alpha-#{index}", 2_000 + index, @namespace, alpha, vector, signature)
    end

    cue = %{vector: vector, binary_signature: signature}

    assert {:ok, results} = RecallIndex.query(cue, scope: alpha, overfetch: 3)
    assert length(results) == 3
    assert Enum.all?(results, &(&1.scope == alpha))

    assert {:ok, fallback_limit_results} =
             RecallIndex.query(cue, scope: alpha, overfetch: :invalid)

    assert length(fallback_limit_results) == 8
    assert Enum.all?(fallback_limit_results, &(&1.scope == alpha))
  end

  test "durable index rebuild cannot deadlock manager search and preserves concurrent upserts" do
    scope = {:tenant, "rebuild-race"}
    ref = make_ref()

    configure_blocking_store(ref)

    search_task = Task.async(fn -> Manager.search("deadlock sentinel", scope: scope) end)
    assert_receive {:blocking_search_entered, ^ref}

    rebuild_task = Task.async(fn -> DurableIndex.rebuild() end)
    assert_receive {:blocking_replay_entered, ^ref, replay_pid}

    concurrent = durable_record("concurrent-upsert", "concurrent rebuild sentinel", scope)
    assert :ok = DurableIndex.upsert(concurrent)

    send(replay_pid, {:release_replay, ref})
    assert :ok = Task.await(rebuild_task, 1_000)

    send(search_task.pid, {:release_search, ref})
    assert {:ok, _results} = Task.await(search_task, 1_000)

    assert {:ok, results} = DurableIndex.search("concurrent rebuild sentinel", scope: scope)
    assert Enum.any?(results, &(&1.id == "concurrent-upsert"))
  end

  test "durable scoring runs in the caller while the index accepts writes" do
    scope = {:tenant, "caller-scoring"}
    ref = make_ref()

    assert :ok =
             DurableIndex.upsert(
               durable_record("first-caller-doc", "caller scoring sentinel", scope)
             )

    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.BlockingEmbedding)
    test_pid = self()

    search_task =
      Task.async(fn ->
        DurableIndex.search("caller scoring sentinel",
          scope: scope,
          test_pid: test_pid,
          ref: ref
        )
      end)

    assert_receive {:blocking_embedding_entered, ^ref, search_pid}

    assert :ok =
             DurableIndex.upsert(
               durable_record("second-caller-doc", "write while scoring", scope)
             )

    send(search_pid, {:release_embedding, ref})
    assert {:ok, [_result | _rest]} = Task.await(search_task, 1_000)
  end

  test "durable index keeps serving its last valid state when replay fails" do
    scope = {:tenant, "rebuild-failure"}
    record = durable_record("stable-record", "stable replay fallback", scope)
    assert :ok = DurableIndex.upsert(record)

    assert {:ok, before_failure} = DurableIndex.search("stable replay fallback", scope: scope)
    assert Enum.any?(before_failure, &(&1.id == "stable-record"))

    Application.put_env(:spectre_mnemonic, :persistent_memory,
      stores: [
        [
          id: :failing_replay,
          adapter: __MODULE__.FailingReplayAdapter,
          role: :primary,
          duplicate: true,
          opts: []
        ]
      ]
    )

    assert {:error, {:persistent_memory_replay_failed, _failures}} = DurableIndex.rebuild()
    assert Process.alive?(DurableIndex.server(@namespace))

    assert {:ok, after_failure} = DurableIndex.search("stable replay fallback", scope: scope)
    assert Enum.any?(after_failure, &(&1.id == "stable-record"))
  end

  test "durable search caches corpus statistics until the next write" do
    scope = {:tenant, "stats-cache"}
    record = durable_record("stats-record", "cached corpus statistics", scope)

    assert :ok = DurableIndex.upsert(record)
    durable_index = DurableIndex.server(@namespace)
    assert :sys.get_state(durable_index).dirty?

    assert {:ok, [_result]} = DurableIndex.search("cached corpus statistics", scope: scope)
    refute :sys.get_state(durable_index).dirty?

    assert {:ok, [_result]} = DurableIndex.search("cached corpus statistics", scope: scope)
    refute :sys.get_state(durable_index).dirty?
  end

  test "durable corpus and postings live in unnamed protected ETS tables" do
    scope = {:tenant, "durable-ets-ownership"}

    assert :ok =
             DurableIndex.upsert(
               durable_record("ets-owned", "protected durable ETS sentinel", scope)
             )

    durable_index = DurableIndex.server(@namespace)
    state = :sys.get_state(durable_index)

    refute Map.has_key?(state, :docs)
    refute Map.has_key?(state, :postings)

    Enum.each(state.tables, fn {_name, table} ->
      assert :ets.info(table, :owner) == durable_index
      assert :ets.info(table, :protection) == :protected
      refute :ets.info(table, :named_table)
    end)

    assert_raise ArgumentError, fn ->
      :ets.insert(state.tables.documents, {:unauthorized, %{}})
    end

    assert {:ok, results} =
             DurableIndex.search("protected durable ETS sentinel", scope: scope)

    assert Enum.any?(results, &(&1.id == "ets-owned"))
  end

  test "durable rebuild releases transferred ETS tables when its caller dies" do
    durable_index = DurableIndex.server(@namespace)
    parent = self()

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        {:ok, ref, _runtime_opts} = GenServer.call(durable_index, :begin_rebuild)
        rebuilt = Documents.empty_state()

        Enum.each(rebuilt.tables, fn {name, table} ->
          true = :ets.give_away(table, durable_index, {:durable_rebuild, ref, name})
        end)

        send(parent, {:durable_tables_transferred, self(), Map.values(rebuilt.tables)})
        Process.sleep(:infinity)
      end)

    assert_receive {:durable_tables_transferred, ^worker, transferred}, 1_000

    assert eventually(fn ->
             state = :sys.get_state(durable_index)
             map_size(state.rebuild.transferred) == map_size(state.tables)
           end)

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

    assert eventually(fn -> is_nil(:sys.get_state(durable_index).rebuild) end)
    assert Enum.all?(transferred, &(:ets.info(&1) == :undefined))
  end

  test "a family tombstone does not hide another family with the same caller id" do
    scope = {:tenant, "family-tombstone"}
    moment = durable_record("shared-id", "shared family tombstone moment", scope)

    knowledge = %{
      durable_record("shared-id", "shared family tombstone knowledge", scope)
      | family: :knowledge
    }

    tombstone = %Record{
      id: "pmem-tombstone",
      namespace: @namespace,
      scope: scope,
      family: :tombstones,
      operation: :put,
      payload: %{family: :knowledge, id: "shared-id"},
      dedupe_key: "tombstone:knowledge:shared-id",
      inserted_at: DateTime.utc_now(),
      source_event_id: "shared-id",
      metadata: %{namespace: @namespace, scope: scope}
    }

    assert :ok = DurableIndex.upsert(moment)
    assert :ok = DurableIndex.upsert(knowledge)
    assert :ok = DurableIndex.upsert(tombstone)

    assert {:ok, results} = DurableIndex.search("shared family tombstone", scope: scope)
    assert Enum.any?(results, &(&1.family == :moments and &1.id == "shared-id"))
    refute Enum.any?(results, &(&1.family == :knowledge and &1.id == "shared-id"))
  end

  defp insert_vector_entry(id, label, namespace, scope, vector, signature) do
    RecallIndex.upsert(%Moment{
      id: id,
      namespace: namespace,
      scope: scope,
      vector: vector,
      binary_signature: signature,
      embedding: %{metadata: %{label: label, dimensions: 2, signature_bits: 8}},
      inserted_at: DateTime.utc_now()
    })
  end

  defp durable_record(id, text, scope) do
    %Record{
      id: "pmem-#{id}",
      namespace: @namespace,
      scope: scope,
      family: :moments,
      operation: :put,
      payload: %{id: id, namespace: @namespace, scope: scope, text: text},
      dedupe_key: "#{@namespace}:#{inspect(scope)}:moments:#{id}",
      inserted_at: DateTime.utc_now(),
      source_event_id: id,
      metadata: %{namespace: @namespace, scope: scope}
    }
  end

  defp configure_blocking_store(ref) do
    Application.put_env(:spectre_mnemonic, :persistent_memory,
      stores: [
        [
          id: :blocking,
          adapter: __MODULE__.BlockingAdapter,
          role: :primary,
          duplicate: true,
          opts: [test_pid: self(), ref: ref]
        ]
      ]
    )
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

  defmodule BlockingAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:append, :replay, :search]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def search(_cue, opts) do
      ref = Keyword.fetch!(opts, :ref)
      send(Keyword.fetch!(opts, :test_pid), {:blocking_search_entered, ref})

      receive do
        {:release_search, ^ref} -> {:ok, []}
      after
        2_000 -> {:error, :search_release_timeout}
      end
    end

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def replay(opts) do
      ref = Keyword.fetch!(opts, :ref)
      send(Keyword.fetch!(opts, :test_pid), {:blocking_replay_entered, ref, self()})

      receive do
        {:release_replay, ^ref} -> {:ok, []}
      after
        2_000 -> {:error, :replay_release_timeout}
      end
    end
  end

  defmodule FailingReplayAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:append, :replay]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def replay(_opts), do: {:error, :unavailable}
  end

  defmodule BlockingEmbedding do
    @behaviour SpectreMnemonic.Embedding.Adapter

    @impl SpectreMnemonic.Embedding.Adapter
    def embed(_input, opts) do
      ref = Keyword.fetch!(opts, :ref)
      send(Keyword.fetch!(opts, :test_pid), {:blocking_embedding_entered, ref, self()})

      receive do
        {:release_embedding, ^ref} -> {:ok, [1.0, 0.0]}
      after
        2_000 -> {:error, :embedding_release_timeout}
      end
    end
  end
end
