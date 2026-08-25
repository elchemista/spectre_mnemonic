defmodule SpectreMnemonic.MemoryReviewRegressionTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Atlas
  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Export
  alias SpectreMnemonic.Export.Reader
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Graph.Resolver
  alias SpectreMnemonic.Graph.Traversal
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Episode
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.File, as: FileStore
  alias SpectreMnemonic.Persistence.Store.Record

  @namespace "spectre_mnemonic_test"

  defmodule NonErasableStore do
    @moduledoc false
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl true
    def capabilities(_opts), do: [:append, :replay]

    @impl true
    def put(_record, _opts), do: {:ok, :stored}

    @impl true
    def replay(_opts), do: {:ok, []}
  end

  @tag timeout: 120_000
  test "erasure completes for the 1,101-record reproducer without a manager timeout" do
    scope = {:subject, "large-erasure"}
    opts = [namespace: @namespace, scope: scope]

    Enum.each(1..1_101, fn index ->
      assert {:ok, _result} =
               Manager.append(:moments, %{id: "large-#{index}", text: "record #{index}"}, opts)
    end)

    assert {:ok, report} = SpectreMnemonic.erase_partition(opts)
    assert report.families.moments == 1_101
    assert {:ok, [%Record{family: :erasure_markers}]} = Manager.replay(opts)
  end

  test "erasure evicts partition dedupe state and permits an identical clean re-append" do
    scope = {:subject, "dedupe-after-erasure"}
    opts = [namespace: @namespace, scope: scope]
    payload = %{id: "same-payload", text: "plaintext removed from manager cache"}

    assert {:ok, first_write} = Manager.append(:moments, payload, opts)
    refute Map.get(first_write, :idempotent?, false)
    assert {:ok, _report} = SpectreMnemonic.erase_partition(opts)
    refute inspect(:sys.get_state(Manager)) =~ payload.text

    assert {:ok, second_write} = Manager.append(:moments, payload, opts)
    refute Map.get(second_write, :idempotent?, false)
    assert second_write.stores != []
    assert {:ok, records} = Manager.replay(opts)
    assert Enum.any?(records, &(&1.family == :moments and &1.payload.id == payload.id))
  end

  test "erasure fails before mutation when any configured store cannot erase and verify" do
    scope = {:subject, "unsupported-erasure-store"}

    Application.put_env(:spectre_mnemonic, :persistent_memory,
      stores: [
        [
          id: :file,
          adapter: FileStore,
          role: :primary,
          duplicate: true,
          opts: [data_root: "mnemonic_data"]
        ],
        [
          id: :remote,
          adapter: NonErasableStore,
          duplicate: true,
          opts: []
        ]
      ]
    )

    Manager.reset_dedupe()
    assert {:ok, %{moment: moment}} = SpectreMnemonic.signal("must remain", scope: scope)

    assert {:error, {:erasure_unsupported_stores, failures}} =
             SpectreMnemonic.erase_partition(namespace: @namespace, scope: scope)

    assert Enum.any?(failures, &(&1.store == :remote))
    assert Enum.any?(Focus.moments(scope: scope), &(&1.id == moment.id))
    assert {:ok, records} = Manager.replay(scope: scope)
    assert Enum.any?(records, &(&1.family == :moments and &1.payload.id == moment.id))
  end

  test "an erasure generation rejects a stale future-dated record restored after erasure" do
    scope = {:subject, "future-stale-record"}
    opts = [namespace: @namespace, scope: scope]

    assert {:ok, _result} = Manager.append(:moments, %{id: "old", text: "old"}, opts)
    assert {:ok, _report} = SpectreMnemonic.erase_partition(opts)

    stale = %Record{
      id: "future-stale-envelope",
      namespace: @namespace,
      scope: scope,
      family: :moments,
      operation: :put,
      payload: %{id: "future-stale", namespace: @namespace, scope: scope, text: "stale"},
      dedupe_key: "future-stale",
      inserted_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
      source_event_id: "future-stale",
      metadata: %{namespace: @namespace, scope: scope}
    }

    assert {:ok, _sequence} = FileStore.put(stale, [])
    Manager.reset_dedupe()
    assert {:ok, records} = Manager.replay(opts)
    refute Enum.any?(records, &(&1.family == :moments and &1.payload.id == "future-stale"))
  end

  test "sealed partitions reject links as well as new moments" do
    scope = {:subject, "sealed-links"}
    {:ok, %{moment: left}} = SpectreMnemonic.signal("left", scope: scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("right", scope: scope)

    assert {:ok, _report} =
             SpectreMnemonic.erase_partition(
               namespace: @namespace,
               scope: scope,
               sealed: true
             )

    assert {:error, :partition_erased} =
             SpectreMnemonic.link(left.id, :supports, right.id, scope: scope, persist?: false)
  end

  test "cluster membership and identity aliases are non-traversable unless explicitly selected" do
    scope = {:subject, "non-traversable-hubs"}
    {:ok, %{moment: left}} = SpectreMnemonic.signal("left hub", scope: scope, persist?: false)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("right hub", scope: scope, persist?: false)
    now = DateTime.utc_now()

    episode = %Episode{
      id: "episode-hub",
      namespace: @namespace,
      scope: scope,
      title: "private cluster label",
      moment_ids: [left.id, right.id],
      inserted_at: now
    }

    Focus.put_episode(episode)

    for {id, source} <- [{"member-left", left.id}, {"member-right", right.id}] do
      Focus.upsert_association(%Association{
        id: id,
        namespace: @namespace,
        scope: scope,
        source_id: source,
        relation: :member_of,
        target_id: episode.id,
        weight: 1.0,
        metadata: %{durable?: false},
        inserted_at: now
      })
    end

    default =
      Traversal.expand([left],
        scope: scope,
        graph_depth: 2,
        activation_floor: 0.0
      )

    refute Map.has_key?(default.activations, episode.id)
    refute Map.has_key?(default.activations, right.id)

    explicit =
      Traversal.expand([left],
        scope: scope,
        relations: [:member_of],
        graph_depth: 2,
        activation_floor: 0.0
      )

    assert Map.has_key?(explicit.activations, episode.id)
    assert Map.has_key?(explicit.activations, right.id)
  end

  test "plasticity decays only stale edges and never persists a hot-only edge" do
    scope = {:subject, "plasticity-persistence"}
    {:ok, %{moment: left}} = SpectreMnemonic.signal("left", scope: scope, persist?: false)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("right", scope: scope, persist?: false)

    assert {:ok, edge} =
             SpectreMnemonic.link(left.id, :supports, right.id,
               scope: scope,
               weight: 0.4,
               persist?: false
             )

    path = %{right.id => %{hops: [%{association_id: edge.id}]}}
    assert {:ok, 1} = Plasticity.reinforce(path, scope: scope)
    reinforced = association(edge.id)
    assert reinforced.weight > edge.weight
    assert {:ok, 0} = Plasticity.decay(scope: scope)
    assert association(edge.id).weight == reinforced.weight

    stale = %{
      reinforced
      | metadata:
          Map.put(
            reinforced.metadata,
            :last_activated_at,
            DateTime.add(DateTime.utc_now(), -31, :day)
          )
    }

    Focus.upsert_association(stale)
    assert {:ok, 1} = Plasticity.decay(scope: scope, persist?: false)
    assert association(edge.id).weight < stale.weight

    assert {:ok, records} = Manager.replay(scope: scope)
    refute Enum.any?(records, &(&1.family == :associations and &1.payload.id == edge.id))
  end

  test "plasticity does not append at a bound and throttles repeated durable reweights" do
    scope = {:subject, "plasticity-log-bound"}
    {:ok, %{moment: left}} = SpectreMnemonic.signal("left", scope: scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("right", scope: scope)

    assert {:ok, edge} =
             SpectreMnemonic.link(left.id, :supports, right.id,
               scope: scope,
               weight: 1.0
             )

    path = %{right.id => %{hops: [%{association_id: edge.id}]}}
    before = raw_family_count(:associations)
    assert {:ok, 0} = Plasticity.reinforce(path, scope: scope)
    assert raw_family_count(:associations) == before

    bounded = %{association(edge.id) | weight: 0.4, metadata: %{durable?: true}}
    Focus.upsert_association(bounded)
    assert {:ok, 1} = Plasticity.reinforce(path, scope: scope)
    after_first = raw_family_count(:associations)
    assert {:ok, 1} = Plasticity.reinforce(path, scope: scope)
    assert raw_family_count(:associations) == after_first
  end

  test "durable entity aliases preserve canonical identity after hot eviction" do
    scope = {:subject, "durable-entity"}

    assert {:ok, packet} =
             SpectreMnemonic.remember("Alice owns the release", scope: scope, persist?: true)

    alice =
      Enum.find(packet.moments, &(&1.kind == :memory_entity and &1.metadata.canonical == "alice"))

    assert {:ok, learned} = Resolver.resolve("Alice", ["Ally"], scope: scope)
    assert learned.id == alice.id

    before_hot_only_alias = raw_family_count(:moments)

    clear_hot_graph()

    assert {:ok, hot_only_alias} =
             Resolver.resolve("Alice", ["Lissy"], scope: scope, persist?: false)

    assert "lissy" in hot_only_alias.metadata.aliases
    assert raw_family_count(:moments) == before_hot_only_alias

    clear_hot_graph()
    assert :miss = Resolver.resolve("Lissy", [], scope: scope, persist?: false)

    assert {:ok, restored} = Resolver.resolve("Ally", [], scope: scope)
    assert restored.id == alice.id
    assert "ally" in restored.metadata.aliases

    assert {:ok, records} = Manager.replay(scope: scope)

    assert Enum.any?(records, fn
             %Record{family: :moments, payload: %{id: id, metadata: metadata}} ->
               id == alice.id and "ally" in Map.get(metadata, :aliases, [])

             _record ->
               false
           end)
  end

  test "durable episodes survive hot eviction in default exports" do
    scope = {:subject, "durable-export-episodes"}
    path = Path.expand("mnemonic_data/durable-episodes.mnemonic")
    {:ok, %{moment: left}} = SpectreMnemonic.signal("episode left", scope: scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("episode right", scope: scope)
    {:ok, _edge} = SpectreMnemonic.link(left.id, :supports, right.id, scope: scope)
    assert {:ok, [episode]} = Atlas.materialize(scope: scope)

    clear_hot_graph()

    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope)
    assert {:ok, export} = Export.read(path)
    assert Enum.any?(export.clusters, &(&1["id"] == episode.id))
  end

  test "atlas includes evicted durable nodes, keeps the newest window, and reports truncation" do
    scope = {:subject, "durable-atlas-window"}

    Application.put_env(:spectre_mnemonic, :hot_memory,
      max_moments_per_scope: 1,
      max_moments_per_namespace: 10
    )

    {:ok, %{moment: oldest}} = SpectreMnemonic.signal("oldest atlas node", scope: scope)
    {:ok, %{moment: middle}} = SpectreMnemonic.signal("middle atlas node", scope: scope)
    {:ok, %{moment: newest}} = SpectreMnemonic.signal("newest atlas node", scope: scope)
    assert Enum.map(Focus.moments(scope: scope), & &1.id) == [newest.id]

    assert {:ok, atlas} = Atlas.build(scope: scope, max_nodes: 2)
    ids = Enum.map(atlas.nodes, & &1.id)
    assert atlas.truncated.nodes
    refute oldest.id in ids
    assert middle.id in ids
    assert newest.id in ids
  end

  test "forget cascades through episodes and durable memberships" do
    scope = {:subject, "forget-episode"}
    {:ok, %{moment: left}} = SpectreMnemonic.signal("forget episode left", scope: scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("forget episode right", scope: scope)
    {:ok, _edge} = SpectreMnemonic.link(left.id, :supports, right.id, scope: scope)
    assert {:ok, [episode]} = Atlas.materialize(scope: scope)

    assert {:ok, 1} = SpectreMnemonic.forget(left.id, scope: scope)
    refute Enum.any?(Focus.episodes(scope: scope), &(&1.id == episode.id))
    assert {:ok, records} = Manager.replay(scope: scope)
    refute Enum.any?(records, &(&1.family == :episodes and &1.payload.id == episode.id))

    refute Enum.any?(records, fn
             %Record{family: :associations, payload: association} ->
               association.relation == :member_of and association.target_id == episode.id

             _record ->
               false
           end)
  end

  test "reclustering supersedes durable episodes and their membership edges" do
    scope = {:subject, "episode-supersession"}
    {:ok, %{moment: first}} = SpectreMnemonic.signal("first cluster", scope: scope)
    {:ok, %{moment: second}} = SpectreMnemonic.signal("second cluster", scope: scope)
    {:ok, _edge} = SpectreMnemonic.link(first.id, :supports, second.id, scope: scope)
    assert {:ok, [old_episode]} = Atlas.materialize(scope: scope)

    {:ok, %{moment: third}} = SpectreMnemonic.signal("third cluster", scope: scope)
    {:ok, _edge} = SpectreMnemonic.link(first.id, :supports, third.id, scope: scope)
    assert {:ok, [new_episode]} = Atlas.materialize(scope: scope)
    assert new_episode.id != old_episode.id

    assert {:ok, records} = Manager.replay(scope: scope)
    refute Enum.any?(records, &(&1.family == :episodes and &1.payload.id == old_episode.id))
    assert Enum.any?(records, &(&1.family == :episodes and &1.payload.id == new_episode.id))

    refute Enum.any?(records, fn
             %Record{family: :associations, payload: association} ->
               association.relation == :member_of and association.target_id == old_episode.id

             _record ->
               false
           end)
  end

  test "export reports active atlas truncation and structure mode removes private labels recursively" do
    scope = {:subject, "export-privacy-and-truncation"}
    path = Path.expand("mnemonic_data/private-structure.mnemonic")
    {:ok, _packet} = SpectreMnemonic.remember("Alice coordinates Project Zephyr", scope: scope)
    {:ok, _result} = SpectreMnemonic.signal("another node", scope: scope)

    assert {:error, {:mnemonic_export_truncated, %{nodes: true}}} =
             SpectreMnemonic.export(path, scope: scope, max_nodes: 1)

    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope)
    assert {:ok, export} = Export.read(path)
    keys = recursive_keys(export)
    refute "canonical" in keys
    refute "aliases" in keys
    refute "title" in keys
    refute "label" in keys
    refute inspect(export) =~ "Project Zephyr"
  end

  test "unsupported metadata values fail export with a typed deterministic error" do
    scope = {:subject, "invalid-json-shape"}
    path = Path.expand("mnemonic_data/invalid-json-shape.mnemonic")

    assert {:ok, _result} =
             SpectreMnemonic.signal("pid metadata",
               scope: scope,
               metadata: %{owner: self()},
               persist?: false
             )

    assert {:error, {:mnemonic_export_failed, ArgumentError, message}} =
             SpectreMnemonic.export(path, scope: scope, mode: :full)

    assert message =~ "unsupported JSON value: :pid"
  end

  test "full export handles deterministic scalar, Date, and Time payload shapes" do
    scope = {:subject, "deterministic-json-shapes"}
    path = Path.expand("mnemonic_data/deterministic-json-shapes.mnemonic")
    opts = [namespace: @namespace, scope: scope]

    assert {:ok, _result} = Manager.append(:moments, "scalar durable payload", opts)

    assert {:ok, _result} =
             SpectreMnemonic.signal("dated metadata",
               scope: scope,
               metadata: %{date: ~D[2026-08-24], time: ~T[12:34:56]},
               persist?: false
             )

    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope, mode: :full)
    assert {:ok, export} = Export.read(path)
    assert inspect(export) =~ "scalar durable payload"
    assert inspect(export) =~ "2026-08-24"
    assert inspect(export) =~ "12:34:56"
  end

  test "reference and function metadata report their exact unsupported JSON shapes" do
    for {label, value, shape} <- [
          {"reference", make_ref(), ":reference"},
          {"function", fn -> :ok end, ":function"}
        ] do
      scope = {:subject, "invalid-#{label}"}
      path = Path.expand("mnemonic_data/invalid-#{label}.mnemonic")

      assert {:ok, _result} =
               SpectreMnemonic.signal(label,
                 scope: scope,
                 metadata: %{invalid: value},
                 persist?: false
               )

      assert {:error, {:mnemonic_export_failed, ArgumentError, message}} =
               SpectreMnemonic.export(path, scope: scope, mode: :full)

      assert message =~ shape
    end
  end

  test "sweep count includes expired hot-only memories" do
    scope = {:subject, "hot-only-retention"}
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    assert {:ok, _result} =
             SpectreMnemonic.signal("hot expired",
               scope: scope,
               valid_until: past,
               persist?: false
             )

    assert {:ok, 1} = SpectreMnemonic.sweep_expired(scope: scope)
    assert Focus.moments(scope: scope) == []

    assert {:error, {:invalid_sweep_option, :now, :tomorrow}} =
             SpectreMnemonic.sweep_expired(scope: scope, now: :tomorrow)
  end

  test "durable index tombstones remove lifecycle state projections too" do
    scope = {:subject, "index-state-tombstone"}
    memory_id = "indexed-memory"

    state_record = %Record{
      id: "state-record",
      namespace: @namespace,
      scope: scope,
      family: :memory_states,
      operation: :put,
      payload: %{id: "state-event", memory_id: memory_id, state: :promoted},
      dedupe_key: "state-record",
      inserted_at: DateTime.utc_now(),
      source_event_id: "state-event",
      metadata: %{}
    }

    tombstone = %{
      state_record
      | id: "state-tombstone",
        family: :tombstones,
        payload: %{family: :moments, id: memory_id},
        dedupe_key: "state-tombstone"
    }

    assert :ok = DurableIndex.upsert(state_record)
    assert Map.has_key?(:sys.get_state(DurableIndex).states, {@namespace, scope, memory_id})
    assert :ok = DurableIndex.upsert(tombstone)
    refute Map.has_key?(:sys.get_state(DurableIndex).states, {@namespace, scope, memory_id})
  end

  test "write guards fail closed when durable marker verification is unavailable" do
    manager = Process.whereis(Manager)
    assert Process.unregister(Manager)

    try do
      assert {:error,
              {:erasure_guard_unavailable,
               {:marker_replay_failed, {:persistent_memory_manager_unavailable, _reason}}}} =
               SpectreMnemonic.Erasure.ensure_writable(
                 namespace: @namespace,
                 scope: {:subject, "guard-unavailable"}
               )
    after
      Process.register(manager, Manager)
    end
  end

  test "verified streams emit typed errors instead of raising if the file changes" do
    scope = {:subject, "stream-mutation"}
    path = Path.expand("mnemonic_data/stream-mutation.mnemonic")
    assert {:ok, _result} = SpectreMnemonic.signal("stream value", scope: scope)
    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope)
    assert {:ok, stream} = Reader.stream(path)

    File.write!(path, <<"broken">>)

    assert [{:error, {:truncated_mnemonic_header, 1}}] = Enum.to_list(stream)
  end

  defp association(id) do
    [{^id, association}] = :ets.lookup(:mnemonic_associations, id)
    association
  end

  defp raw_family_count(family) do
    {:ok, frames} = FileStore.replay([])

    Enum.count(frames, fn
      {_sequence, _timestamp, %Record{family: ^family}} -> true
      _frame -> false
    end)
  end

  defp clear_hot_graph do
    Enum.each(
      [
        :mnemonic_moments,
        :mnemonic_moments_by_stream,
        :mnemonic_moments_by_task,
        :mnemonic_moments_by_scope,
        :mnemonic_moments_by_signal,
        :mnemonic_moment_counts,
        :mnemonic_associations,
        :mnemonic_associations_by_scope,
        :mnemonic_associations_by_memory,
        :mnemonic_entity_registry,
        :mnemonic_episodes,
        :mnemonic_episodes_by_scope,
        :mnemonic_atlas_dirty
      ],
      &:ets.delete_all_objects/1
    )
  end

  defp recursive_keys(value) when is_struct(value),
    do: value |> Map.from_struct() |> recursive_keys()

  defp recursive_keys(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} -> [to_string(key) | recursive_keys(nested)] end)
  end

  defp recursive_keys(value) when is_list(value), do: Enum.flat_map(value, &recursive_keys/1)
  defp recursive_keys(_value), do: []
end
