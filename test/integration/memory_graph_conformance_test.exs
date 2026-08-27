defmodule SpectreMnemonic.MemoryGraphConformanceTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.ETS, as: ActiveETS
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Atlas
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Graph.Resolver
  alias SpectreMnemonic.Graph.Traversal
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Recall.Index, as: RecallIndex
  alias SpectreMnemonic.Recall.Lexical

  test "lexical normalization removes English and Italian stopwords from ranking signals" do
    assert Lexical.keywords("The garden is in the city and the flowers are red") ==
             ~w(garden city flowers red)

    assert Lexical.keywords("Il rilascio è bloccato dalla chiave e dalla rete") ==
             ~w(rilascio bloccato chiave rete)

    refute "The" in Lexical.entities("The garden belongs to Alice")
    assert "Alice" in Lexical.entities("The garden belongs to Alice")

    assert {:ok, context} = QueryContext.new("The release belongs to Alice")
    refute "the" in context.keywords
    refute "The" in context.entities
  end

  test "minimum vector similarity removes weak candidates in the index and public recall" do
    scope = {:subject, "similarity-floor"}

    {:ok, %{moment: target}} =
      SpectreMnemonic.signal("opaque target alpha", scope: scope, embedding: [1.0, 0.0])

    {:ok, %{moment: weak}} =
      SpectreMnemonic.signal("opaque weak beta", scope: scope, embedding: [0.5, 0.866_025])

    cue = Service.embed("unshared query words", embedding: [1.0, 0.0])

    assert {:ok, [%{id: target_id}]} =
             RecallIndex.query(cue,
               scope: scope,
               overfetch: 10,
               min_vector_similarity: 0.8
             )

    assert target_id == target.id

    assert {:ok, packet} =
             SpectreMnemonic.recall("unshared query words",
               scope: scope,
               embedding: [1.0, 0.0],
               min_vector_similarity: 0.8,
               plasticity?: false,
               limit: 10
             )

    assert target.id in Enum.map(packet.moments, & &1.id)
    refute weak.id in Enum.map(packet.moments, & &1.id)

    for invalid <- [-0.01, 1.01, "high", nil] do
      assert {:error, {:invalid_recall_option, :min_vector_similarity, ^invalid}} =
               SpectreMnemonic.recall("cue", min_vector_similarity: invalid)
    end
  end

  test "embedding index accepts map configuration and contains malformed configuration" do
    scope = {:subject, "index-config-shapes"}

    Application.put_env(:spectre_mnemonic, :embedding, %{
      index: %{backend: :vettore, vettore_index: :flat, strategy: :exact}
    })

    {:ok, %{moment: target}} =
      SpectreMnemonic.signal("map configured index", scope: scope, embedding: [1.0, 0.0])

    cue = Service.embed("cue", vector: [1.0, 0.0])
    assert {:ok, [%{id: id}]} = RecallIndex.query(cue, scope: scope, overfetch: 1)
    assert id == target.id

    Application.put_env(:spectre_mnemonic, :embedding, %{index: :invalid})
    assert {:ok, [%{id: id}]} = RecallIndex.query(cue, scope: scope, overfetch: 1)
    assert id == target.id

    Application.put_env(:spectre_mnemonic, :embedding, :invalid)
    assert {:ok, [%{id: id}]} = RecallIndex.query(cue, scope: scope, overfetch: 1)
    assert id == target.id
  end

  test "remember rejects malformed graph and aggregation parameters before writing memory" do
    invalid = [
      {:chunk_words, 0},
      {:chunk_words, 1.5},
      {:overlap_words, -1},
      {:summary_words, 0},
      {:max_related_edges, -1},
      {:max_related_edges, 2.5},
      {:max_cross_memory_edges, -1},
      {:similarity_threshold, -0.01},
      {:similarity_threshold, 1.01},
      {:cross_memory_similarity_threshold, :high},
      {:extract_entities?, :yes},
      {:cross_memory?, 1},
      {:persist?, nil},
      {:metadata, :invalid},
      {:root_attention, "high"},
      {:chunk_attention, nil},
      {:summary_attention, :invalid},
      {:category_attention, []},
      {:extraction_attention, %{}}
    ]

    Enum.each(invalid, fn {key, value} ->
      assert {:error, {:invalid_remember_option, ^key, ^value}} =
               SpectreMnemonic.remember("must not be stored", [{key, value}])
    end)

    assert {:error, {:invalid_remember_options, %{chunk_words: 10}}} =
             SpectreMnemonic.remember("must not be stored", %{chunk_words: 10})

    assert Focus.moments() == []
  end

  test "link validates endpoints relation weight and metadata without partial writes" do
    scope = {:subject, "link-validation"}
    {:ok, %{moment: left}} = SpectreMnemonic.signal("left", scope: scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("right", scope: scope)

    assert {:error, {:invalid_link_endpoint, :source_id, ""}} =
             SpectreMnemonic.link("", :supports, right.id, scope: scope)

    assert {:error, {:invalid_link_endpoint, :target_id, nil}} =
             SpectreMnemonic.link(left.id, :supports, nil, scope: scope)

    assert {:error, {:invalid_link_relation, "supports"}} =
             SpectreMnemonic.link(left.id, "supports", right.id, scope: scope)

    assert {:error, {:invalid_link_relation, false}} =
             SpectreMnemonic.link(left.id, false, right.id, scope: scope)

    for weight <- [-0.01, 1.01, "heavy"] do
      assert {:error, {:invalid_link_weight, ^weight}} =
               SpectreMnemonic.link(left.id, :supports, right.id,
                 scope: scope,
                 weight: weight
               )
    end

    assert {:error, {:invalid_focus_option, :metadata, :invalid}} =
             SpectreMnemonic.link(left.id, :supports, right.id,
               scope: scope,
               metadata: :invalid
             )

    assert Focus.associations(scope: scope) == []
  end

  test "recall validates every graph-bound parameter" do
    invalid = [
      {:overfetch, -1},
      {:graph_depth, -1},
      {:max_graph_nodes, -1},
      {:hop_decay, -0.1},
      {:activation_floor, 1.1},
      {:prune_threshold, :low},
      {:relations, [:supports, "invalid"]},
      {:relation_types, :supports},
      {:exclude_relations, :contradicts}
    ]

    Enum.each(invalid, fn {key, value} ->
      assert {:error, {:invalid_recall_option, ^key, ^value}} =
               SpectreMnemonic.recall("cue", [{key, value}])
    end)
  end

  test "traversal honors included excluded and pruned relation types" do
    scope = {:subject, "typed-traversal"}
    seed = signal!("seed", scope)
    supported = signal!("supported", scope)
    contradicted = signal!("contradicted", scope)
    weak = signal!("weak", scope)

    {:ok, _edge} =
      SpectreMnemonic.link(seed.id, :supports, supported.id, scope: scope, weight: 0.9)

    {:ok, _edge} =
      SpectreMnemonic.link(seed.id, :contradicts, contradicted.id, scope: scope, weight: 0.9)

    {:ok, _edge} = SpectreMnemonic.link(seed.id, :supports, weak.id, scope: scope, weight: 0.01)

    result =
      Traversal.expand([seed],
        scope: scope,
        graph_depth: 1,
        hop_decay: 1.0,
        activation_floor: 0.0,
        prune_threshold: 0.03,
        relations: [:supports]
      )

    assert supported.id in Map.keys(result.activations)
    refute contradicted.id in Map.keys(result.activations)
    refute weak.id in Map.keys(result.activations)

    excluded =
      Traversal.expand([seed],
        scope: scope,
        graph_depth: 1,
        activation_floor: 0.0,
        exclude_relations: [:supports]
      )

    assert contradicted.id in Map.keys(excluded.activations)
    refute supported.id in Map.keys(excluded.activations)
  end

  test "traversal enforces a hard node cap including seed memories" do
    scope = {:subject, "node-cap"}
    seeds = Enum.map(1..4, &signal!("seed #{&1}", scope))

    assert %{moments: [], activations: %{}, paths: %{}} =
             Traversal.expand(seeds, scope: scope, max_graph_nodes: 0)

    result = Traversal.expand(seeds, scope: scope, max_graph_nodes: 2, graph_depth: 0)
    assert map_size(result.activations) == 2
    assert length(result.moments) == 2
  end

  test "hub damping reduces propagation from high-degree nodes" do
    scope = {:subject, "hub-damping"}
    hub = signal!("hub", scope)
    leaves = Enum.map(1..4, &signal!("hub leaf #{&1}", scope))
    pair_source = signal!("pair source", scope)
    pair_target = signal!("pair target", scope)

    Enum.each(leaves, fn leaf ->
      assert {:ok, _edge} = SpectreMnemonic.link(hub.id, :supports, leaf.id, scope: scope)
    end)

    assert {:ok, _edge} =
             SpectreMnemonic.link(pair_source.id, :supports, pair_target.id, scope: scope)

    opts = [scope: scope, graph_depth: 1, hop_decay: 1.0, activation_floor: 0.0]
    from_hub = Traversal.expand([hub], opts)
    from_pair = Traversal.expand([pair_source], opts)

    assert from_hub.activations[hd(leaves).id] < from_pair.activations[pair_target.id]
  end

  test "multi-hop traversal records a stable explanatory path" do
    scope = {:subject, "multi-hop-path"}
    first = signal!("first", scope)
    second = signal!("second", scope)
    third = signal!("third", scope)
    {:ok, first_edge} = SpectreMnemonic.link(first.id, :supports, second.id, scope: scope)
    {:ok, second_edge} = SpectreMnemonic.link(second.id, :causes, third.id, scope: scope)

    result =
      Traversal.expand([first],
        scope: scope,
        graph_depth: 2,
        hop_decay: 1.0,
        activation_floor: 0.0
      )

    assert %{seed_id: seed_id, hops: [first_hop, second_hop]} = result.paths[third.id]
    assert seed_id == first.id
    assert first_hop.association_id == first_edge.id
    assert second_hop.association_id == second_edge.id
    assert second_hop.activation < first_hop.activation
  end

  test "atlas bounds nodes and edges and keeps deterministic layout coordinates" do
    scope = {:subject, "bounded-atlas"}
    nodes = Enum.map(1..5, &signal!("atlas node #{&1}", scope))

    nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [left, right] ->
      assert {:ok, _edge} = SpectreMnemonic.link(left.id, :supports, right.id, scope: scope)
    end)

    assert {:ok, first} = SpectreMnemonic.atlas(scope: scope, max_nodes: 3, max_edges: 1)
    assert {:ok, second} = SpectreMnemonic.atlas(scope: scope, max_nodes: 3, max_edges: 1)

    assert first.nodes == second.nodes
    assert first.edges == second.edges
    assert first.layout_hints == second.layout_hints
    assert first.truncated == %{nodes: true, edges: true}
    assert length(first.nodes) == 3
    assert length(first.edges) == 1

    Enum.each(first.layout_hints, fn {_id, %{x: x, y: y}} ->
      assert x >= 0.0 and x <= 1.0
      assert y >= 0.0 and y <= 1.0
    end)
  end

  test "incremental atlas clustering does not absorb an unrelated component" do
    scope = {:subject, "dirty-components"}
    first = signal!("component one first", scope)
    second = signal!("component one second", scope)
    outside_left = signal!("outside left", scope)
    outside_right = signal!("outside right", scope)
    {:ok, _edge} = SpectreMnemonic.link(first.id, :supports, second.id, scope: scope)

    {:ok, _edge} =
      SpectreMnemonic.link(outside_left.id, :supports, outside_right.id, scope: scope)

    assert {:ok, _clusters} = Atlas.materialize(scope: scope)
    added = signal!("component one added", scope)
    {:ok, _edge} = SpectreMnemonic.link(first.id, :supports, added.id, scope: scope)

    assert {:ok, clusters} = Atlas.materialize(scope: scope)
    assert clusters != []

    Enum.each(clusters, fn cluster ->
      refute outside_left.id in cluster.moment_ids
      refute outside_right.id in cluster.moment_ids
    end)
  end

  test "entity aggregation reuses canonical ids only inside one partition" do
    scope = {:subject, "entity-aggregation"}
    neighbor = {:subject, "entity-neighbor"}

    Enum.each(["Alice called Bob", "Alice reviewed deploy", "Alice approved release"], fn text ->
      assert {:ok, _packet} = SpectreMnemonic.remember(text, scope: scope)
    end)

    alice = entities_named("alice", scope)
    assert length(alice) == 1
    assert {:ok, resolved} = Resolver.resolve("ALICE", ["Ally"], scope: scope)
    assert resolved.id == hd(alice).id
    assert {:ok, aliased} = Resolver.resolve("ally", [], scope: scope)
    assert aliased.id == resolved.id

    assert {:ok, _packet} = SpectreMnemonic.remember("Alice called Bob", scope: neighbor)
    [neighbor_alice] = entities_named("alice", neighbor)
    assert neighbor_alice.id != resolved.id
  end

  test "cross-memory aggregation respects similarity threshold cap and partition" do
    scope = {:subject, "aggregation-cap"}
    neighbor = {:subject, "aggregation-neighbor"}

    Enum.each(1..4, fn index ->
      assert {:ok, _memory} =
               SpectreMnemonic.signal("candidate #{index}", scope: scope, embedding: [1.0, 0.0])
    end)

    {:ok, %{moment: outside}} =
      SpectreMnemonic.signal("outside candidate", scope: neighbor, embedding: [1.0, 0.0])

    assert {:ok, packet} =
             SpectreMnemonic.remember("new semantic root",
               scope: scope,
               embedding: [1.0, 0.0],
               extract_entities?: false,
               cross_memory_similarity_threshold: 0.99,
               max_cross_memory_edges: 2
             )

    related = Enum.filter(packet.associations, &(&1.relation == :related_memory))
    assert length(related) == 2
    refute Enum.any?(related, &(&1.target_id == outside.id))
    assert Enum.all?(related, &(&1.metadata.similarity >= 0.99))

    assert {:ok, disabled} =
             SpectreMnemonic.remember("another semantic root",
               scope: scope,
               embedding: [1.0, 0.0],
               extract_entities?: false,
               cross_memory?: false
             )

    refute Enum.any?(disabled.associations, &(&1.relation == :related_memory))
  end

  test "plasticity reinforcement is monotonic and decay respects its floor" do
    scope = {:subject, "plasticity-bounds"}
    left = signal!("plastic left", scope)
    right = signal!("plastic right", scope)
    {:ok, edge} = SpectreMnemonic.link(left.id, :supports, right.id, scope: scope, weight: 0.2)
    path = %{right.id => %{hops: [%{association_id: edge.id}]}}

    weights =
      Enum.map(1..5, fn _iteration ->
        assert {:ok, 1} = Plasticity.reinforce(path, scope: scope, reinforcement_rate: 0.25)
        association(edge.id).weight
      end)

    assert weights == Enum.sort(weights)
    assert Enum.uniq(weights) == weights
    assert List.last(weights) < 1.0

    assert {:ok, 1} =
             Plasticity.decay(
               scope: scope,
               decay_factor: 0.0,
               weight_floor: 0.15,
               used_before: DateTime.add(DateTime.utc_now(), 1, :second)
             )

    assert_in_delta association(edge.id).weight, 0.15, 1.0e-12
  end

  test "recall trace includes both graph hops and deterministic cluster membership" do
    scope = {:subject, "trace-clusters"}
    seed = signal!("unique trace anchor", scope)
    context = signal!("cluster context", scope)
    {:ok, edge} = SpectreMnemonic.link(seed.id, :supports, context.id, scope: scope)

    assert {:ok, packet} =
             SpectreMnemonic.recall("unique trace anchor",
               scope: scope,
               trace: true,
               plasticity?: false,
               graph_depth: 1,
               activation_floor: 0.0,
               limit: 10
             )

    assert [%{association_id: association_id}] = packet.trace[context.id].hops
    assert association_id == edge.id
    assert packet.trace[seed.id].clusters != []
    assert packet.trace[context.id].clusters != []
  end

  defp signal!(text, scope) do
    {:ok, %{moment: moment}} = SpectreMnemonic.signal(text, scope: scope)
    moment
  end

  defp entities_named(canonical, scope) do
    scope
    |> then(&Focus.moments(scope: &1))
    |> Enum.filter(fn moment ->
      moment.kind == :memory_entity and Map.get(moment.metadata, :canonical) == canonical
    end)
  end

  defp association(id) do
    [{^id, association}] = ActiveETS.lookup(:mnemonic_associations, id)
    association
  end
end
