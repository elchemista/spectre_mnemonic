defmodule SpectreMnemonic.Integration.ProjectionLifecycleTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Active.Eviction
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Atlas
  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Episode
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Recall.Index, as: RecallIndex

  @namespace "spectre_mnemonic_test"

  test "overlapping durable rebuilds preserve the readable committed generation" do
    opts = [namespace: @namespace, scope: :overlapping_rebuild]
    assert {:ok, _} = SpectreMnemonic.signal("committed orchard", opts)
    pid = DurableIndex.server(@namespace)
    {:ok, ref, _runtime_opts} = GenServer.call(pid, :begin_rebuild)

    assert {:error, :rebuild_in_progress} = DurableIndex.rebuild(opts)
    assert {:ok, [_]} = DurableIndex.search("orchard", opts)

    assert {:error, :stale_rebuild} =
             GenServer.call(pid, {:finish_rebuild, make_ref(), {:error, :offline}})

    assert {:error, :offline} = GenServer.call(pid, {:finish_rebuild, ref, {:error, :offline}})
    assert :ok = DurableIndex.rebuild(opts)
    assert {:ok, [_]} = DurableIndex.search("orchard", opts)
  end

  defmodule OfflineAtlasStore do
    def capabilities(_opts), do: [:append, :replay]
    def replay(_opts), do: {:ok, []}
    def put(_record, _opts), do: {:error, :offline}
  end

  test "atlas restores claimed dirty work after a storage failure and can retry normally" do
    opts = [scope: :atlas_retry, persist?: false]
    {:ok, %{moment: first}} = SpectreMnemonic.signal("release owner", opts)
    {:ok, %{moment: second}} = SpectreMnemonic.signal("release date", opts)
    assert {:ok, _} = SpectreMnemonic.link(first.id, :supports, second.id, opts)
    dirty = Atlas.dirty_ids(opts)

    assert {:error, {:persistent_memory_failed, [_]}} =
             Atlas.materialize(
               opts ++
                 [
                   persistent_memory: [
                     stores: [
                       [id: :offline, role: :primary, adapter: OfflineAtlasStore, opts: []]
                     ]
                   ]
                 ]
             )

    assert Atlas.dirty_ids(opts) == dirty
    assert {:ok, [_]} = Atlas.materialize(scope: :atlas_retry)
    assert Atlas.dirty_ids(opts) == []

    for adapter <- [
          fn _input, _opts -> {:ok, "approved label"} end,
          fn _input -> throw(:offline) end,
          :invalid_adapter,
          42
        ] do
      assert {:ok, %{clusters: [episode]}} = Atlas.build(opts ++ [atlas_label_adapter: adapter])
      assert is_binary(episode.title)
      assert episode.title != ""
    end

    assert {:ok, []} = Atlas.materialize(scope: :empty, recluster: true)
  end

  test "rolling back a hot intake removes its graph and derived records only" do
    opts = [scope: :rollback, persist?: false]

    assert {:ok, %{moment: rejected}} =
             SpectreMnemonic.signal(
               "rejected intake",
               opts ++ [metadata: %{intake_run_id: "run"}]
             )

    assert {:ok, %{moment: retained}} = SpectreMnemonic.signal("independent memory", opts)

    episode = %Episode{
      id: "rollback-episode",
      namespace: @namespace,
      scope: :rollback,
      moment_ids: [rejected.id]
    }

    assert :ok = Focus.put_episode(episode)

    association = %Association{
      id: "rollback-association",
      namespace: @namespace,
      scope: :rollback,
      source_id: episode.id,
      target_id: rejected.id,
      relation: :contains
    }

    assert :ok = Focus.upsert_association(association)

    for {table, index} <- [
          {:mnemonic_observations, :mnemonic_observations_by_scope},
          {:mnemonic_mental_models, :mnemonic_mental_models_by_scope}
        ] do
      record = %{
        id: "derived",
        namespace: @namespace,
        scope: :rollback,
        source_ids: [rejected.id]
      }

      ETS.insert(table, {record.id, record})
      ETS.insert(index, {{@namespace, :rollback}, record.id})
    end

    assert {:ok, 1} = Focus.rollback_intake("run", opts)
    assert [%{id: retained_id}] = Focus.moments(opts)
    assert retained_id == retained.id
    assert Focus.episodes(opts) == []
    assert Focus.associations(opts) == []

    for table <- [:mnemonic_observations, :mnemonic_mental_models] do
      assert ETS.lookup(table, "derived") == []
    end

    assert {:ok, 0} = Focus.rollback_intake("run", opts)
    assert {:ok, 0} = Focus.rollback_intake(nil, opts)
  end

  test "pinning and dropping an episode leave accounting and unrelated memory intact" do
    opts = [namespace: @namespace, scope: :pinning, persist?: true]
    assert {:ok, %{moment: moment}} = SpectreMnemonic.signal("pinning lifecycle", opts)
    assert :ok = Governance.append_state(moment.id, :pinned, :manual, opts)
    assert :ok = Focus.validate_pinned_transition(moment.id, :pinned, opts)
    [{_, pinned_bytes}] = ETS.lookup(:mnemonic_hot_bytes, {:pinned, @namespace})
    assert pinned_bytes > 0, inspect(ETS.lookup(:mnemonic_moment_sizes, moment.id))

    episode = %Episode{
      id: "temporary-episode",
      namespace: @namespace,
      scope: :pinning,
      moment_ids: [moment.id]
    }

    assert :ok = Focus.put_episode(episode)
    assert :ok = Focus.drop_episode(episode, opts)
    assert Focus.episodes(opts) == []
    assert [%{id: memory_id}] = Focus.moments(opts)
    assert memory_id == moment.id
    assert {:ok, 1} = Focus.forget(moment.id, opts)
    assert [{_, 0}] = ETS.lookup(:mnemonic_hot_bytes, {:pinned, @namespace})
    assert {:ok, 0} = Focus.forget(moment.id, opts)
    assert [{_, 0}] = ETS.lookup(:mnemonic_hot_bytes, {:pinned, @namespace})
  end

  test "positive byte accounting enforces a cumulative pinned budget" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "cumulative-pinned-budget",
         namespace: "cumulative-pinned-budget",
         limits: [max_pinned_bytes: 128 * 1024 * 1024]}
      )

    assert {:ok, %{moment: first}} = SpectreMnemonic.signal("first pin", engine: engine)
    assert {:ok, %{moment: second}} = SpectreMnemonic.signal("second pin", engine: engine)
    {:ok, runtime} = Engine.resolve(engine)

    budget =
      ETS.with_engine(engine, fn ->
        [first_size] = ETS.lookup(:mnemonic_moment_sizes, first.id)
        [second_size] = ETS.lookup(:mnemonic_moment_sizes, second.id)
        elem(first_size, 1) + elem(second_size, 1) - 1
      end)

    opts = [
      namespace: runtime.config.internal_namespace,
      engine_ref: runtime.config.ref,
      max_pinned_bytes: budget
    ]

    assert :ok = Governance.append_state(first.id, :pinned, :manual, opts)

    assert {:error, {:mnemonic_limit_exceeded, :max_pinned_bytes}} =
             Governance.append_state(second.id, :pinned, :manual, opts)

    ETS.with_engine(engine, fn ->
      [{_, bytes}] = ETS.lookup(:mnemonic_hot_bytes, {:pinned, runtime.config.internal_namespace})
      assert bytes > 0
      assert bytes <= budget

      assert :ok =
               Eviction.adjust_bytes(
                 {:pinned, runtime.config.internal_namespace},
                 -10_000
               )

      assert [{_, 0}] =
               ETS.lookup(:mnemonic_hot_bytes, {:pinned, runtime.config.internal_namespace})
    end)
  end

  test "active vector index rebuild and partition purge preserve the other scope" do
    vector = Vector.normalize_to_f32_binary([1.0, 0.0])

    for scope <- [:first, :second] do
      assert {:ok, _} =
               SpectreMnemonic.signal("vector #{scope}",
                 scope: scope,
                 vector: vector,
                 persist?: false
               )
    end

    {:ok, runtime} = Engine.resolve(SpectreMnemonic.DefaultEngine)
    assert RecallIndex.server(runtime.config.ref) == RecallIndex.server(@namespace)
    assert :ok = RecallIndex.rebuild()
    assert {:ok, [_]} = RecallIndex.query(%{vector: vector}, scope: :first)
    assert :ok = RecallIndex.purge_partition(scope: :first)
    assert {:ok, []} = RecallIndex.query(%{vector: vector}, scope: :first)
    assert {:ok, [_]} = RecallIndex.query(%{vector: vector}, scope: :second)
    assert :ok = RecallIndex.rebuild()
    assert {:ok, [_]} = RecallIndex.query(%{vector: vector}, scope: :first)
  end

  test "large durable partitions use bounded posting candidates and report their sources" do
    scope = :postings
    now = DateTime.utc_now()

    for index <- 1..270 do
      record = %Record{
        id: "record-#{index}",
        namespace: @namespace,
        scope: scope,
        family: :moments,
        operation: :put,
        inserted_at: now,
        payload: %{id: "memory-#{index}", text: "orchard apple #{index}", entities: ["Alice"]}
      }

      assert :ok = DurableIndex.upsert(record)
    end

    assert {:ok, results} =
             DurableIndex.search("orchard Alice",
               scope: scope,
               max_candidates: 5,
               limit: 5,
               brute_force_threshold: 0
             )

    assert length(results) == 5
    assert Enum.all?(results, &(&1.scope == scope))
    assert %{running?: true, documents: count, generation: generations} = DurableIndex.status()
    assert count >= 270
    assert is_map(generations)
  end

  test "durable intake rollback removes attached recipes and is safe to repeat" do
    opts = [scope: :recipe_rollback, persist?: true]

    assert {:ok, %{moment: moment, action_recipe: recipe}} =
             SpectreMnemonic.signal(
               "temporary recipe",
               opts ++
                 [
                   metadata: %{intake_run_id: "recipe-run"},
                   action_recipe: [text: "send report"]
                 ]
             )

    assert [^recipe] = Focus.action_recipes([recipe.id], opts)
    assert {:ok, 1} = Focus.rollback_intake("recipe-run", opts)
    assert Focus.action_recipes([recipe.id], opts) == []
    assert Focus.moments(opts) == []
    assert {:ok, records} = Manager.replay(opts)
    refute Enum.any?(records, &(&1.family == :moments and &1.payload.id == moment.id))
    refute Enum.any?(records, &(&1.family == :action_recipes and &1.payload.id == recipe.id))
    assert {:ok, 0} = Focus.rollback_intake("recipe-run", opts)
  end

  test "attention decay protects pinned memories and respects the floor with map configuration" do
    opts = [scope: :attention_decay, persist?: false]

    assert {:ok, %{moment: ordinary}} =
             SpectreMnemonic.signal("decaying", opts ++ [attention: 2.0])

    assert {:ok, %{moment: pinned}} =
             SpectreMnemonic.signal("protected", opts ++ [attention: 2.0])

    yesterday = DateTime.add(DateTime.utc_now(), -172_800, :second)
    assert :ok = Focus.hydrate_moment(%{ordinary | inserted_at: yesterday}, opts)
    assert :ok = Focus.hydrate_moment(%{pinned | inserted_at: yesterday}, opts)
    assert :ok = Governance.append_state(pinned.id, :pinned, :manual, opts)

    Application.put_env(:spectre_mnemonic, :hot_memory, %{
      attention_decay_factor: 0.0,
      attention_floor: 0.5
    })

    assert {:ok, 1} = Focus.decay_attention_all(opts)
    by_id = Map.new(Focus.moments(opts), &{&1.id, &1.attention})
    assert by_id[ordinary.id] == 0.5
    assert by_id[pinned.id] == 2.0
    assert {:ok, 0} = Focus.decay_attention_all(opts)
    assert :ok = Focus.reinforce_attention([ordinary.id, ordinary.id], opts)
    assert {:ok, 0} = Focus.forget(fn _ -> throw(:invalid_selector) end, opts)
  end
end
