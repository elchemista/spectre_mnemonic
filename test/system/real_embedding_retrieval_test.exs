defmodule SpectreMnemonic.RealEmbeddingRetrievalTest do
  use SpectreMnemonic.MemoryCase

  @moduletag :real_embedding

  alias Spectre.Classifier.Embeddings.ExFastembed, as: FastembedAdapter
  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Recall.Index, as: RecallIndex

  @model "Xenova/bge-small-en-v1.5"

  setup_all do
    model = System.get_env("MNEMONIC_EMBEDDING_MODEL") || @model

    case FastembedAdapter.load(model) do
      {:ok, dimensions} when dimensions > 0 ->
        {:ok, model: model, dimensions: dimensions}

      {:error, reason} ->
        flunk("could not load the local embedding model: #{inspect(reason)}")
    end
  end

  setup do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, FastembedAdapter)
    :ok
  end

  test "local inference produces finite normalized vectors", %{
    model: model,
    dimensions: dimensions
  } do
    first = Service.embed("A car needs fuel before a long journey", [])
    second = Service.embed("Quarterly invoices need finance approval", [])

    assert first.error == nil
    assert first.metadata.provider == FastembedAdapter
    assert first.metadata.dimensions == dimensions
    assert first.metadata.model == nil
    assert is_binary(first.binary_signature)
    assert Vector.dimensions(first.vector) == dimensions
    assert_in_delta Vector.cosine(first.vector, first.vector), 1.0, 1.0e-5
    assert Vector.cosine(first.vector, second.vector) < 0.75
    assert model != ""
  end

  test "semantic paraphrases score above unrelated memories" do
    automobile = Service.embed("A car needs fuel before the long journey", [])
    paraphrase = Service.embed("The automobile requires gasoline for the trip", [])
    unrelated = Service.embed("Quarterly invoices must be approved by finance", [])

    related_score = Vector.cosine(automobile.vector, paraphrase.vector)
    unrelated_score = Vector.cosine(automobile.vector, unrelated.vector)

    assert related_score > 0.80
    assert related_score > unrelated_score + 0.20
  end

  test "Vettore ranks a semantic match with little lexical overlap first" do
    scope = {:subject, "real-vector-rank"}

    {:ok, %{moment: target}} =
      SpectreMnemonic.signal("The automobile requires gasoline for the trip", scope: scope)

    {:ok, %{moment: lexical_distractor}} =
      SpectreMnemonic.signal("A fuel usage dashboard tracks vehicle efficiency", scope: scope)

    {:ok, %{moment: unrelated}} =
      SpectreMnemonic.signal("Quarterly invoices must be approved by finance", scope: scope)

    cue = Service.embed("A car needs fuel before the long journey", [])

    assert {:ok, [first | rest]} = RecallIndex.query(cue, scope: scope, overfetch: 3)
    assert first.id == target.id
    assert Enum.any?(rest, &(&1.id == lexical_distractor.id))
    assert Enum.any?(rest, &(&1.id == unrelated.id))
    assert first.cosine > Enum.find(rest, &(&1.id == unrelated.id)).cosine
  end

  test "end-to-end recall surfaces the semantic target before distractors" do
    scope = {:subject, "real-recall"}

    {:ok, %{moment: target}} =
      SpectreMnemonic.signal(
        "Deployment cannot proceed without the secret access keys",
        scope: scope
      )

    {:ok, %{moment: distractor}} =
      SpectreMnemonic.signal("The garden flowers need water every morning", scope: scope)

    assert {:ok, packet} =
             SpectreMnemonic.recall(
               "The production release is blocked because credentials are missing",
               scope: scope,
               limit: 5,
               plasticity?: false
             )

    ids = Enum.map(packet.moments, & &1.id)
    assert target.id in ids
    assert Enum.find_index(ids, &(&1 == target.id)) < Enum.find_index(ids, &(&1 == distractor.id))
  end

  test "local semantic retrieval gets the expected top result across distinct intents" do
    scope = {:subject, "real-retrieval-matrix"}

    corpus = [
      {"travel", "The automobile requires gasoline before a long journey"},
      {"finance", "Quarterly supplier invoices need approval from finance"},
      {"deploy", "Production deployment is blocked until credentials are restored"},
      {"garden", "The garden flowers should be watered every morning"},
      {"astronomy", "A telescope captures images of distant galaxies at night"}
    ]

    ids =
      Map.new(corpus, fn {label, text} ->
        {:ok, %{moment: moment}} = SpectreMnemonic.signal(text, scope: scope)
        {label, moment.id}
      end)

    queries = [
      {"travel", "A car needs fuel for the trip"},
      {"finance", "Who must authorize vendor bills this quarter?"},
      {"deploy", "The release cannot proceed because access keys are missing"},
      {"garden", "When do the plants need irrigation?"},
      {"astronomy", "How can we photograph faraway space objects?"}
    ]

    Enum.each(queries, fn {expected, query} ->
      cue = Service.embed(query, [])
      assert {:ok, [first | _rest]} = RecallIndex.query(cue, scope: scope, overfetch: 5)
      assert first.id == Map.fetch!(ids, expected)
    end)
  end

  test "a measured similarity floor excludes a real unrelated embedding" do
    scope = {:subject, "real-similarity-floor"}

    {:ok, %{moment: target}} =
      SpectreMnemonic.signal("The automobile requires gasoline for the trip", scope: scope)

    {:ok, %{moment: unrelated}} =
      SpectreMnemonic.signal("Quarterly invoices must be approved by finance", scope: scope)

    cue = Service.embed("A car needs fuel before travelling", [])
    target_similarity = Vector.cosine(cue.vector, target.vector)
    unrelated_similarity = Vector.cosine(cue.vector, unrelated.vector)
    threshold = (target_similarity + unrelated_similarity) / 2

    assert target_similarity > unrelated_similarity

    assert {:ok, results} =
             RecallIndex.query(cue,
               scope: scope,
               overfetch: 10,
               min_vector_similarity: threshold
             )

    assert Enum.any?(results, &(&1.id == target.id))
    refute Enum.any?(results, &(&1.id == unrelated.id))
  end

  test "semantic retrieval never crosses the requested partition" do
    allowed_scope = {:subject, "real-allowed"}
    other_scope = {:subject, "real-other"}

    {:ok, %{moment: allowed}} =
      SpectreMnemonic.signal("The automobile requires gasoline", scope: allowed_scope)

    {:ok, %{moment: outside}} =
      SpectreMnemonic.signal("The automobile requires gasoline", scope: other_scope)

    cue = Service.embed("A car needs fuel", [])

    assert {:ok, results} = RecallIndex.query(cue, scope: allowed_scope, overfetch: 10)
    assert Enum.any?(results, &(&1.id == allowed.id))
    refute Enum.any?(results, &(&1.id == outside.id))
  end

  test "hybrid quantized and exact strategies agree on the best real match" do
    scope = {:subject, "real-strategies"}

    {:ok, %{moment: target}} =
      SpectreMnemonic.signal("The automobile requires gasoline for the trip", scope: scope)

    {:ok, _memory} =
      SpectreMnemonic.signal("A telescope maps distant galaxies", scope: scope)

    {:ok, _memory} =
      SpectreMnemonic.signal("Finance approved the quarterly invoices", scope: scope)

    cue = Service.embed("A car needs fuel before travelling", [])

    winners =
      Enum.map([:hybrid, :quantized, :exact], fn strategy ->
        Application.put_env(:spectre_mnemonic, :embedding,
          index: [backend: :vettore, strategy: strategy]
        )

        assert {:ok, [first | _rest]} = RecallIndex.query(cue, scope: scope, overfetch: 3)
        first.id
      end)

    assert Enum.uniq(winners) == [target.id]
  end

  test "real semantic similarity creates an aggregation edge" do
    scope = {:subject, "real-semantic-edge"}

    {:ok, %{moment: existing}} =
      SpectreMnemonic.signal("The automobile requires gasoline before travelling", scope: scope)

    assert {:ok, packet} =
             SpectreMnemonic.remember("A car needs fuel ahead of a long journey",
               scope: scope,
               extract_entities?: false
             )

    assert Enum.any?(packet.associations, fn association ->
             association.relation == :related_memory and association.target_id == existing.id and
               association.metadata.similarity > 0.75
           end)
  end

  test "durable rebuild preserves real vectors for semantic search" do
    scope = {:subject, "real-durable"}

    {:ok, %{moment: target}} =
      SpectreMnemonic.signal("The automobile requires gasoline for the trip",
        scope: scope,
        persist?: true
      )

    SpectreMnemonic.MemoryCase.clear_memory()
    assert :ok = DurableIndex.rebuild(scope: scope)

    assert {:ok, results} =
             SpectreMnemonic.search("A car needs fuel before travelling", scope: scope)

    assert Enum.any?(results, &(&1.id == target.id and &1.score > 0.0))
  end
end
