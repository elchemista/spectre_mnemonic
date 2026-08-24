defmodule SpectreMnemonic.MemoryLifecycleTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Atlas
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Export
  alias SpectreMnemonic.Export.CanonicalJSON
  alias SpectreMnemonic.Export.Reader
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Graph.Resolver
  alias SpectreMnemonic.Knowledge.SMEM
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Disk
  alias SpectreMnemonic.Persistence.Store.File, as: FileStore
  alias SpectreMnemonic.Recall.Index, as: RecallIndex

  @namespace "spectre_mnemonic_test"

  defmodule ShredAdapter do
    @moduledoc false

    def shred(context, _opts), do: {:ok, context}
  end

  defmodule AtlasLabelAdapter do
    @moduledoc false

    @behaviour SpectreMnemonic.Atlas.LabelAdapter

    @impl true
    def label(input, _opts) do
      {:ok, "release coordination (#{length(input.member_ids)})"}
    end
  end

  test "weighted traversal exposes a trace and reinforcement is append-only" do
    scope = {:subject, "trace"}

    {:ok, %{moment: seed}} =
      SpectreMnemonic.signal("deploy moved to friday", scope: scope, persist?: true)

    {:ok, %{moment: context}} =
      SpectreMnemonic.signal("calendar owner alice", scope: scope, persist?: true)

    {:ok, edge} =
      SpectreMnemonic.link(seed.id, :mentions_entity, context.id,
        scope: scope,
        weight: 0.4,
        persist?: true
      )

    assert {:ok, packet} =
             SpectreMnemonic.recall("deploy friday",
               scope: scope,
               trace: true,
               plasticity?: false,
               limit: 10
             )

    assert packet.trace[seed.id].hops == []
    assert [%{association_id: association_id}] = packet.trace[context.id].hops
    assert association_id == edge.id

    assert {:ok, 1} = Plasticity.reinforce(packet.trace, scope: scope)
    [updated] = Enum.filter(Focus.associations(scope: scope), &(&1.id == edge.id))
    assert updated.weight > edge.weight

    assert {:ok, records} = Manager.replay(scope: scope)
    durable = Enum.find(records, &(&1.family == :associations and &1.payload.id == edge.id))
    assert durable.payload.weight == updated.weight
  end

  test "caller embeddings use Vettore for fast partition-local semantic recall" do
    scope = {:subject, "vettore-alpha"}
    neighbor = {:subject, "vettore-beta"}

    {:ok, %{moment: match}} =
      SpectreMnemonic.signal("opaque first memory", scope: scope, embedding: [1.0, 0.0, 0.0])

    {:ok, %{moment: miss}} =
      SpectreMnemonic.signal("opaque second memory", scope: scope, vector: [-1.0, 0.0, 0.0])

    {:ok, %{moment: outside}} =
      SpectreMnemonic.signal("opaque neighbor memory",
        scope: neighbor,
        embedding: [1.0, 0.0, 0.0]
      )

    assert match.embedding.metadata.provider == :caller
    assert Vector.dimensions(match.vector) == 3

    cue = Service.embed("unused", embedding: [1.0, 0.0, 0.0])

    assert {:ok, [first | rest]} = RecallIndex.query(cue, scope: scope, overfetch: 2)
    assert first.id == match.id
    assert Enum.any?(rest, &(&1.id == miss.id))
    refute Enum.any?([first | rest], &(&1.id == outside.id))

    state = :sys.get_state(RecallIndex)
    assert Map.has_key?(state.vettore, {@namespace, scope})
    assert Map.has_key?(state.vettore, {@namespace, neighbor})
  end

  test "semantic similarity creates a useful cross-memory graph edge" do
    scope = {:subject, "semantic-links"}

    {:ok, %{moment: existing}} =
      SpectreMnemonic.signal("unrelated vocabulary alpha",
        scope: scope,
        embedding: [0.8, 0.2, 0.0]
      )

    assert {:ok, packet} =
             SpectreMnemonic.remember("completely different words beta",
               scope: scope,
               embedding: [0.8, 0.2, 0.0],
               extract_entities?: false
             )

    assert is_binary(packet.root.vector)

    assert Enum.any?(packet.associations, fn association ->
             association.relation == :related_memory and association.target_id == existing.id and
               association.metadata.similarity > 0.99
           end)
  end

  test "caller embedding metadata is retained and malformed vectors degrade safely" do
    scope = {:subject, "direct-embeddings"}

    assert {:ok, %{moment: valid}} =
             SpectreMnemonic.signal("caller model output",
               scope: scope,
               embedding: %{
                 vector: [0.2, 0.4, 0.8],
                 metadata: %{model: "private-model", revision: 7}
               }
             )

    assert valid.embedding.metadata.model == "private-model"
    assert valid.embedding.metadata.revision == 7
    assert valid.embedding.metadata.provider == :caller

    assert {:ok, %{moment: malformed}} =
             SpectreMnemonic.signal("still searchable as text",
               scope: scope,
               embedding: [1.0, :not_a_number]
             )

    assert malformed.vector == nil
    assert malformed.binary_signature == nil
    assert malformed.embedding.error == :invalid_embedding
  end

  test "Vettore supports quantized and exact strategies, replacement, and deletion" do
    scope = {:subject, "vettore-lifecycle"}

    Application.put_env(:spectre_mnemonic, :embedding,
      index: [
        backend: :vettore,
        vettore_index: :flat,
        vettore_index_options: :invalid,
        strategy: :quantized
      ]
    )

    {:ok, %{moment: match}} =
      SpectreMnemonic.signal("first vector", scope: scope, embedding: [1.0, 0.0])

    {:ok, %{moment: other}} =
      SpectreMnemonic.signal("second vector", scope: scope, embedding: [0.0, 1.0])

    first_cue = Service.embed("unused", vector: [1.0, 0.0])
    assert {:ok, [%{id: match_id} | _rest]} = RecallIndex.query(first_cue, scope: scope)
    assert match_id == match.id

    {:ok, %{moment: different_dimensions}} =
      SpectreMnemonic.signal("three dimensional vector",
        scope: scope,
        embedding: [0.0, 0.0, 1.0]
      )

    Application.put_env(:spectre_mnemonic, :embedding,
      index: [backend: :vettore, vettore_index: :flat, strategy: :hybrid]
    )

    different_cue = Service.embed("unused", vector: [0.0, 0.0, 1.0])
    assert {:ok, different_results} = RecallIndex.query(different_cue, scope: scope)
    assert Enum.any?(different_results, &(&1.id == different_dimensions.id))

    replacement = Service.embed("unused", vector: [0.0, 1.0])

    assert :ok =
             RecallIndex.upsert(%{
               match
               | vector: replacement.vector,
                 binary_signature: replacement.binary_signature,
                 embedding: replacement
             })

    Application.put_env(:spectre_mnemonic, :embedding,
      index: [backend: :vettore, vettore_index: :flat, strategy: :exact]
    )

    assert {:ok, exact_results} = RecallIndex.query(replacement, scope: scope, overfetch: 2)
    assert Enum.any?(exact_results, &(&1.id == match.id))
    assert Enum.any?(exact_results, &(&1.id == other.id))

    assert :ok = RecallIndex.delete(match.id)
    assert {:ok, remaining} = RecallIndex.query(replacement, scope: scope, overfetch: 2)
    refute Enum.any?(remaining, &(&1.id == match.id))
    assert Enum.any?(remaining, &(&1.id == other.id))

    :ets.delete(:mnemonic_embedding_index, other.id)
    assert {:ok, []} = RecallIndex.query(replacement, scope: scope, overfetch: 2)

    fallback_scope = {:subject, "vettore-unavailable-index"}

    Application.put_env(:spectre_mnemonic, :embedding,
      index: [backend: :vettore, vettore_index: :not_an_index]
    )

    assert {:ok, %{moment: fallback}} =
             SpectreMnemonic.signal("fallback vector", scope: fallback_scope, vector: [1.0, 0.0])

    assert {:ok, [%{id: fallback_id}]} =
             RecallIndex.query(fallback.embedding, scope: fallback_scope, overfetch: 1)

    assert fallback_id == fallback.id

    Application.put_env(:spectre_mnemonic, :embedding, index: [enabled: false])
    assert {:ok, []} = RecallIndex.query(replacement, scope: scope, overfetch: 0)
  end

  test "atlas is deterministic, bounded, and partition hermetic" do
    scope = {:subject, "atlas"}
    neighbor = {:subject, "neighbor"}

    {:ok, %{moment: left}} = SpectreMnemonic.signal("deploy planning", scope: scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("friday release", scope: scope)
    {:ok, %{moment: outside}} = SpectreMnemonic.signal("private neighbor", scope: neighbor)
    {:ok, _edge} = SpectreMnemonic.link(left.id, :supports, right.id, scope: scope, weight: 0.9)

    assert {:ok, first} = SpectreMnemonic.atlas(scope: scope)
    assert {:ok, second} = SpectreMnemonic.atlas(scope: scope)
    assert first.clusters == second.clusters
    assert first.stats.nodes == 2
    assert first.stats.edges == 1
    assert first.stats.clusters == 1
    refute Enum.any?(first.nodes, &(&1.id == outside.id))
    assert Enum.all?(first.edges, &(&1.scope == scope))
  end

  test "atlas consumes dirty connected components and supports optional labels" do
    scope = {:subject, "incremental-atlas"}

    {:ok, %{moment: first}} = SpectreMnemonic.signal("release owner alice", scope: scope)
    {:ok, %{moment: second}} = SpectreMnemonic.signal("release date friday", scope: scope)
    {:ok, %{moment: third}} = SpectreMnemonic.signal("release checklist", scope: scope)
    {:ok, _edge} = SpectreMnemonic.link(first.id, :supports, second.id, scope: scope)
    {:ok, _edge} = SpectreMnemonic.link(second.id, :supports, third.id, scope: scope)

    assert Enum.sort(Atlas.dirty_ids(scope: scope)) == Enum.sort([first.id, second.id, third.id])

    assert {:ok, [episode]} =
             Atlas.materialize(scope: scope, atlas_label_adapter: AtlasLabelAdapter)

    assert episode.title == "release coordination (3)"
    refute episode.metadata.deterministic?
    assert episode.metadata.label_source == :adapter
    assert Atlas.dirty_ids(scope: scope) == []
    assert {:ok, []} = Atlas.materialize(scope: scope)

    assert {:ok, [reclustered]} =
             Atlas.materialize(
               scope: scope,
               recluster: true,
               atlas_label_adapter: fn _input -> raise "adapter unavailable" end
             )

    assert reclustered.metadata.deterministic?
    assert is_binary(reclustered.title)
  end

  test "entity aliases resolve deterministically and explicit merges redirect the registry" do
    scope = {:subject, "resolver"}

    {:ok, packet} =
      SpectreMnemonic.remember("Alice called Bob", scope: scope, persist?: true)

    alice =
      Enum.find(packet.moments, &(&1.kind == :memory_entity and &1.metadata.canonical == "alice"))

    bob =
      Enum.find(packet.moments, &(&1.kind == :memory_entity and &1.metadata.canonical == "bob"))

    assert Resolver.normalize("  ALICE-Marie  ") == "alice marie"
    assert {:ok, resolved} = Resolver.resolve("Alice", ["ALLY"], scope: scope)
    assert resolved.id == alice.id
    assert {:ok, aliased} = Resolver.resolve("ally", [], scope: scope)
    assert aliased.id == alice.id

    assert {:ok, same_as} = SpectreMnemonic.merge_entities(alice.id, bob.id, scope: scope)
    assert same_as.relation == :same_as
    :ets.delete_all_objects(:mnemonic_entity_registry)
    assert {:ok, redirected} = Resolver.resolve("bob", [], scope: scope)
    assert redirected.id == alice.id

    assert :ok = SpectreMnemonic.unmerge_entities(alice.id, bob.id, scope: scope)
    :ets.delete_all_objects(:mnemonic_entity_registry)
    assert {:ok, restored_bob} = Resolver.resolve("bob", [], scope: scope)
    assert restored_bob.id == bob.id

    assert {:error, :merge_not_found} =
             SpectreMnemonic.unmerge_entities(alice.id, bob.id, scope: scope)

    assert {:error, :same_entity_id} =
             SpectreMnemonic.unmerge_entities(alice.id, alice.id, scope: scope)

    assert {:error, :same_entity_id} = SpectreMnemonic.merge_entities(alice.id, alice.id)

    assert {:error, :unknown_entity} =
             SpectreMnemonic.merge_entities(alice.id, "missing", scope: scope)
  end

  test "plasticity decays eligible edges across partitions and protects identity edges" do
    first_scope = {:subject, "decay-a"}
    second_scope = {:subject, "decay-b"}

    {:ok, %{moment: first_a}} = SpectreMnemonic.signal("first alpha", scope: first_scope)
    {:ok, %{moment: first_b}} = SpectreMnemonic.signal("second alpha", scope: first_scope)
    {:ok, %{moment: second_a}} = SpectreMnemonic.signal("first beta", scope: second_scope)
    {:ok, %{moment: second_b}} = SpectreMnemonic.signal("second beta", scope: second_scope)

    {:ok, first_edge} =
      SpectreMnemonic.link(first_a.id, :supports, first_b.id, scope: first_scope, weight: 0.8)

    {:ok, second_edge} =
      SpectreMnemonic.link(second_a.id, :supports, second_b.id, scope: second_scope, weight: 0.6)

    assert {:ok, 1} =
             Plasticity.decay(
               scope: first_scope,
               decay_factor: 0.5,
               weight_floor: 0.1
             )

    assert_in_delta association(first_edge.id).weight, 0.45, 1.0e-12
    assert {:ok, count} = Plasticity.decay_all(decay_factor: 0.5, weight_floor: 0.1)
    assert count == 2
    assert association(first_edge.id).weight < 0.45
    assert association(second_edge.id).weight < 0.6
    assert {:ok, 0} = Plasticity.reinforce(%{}, scope: first_scope)
  end

  test "resolver repairs stale registry entries and plasticity handles path variants" do
    scope = {:subject, "edge-branches"}
    partition = {@namespace, scope}

    assert :miss = Resolver.resolve("Nobody", [], scope: scope)
    :ets.insert(:mnemonic_entity_registry, {{partition, "ghost"}, "missing"})
    assert :miss = Resolver.resolve("ghost", [], scope: scope)
    assert :ets.lookup(:mnemonic_entity_registry, {partition, "ghost"}) == []
    assert {:error, :not_an_entity} = Resolver.register(%Moment{kind: :text})
    assert Resolver.signal_for(%Moment{signal_id: "missing"}) == nil

    {:ok, packet} = SpectreMnemonic.remember("Alice met Bob", scope: scope)

    alice =
      Enum.find(packet.moments, &(&1.kind == :memory_entity and &1.metadata.canonical == "alice"))

    :ets.match_delete(:mnemonic_entity_registry, {{partition, :_}, :_})
    assert {:ok, seeded} = Resolver.resolve("alice", [], scope: scope)
    assert seeded.id == alice.id

    plasticity_scope = {:subject, "path-variants"}
    {:ok, %{moment: left}} = SpectreMnemonic.signal("left branch", scope: plasticity_scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("right branch", scope: plasticity_scope)

    {:ok, edge} =
      SpectreMnemonic.link(left.id, :supports, right.id, scope: plasticity_scope, weight: 0.5)

    paths = [%{hops: [%{association_id: edge.id}]}]

    assert {:ok, 1} =
             Plasticity.reinforce(paths, scope: plasticity_scope, reinforcement_rate: 2)

    assert association(edge.id).weight == 1.0
    assert {:ok, 0} = Plasticity.reinforce(:invalid, scope: plasticity_scope)

    before_use = DateTime.add(DateTime.utc_now(), -60, :second)
    assert {:ok, 0} = Plasticity.decay(scope: plasticity_scope, used_before: before_use)

    assert {:error, {:invalid_plasticity_option, :used_before, :invalid}} =
             Plasticity.decay(scope: plasticity_scope, used_before: :invalid)
  end

  test "export is deterministic, verified, structure-only, and never leaks secrets" do
    scope = {:subject, "export"}
    key = :crypto.strong_rand_bytes(32)
    first_path = Path.expand("mnemonic_data/first.mnemonic")
    second_path = Path.expand("mnemonic_data/second.mnemonic")
    full_path = Path.expand("mnemonic_data/full.mnemonic")

    {:ok, _packet} =
      SpectreMnemonic.remember("Alice moved the deploy to Friday",
        scope: scope,
        persist?: true
      )

    {:ok, _secret} =
      SpectreMnemonic.signal("sk_live_super_secret",
        scope: scope,
        secret?: true,
        label: "billing token",
        secret_key: key,
        persist?: true
      )

    assert {:ok, report} = SpectreMnemonic.export(first_path, scope: scope)
    assert {:ok, _report} = SpectreMnemonic.export(second_path, scope: scope)
    assert File.read!(first_path) == File.read!(second_path)

    assert {:ok, structure} = Export.read(first_path)
    assert structure.trailer["content_digest"] == report.content_digest
    refute inspect(structure) =~ "Alice moved the deploy to Friday"
    refute inspect(structure) =~ "sk_live_super_secret"
    assert {:ok, stream} = Export.stream(first_path)
    assert stream |> Enum.map(& &1["section"]) |> length() == 8

    redacted_path = Path.expand("mnemonic_data/redacted.mnemonic")

    assert {:ok, _report} =
             SpectreMnemonic.export(redacted_path,
               scope: scope,
               mode: {:redacted, fn payload -> %{id: Map.get(payload, :id), redacted: true} end},
               include: [:nodes]
             )

    assert {:ok, redacted} = Export.read(redacted_path)
    assert redacted.edges == []
    assert Enum.all?(redacted.nodes, &(&1["redacted"] == true or &1["secret"] == true))

    assert {:ok, _report} =
             SpectreMnemonic.export(full_path, scope: scope, mode: :full, embeddings?: true)

    assert {:ok, full} = Export.read(full_path)
    refute inspect(full) =~ "sk_live_super_secret"
    assert Enum.any?(full.nodes, &(&1["secret"] == true and &1["label"] == "billing token"))

    corrupted = File.read!(first_path)
    size = byte_size(corrupted)
    prefix = binary_part(corrupted, 0, size - 1)
    last = :binary.at(corrupted, size - 1)
    File.write!(first_path, <<prefix::binary, Bitwise.bxor(last, 1)>>)
    assert {:error, _reason} = Export.read(first_path)
  end

  test "export can exclude active projections and reader rejects malformed frames" do
    scope = {:subject, "export-errors"}
    path = Path.expand("mnemonic_data/no-active.mnemonic")
    malformed = Path.expand("mnemonic_data/malformed.mnemonic")

    {:ok, _memory} = SpectreMnemonic.signal("active only", scope: scope, persist?: false)
    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope, active?: false)
    assert {:ok, export} = Export.read(path)
    assert export.nodes == []
    assert export.clusters == []
    assert export.manifest["created_at"] == "1970-01-01T00:00:00Z"

    File.write!(malformed, "SMNE")
    assert {:error, {:truncated_mnemonic_header, 1}} = Export.read(malformed)

    invalid_gzip = "not-gzip"
    crc = :erlang.crc32(invalid_gzip)

    File.write!(
      malformed,
      <<"SMNE", 1, 1::unsigned-64, byte_size(invalid_gzip)::unsigned-32, crc::unsigned-32,
        invalid_gzip::binary>>
    )

    assert {:error, {:invalid_mnemonic_compression, 1}} = Export.read(malformed)

    invalid_json = :zlib.gzip("not json")
    crc = :erlang.crc32(invalid_json)

    File.write!(
      malformed,
      <<"SMNE", 1, 1::unsigned-64, byte_size(invalid_json)::unsigned-32, crc::unsigned-32,
        invalid_json::binary>>
    )

    assert {:error, {:invalid_mnemonic_json, 1}} = Export.read(malformed)
  end

  test "export chunks large sections and the verified stream remains lazy" do
    scope = {:subject, "chunked-export"}
    path = Path.expand("mnemonic_data/chunked.mnemonic")

    Enum.each(1..12, fn index ->
      assert {:ok, _result} =
               SpectreMnemonic.signal(
                 "chunked memory #{index} with enough structural metadata",
                 scope: scope,
                 persist?: true
               )
    end)

    assert {:ok, report} =
             SpectreMnemonic.export(path, scope: scope, frame_target_bytes: 1_200)

    assert {:ok, stream} = Export.stream(path)
    refute is_list(stream)
    frames = Enum.to_list(stream)
    assert Enum.count(frames, &(&1["section"] == "nodes")) > 1

    assert {:ok, decoded} = Export.read(path)
    assert length(decoded.nodes) == report.counts["nodes"]
    assert decoded.manifest["counts"] == decoded.trailer["counts"]
  end

  test "reader rejects semantic, partition, framing, and accounting violations" do
    path = Path.expand("mnemonic_data/conformance-errors.mnemonic")
    sections = ~w(nodes edges clusters models knowledge governance)
    counts = Map.new(sections, &{&1, 0})
    content = Enum.map(sections, &%{"section" => &1, "data" => []})
    digest = content_digest(content)
    scope_digest = String.duplicate("a", 64)

    manifest = %{
      "format" => "spectre-mnemonic",
      "format_version" => 1,
      "library_version" => "0.4.0",
      "namespace" => @namespace,
      "scope" => "{:subject, \"conformance\"}",
      "scope_digest" => scope_digest,
      "privacy_mode" => "structure",
      "created_at" => "1970-01-01T00:00:00Z",
      "content_digest" => digest,
      "counts" => counts
    }

    trailer = %{"content_digest" => digest, "counts" => counts}
    manifest_frame = %{"section" => "manifest", "data" => manifest}
    trailer_frame = %{"section" => "trailer", "data" => trailer}
    valid_frames = [manifest_frame | content] ++ [trailer_frame]

    write_mnemonic(path, valid_frames)
    assert {:ok, _frames} = Reader.read(path)
    assert {:ok, verified_stream} = Reader.stream(path)
    File.write!(path, "broken")
    assert [{:error, {:truncated_mnemonic_header, 1}}] = Enum.to_list(verified_stream)

    write_mnemonic(path, valid_frames)
    assert {:ok, missing_stream} = Reader.stream(path)
    File.rm!(path)

    assert [{:error, {:mnemonic_open_failed, ^path, :enoent}}] =
             Enum.to_list(missing_stream)

    write_mnemonic(
      path,
      [%{manifest_frame | "data" => %{manifest | "format_version" => 2}} | content] ++
        [trailer_frame]
    )

    assert {:error, {:unsupported_mnemonic_format, _manifest}} = Export.read(path)

    write_mnemonic(
      path,
      [
        %{manifest_frame | "data" => %{manifest | "content_digest" => String.duplicate("0", 64)}}
        | content
      ] ++
        [
          %{
            trailer_frame
            | "data" => %{trailer | "content_digest" => String.duplicate("0", 64)}
          }
        ]
    )

    assert {:error, :mnemonic_digest_mismatch} = Export.read(path)

    wrong_counts = Map.put(counts, "nodes", 1)

    write_mnemonic(
      path,
      [%{manifest_frame | "data" => %{manifest | "counts" => wrong_counts}} | content] ++
        [%{trailer_frame | "data" => %{trailer | "counts" => wrong_counts}}]
    )

    assert {:error, {:mnemonic_count_mismatch, _actual, ^wrong_counts, ^wrong_counts}} =
             Export.read(path)

    mixed = [
      %{
        "section" => "nodes",
        "data" => [
          %{
            "family" => "moments",
            "id" => "mixed",
            "inserted_at" => "1970-01-01T00:00:00Z",
            "namespace" => "another",
            "scope_digest" => scope_digest
          }
        ]
      }
      | Enum.drop(content, 1)
    ]

    write_mnemonic(path, [manifest_frame | mixed] ++ [trailer_frame])
    assert {:error, {:mixed_mnemonic_partition, _record}} = Export.read(path)

    write_mnemonic(path, [manifest_frame, Enum.at(content, 1)])
    assert {:error, :invalid_mnemonic_sections} = Export.read(path)

    write_mnemonic(path, [%{"section" => "unknown", "data" => []}])
    assert {:error, :invalid_mnemonic_sections} = Export.read(path)

    write_mnemonic(path, [%{"unexpected" => true}])
    assert {:error, {:invalid_mnemonic_frame, 1}} = Export.read(path)

    File.write!(path, <<"NOPE", 1, 1::unsigned-64, 0::unsigned-32, 0::unsigned-32>>)
    assert {:error, {:invalid_mnemonic_header, 1, "NOPE", 1}} = Export.read(path)

    File.write!(path, <<"SMNE", 1, 2::unsigned-64, 0::unsigned-32, 0::unsigned-32>>)
    assert {:error, {:invalid_mnemonic_sequence, 1, 2}} = Export.read(path)

    File.write!(path, <<"SMNE", 1, 1::unsigned-64, 4::unsigned-32, 0::unsigned-32, 1, 2>>)
    assert {:error, {:truncated_mnemonic_frame, 1}} = Export.read(path)

    File.write!(path, <<>>)
    assert {:error, :invalid_mnemonic_sections} = Export.read(path)

    File.write!(path, <<"SMNE", 1, 1::unsigned-64, 0::unsigned-32, 0::unsigned-32>>)
    assert {:error, {:invalid_mnemonic_compression, 1}} = Export.read(path)

    assert {:error, {:mnemonic_open_failed, _, :enoent}} = Reader.read(path <> ".missing")
  end

  test "partition erasure removes evicted durable records and preserves its neighbor" do
    erased_scope = {:subject, "erase-me"}
    neighbor_scope = {:subject, "keep-me"}

    Application.put_env(:spectre_mnemonic, :hot_memory,
      max_moments_per_scope: 1,
      max_moments_per_namespace: 10
    )

    {:ok, %{moment: first}} =
      SpectreMnemonic.signal("first durable subject record",
        scope: erased_scope,
        persist?: true
      )

    {:ok, _second} =
      SpectreMnemonic.signal("second durable subject record",
        scope: erased_scope,
        persist?: true
      )

    refute Enum.any?(Focus.moments(scope: erased_scope), &(&1.id == first.id))

    {:ok, %{moment: neighbor}} =
      SpectreMnemonic.signal("neighbor must survive",
        scope: neighbor_scope,
        persist?: true
      )

    assert {:ok, report} =
             SpectreMnemonic.erase_partition(
               namespace: @namespace,
               scope: erased_scope,
               sealed: true
             )

    assert report.compaction == :erased
    assert report.families.moments > 0
    assert Focus.moments(scope: erased_scope) == []

    assert {:ok, erased_records} = Manager.replay(scope: erased_scope)
    assert Enum.all?(erased_records, &(&1.family == :erasure_markers))

    assert {:ok, neighbor_records} = Manager.replay(scope: neighbor_scope)

    assert Enum.any?(
             neighbor_records,
             &(&1.family == :moments and &1.payload.id == neighbor.id)
           )

    assert {:error, :partition_erased} =
             SpectreMnemonic.signal("must not resurrect", scope: erased_scope)

    refute File.exists?(Path.expand("mnemonic_data/snapshots/previous.term"))
    assert Path.wildcard(Path.expand("mnemonic_data/segments/compacted-*.smem")) == []

    assert {:ok, repeated} =
             SpectreMnemonic.erase_partition(namespace: @namespace, scope: erased_scope)

    assert repeated.already_erased?
  end

  test "erasure rewrites knowledge physically and stale restored data cannot resurrect" do
    scope = {:subject, "erase-stale"}
    opts = [namespace: @namespace, scope: scope]
    knowledge_path = SMEM.path(opts)
    active_path = Path.expand("mnemonic_data/segments/active.smem")

    assert {:ok, _memory} = SpectreMnemonic.signal("durable old memory", scope: scope)
    assert {:ok, _sequence} = SMEM.append(%{type: :fact, text: "durable old knowledge"}, opts)
    old_knowledge = File.read!(knowledge_path)
    old_store = File.read!(active_path)

    assert {:ok, _report} = SpectreMnemonic.erase_partition(opts)
    assert {:ok, []} = SMEM.replay(opts)
    assert :ok = SMEM.verify_erased(opts)
    assert :ok = FileStore.verify_erased([], @namespace, scope, MapSet.new())

    assert {:ok, raw_events} =
             SMEM.reduce(opts, [], fn {_sequence, _timestamp, event}, acc ->
               {:cont, [event | acc]}
             end)

    assert [%{type: :compaction_marker, metadata: %{erasure?: true}}] = raw_events

    File.write!(knowledge_path, old_knowledge)
    File.write!(active_path, old_store, [:append])

    assert {:ok, []} = SMEM.replay(opts)
    assert {:ok, records} = Manager.replay(opts)
    assert Enum.all?(records, &(&1.family == :erasure_markers))
  end

  test "sealed erasure also blocks progressive knowledge writes" do
    scope = {:subject, "sealed-knowledge"}
    opts = [namespace: @namespace, scope: scope, sealed: true]

    assert {:ok, _memory} = SpectreMnemonic.signal("erase this", scope: scope)
    assert {:ok, _report} = SpectreMnemonic.erase_partition(opts)

    assert {:error, :partition_erased} =
             SMEM.append(%{type: :fact, text: "must not return"}, opts)
  end

  test "unsealed erasure starts clean new history while explicit context fails closed" do
    scope = {:subject, "reusable"}

    assert {:error, :erasure_namespace_required} =
             SpectreMnemonic.erase_partition(scope: scope)

    assert {:error, :erasure_scope_required} =
             SpectreMnemonic.erase_partition(namespace: @namespace)

    {:ok, %{moment: old}} = SpectreMnemonic.signal("old history", scope: scope, persist?: true)

    assert {:ok, report} =
             SpectreMnemonic.erase_partition(namespace: @namespace, scope: scope)

    refute report.already_erased?

    assert {:ok, %{moment: fresh}} =
             SpectreMnemonic.signal("fresh history", scope: scope, persist?: true)

    assert fresh.id != old.id

    assert {:ok, records} = Manager.replay(scope: scope)
    refute Enum.any?(records, &(&1.family == :moments and &1.payload.id == old.id))
    assert Enum.any?(records, &(&1.family == :moments and &1.payload.id == fresh.id))

    assert {:ok, shred_context} =
             SpectreMnemonic.Secrets.shred(scope, crypto_adapter: ShredAdapter)

    assert shred_context.namespace == @namespace
    assert shred_context.scope == scope
  end

  test "sweep_expired uses the normal forget cascade" do
    scope = {:subject, "retention"}
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("expired memory", scope: scope, valid_until: past, persist?: true)

    assert {:ok, 1} = SpectreMnemonic.sweep_expired(scope: scope)
    refute Enum.any?(Focus.moments(scope: scope), &(&1.id == moment.id))
  end

  test "sweep_expired also tombstones durable moments evicted from hot memory" do
    scope = {:subject, "retention-evicted"}
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Application.put_env(:spectre_mnemonic, :hot_memory,
      max_moments_per_scope: 1,
      max_moments_per_namespace: 10
    )

    {:ok, %{moment: expired}} =
      SpectreMnemonic.signal("expired durable memory",
        scope: scope,
        valid_until: past,
        persist?: true
      )

    {:ok, %{moment: current}} =
      SpectreMnemonic.signal("current durable memory", scope: scope, persist?: true)

    refute Enum.any?(Focus.moments(scope: scope), &(&1.id == expired.id))
    assert {:ok, 1} = SpectreMnemonic.sweep_expired(scope: scope)

    assert {:ok, records} = Manager.replay(scope: scope)
    refute Enum.any?(records, &(&1.family == :moments and &1.payload.id == expired.id))
    assert Enum.any?(records, &(&1.family == :moments and &1.payload.id == current.id))
  end

  test "legacy disk facade still replays and compacts the default store" do
    assert Disk.data_root() == "mnemonic_data"
    assert {:ok, _write} = Disk.append(:knowledge, %{id: "legacy-knowledge", text: "legacy"})
    assert {:ok, frames} = Disk.replay()
    assert Enum.any?(frames, &match?({_sequence, _timestamp, {:knowledge, _payload}}, &1))
    assert {:ok, snapshot} = Disk.compact()
    assert File.exists?(snapshot)
  end

  defp association(id) do
    [{^id, association}] = :ets.lookup(:mnemonic_associations, id)
    association
  end

  defp content_digest(frames) do
    frames
    |> Enum.map_join("", &CanonicalJSON.encode/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_mnemonic(path, frames) do
    binary =
      frames
      |> Enum.with_index(1)
      |> Enum.map(fn {frame, sequence} ->
        payload = frame |> CanonicalJSON.encode() |> :zlib.gzip()

        <<"SMNE", 1, sequence::unsigned-64, byte_size(payload)::unsigned-32,
          :erlang.crc32(payload)::unsigned-32, payload::binary>>
      end)
      |> IO.iodata_to_binary()

    File.write!(path, binary)
  end
end
