defmodule SpectreMnemonic.Durable.Query do
  @moduledoc false

  alias SpectreMnemonic.Durable.Documents
  alias SpectreMnemonic.Durable.Postings
  alias SpectreMnemonic.Durable.Stats
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.SearchResult
  alias SpectreMnemonic.Telemetry

  @k1 1.4
  @b 0.75

  @spec candidate_snapshot(map(), term(), keyword()) :: map()
  def candidate_snapshot(state, cue, opts) do
    namespace = Identity.namespace!(opts)
    partition = {namespace, Scope.from_opts(opts)}
    query_terms = Documents.terms(cue_text(cue))
    query_entities = Documents.entities(cue_text(cue))
    total = Postings.partition_count(state.tables, partition)
    limit = Postings.candidate_limit(opts)
    threshold = Postings.brute_force_threshold(opts)

    {keys, mode, sources} =
      if total <= threshold do
        {Postings.recent(state.tables, partition), :brute_force, %{partition: total}}
      else
        Postings.candidate_keys(state.tables, partition, query_terms, query_entities, limit)
      end

    docs = Documents.fetch(state, Enum.take(keys, limit))
    state_keys = docs |> Map.values() |> Enum.map(& &1.state_key)

    emit_candidate_event(mode, total, map_size(docs), sources, opts)

    %{
      docs: docs,
      states: Documents.fetch_lifecycle(state, state_keys),
      doc_freq: Postings.doc_frequencies(state.tables, query_terms),
      avg_len: state.avg_len,
      total_docs: state.total_docs,
      dirty?: false,
      revision: state.revision,
      rebuild: nil
    }
  end

  @spec search(map(), term(), keyword()) :: [SearchResult.t()]
  def search(%{docs: docs, total_docs: total_docs} = state, cue, opts) do
    limit = search_limit(opts)
    query = cue_text(cue)
    query_terms = Documents.terms(query)
    query_entities = Documents.entities(query)
    embedding = query_embedding(cue, opts)

    docs
    |> Map.values()
    |> Enum.filter(fn doc ->
      visible?(doc.record, opts) and not Stats.hidden?(doc.state_key, state.states)
    end)
    |> Enum.map(fn doc ->
      score_doc(doc, query, query_terms, query_entities, embedding, state)
    end)
    |> Enum.filter(&(&1.score > 0 and total_docs > 0))
    |> Enum.sort_by(fn result -> {-result.score, -result_timestamp(result), result.id} end)
    |> Enum.take(limit)
  end

  defp search_limit(opts) do
    case Keyword.get(opts, :limit, 10) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _invalid -> 10
    end
  end

  defp query_embedding(%QueryContext{embedding: embedding}, _opts), do: embedding || %{}
  defp query_embedding(cue, opts), do: Service.embed(cue, opts)

  defp result_timestamp(%SearchResult{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp result_timestamp(_result), do: 0

  defp visible?(%Record{} = record, opts),
    do: Scope.match?(record, opts) and Temporal.match?(record.payload, opts)

  defp score_doc(doc, query, query_terms, query_entities, embedding, state) do
    bm25 = bm25_score(doc, query_terms, state)

    phrase =
      if query != "" and String.contains?(String.downcase(doc.text), query), do: 4.0, else: 0.0

    exact = exact_score(doc, query_terms)
    entity = entity_score(doc.entities, query_entities)
    vector = vector_score(doc, embedding)
    lifecycle = lifecycle_score(doc.state_key, state.states)
    score = bm25 + phrase + exact + entity + vector + lifecycle

    %SearchResult{
      source: :persistent,
      namespace: doc.namespace,
      scope: doc.scope,
      family: doc.family,
      id: doc.memory_id,
      record_id: doc.id,
      score: score,
      state: Stats.latest_state(doc.state_key, state.states),
      record: doc.record.payload,
      text: doc.text,
      provenance: doc.provenance,
      inserted_at: doc.inserted_at,
      scores: %{bm25: bm25, vector: vector, lifecycle: lifecycle},
      metadata: %{namespace: doc.namespace, scope: doc.scope}
    }
  end

  defp bm25_score(_doc, [], _state), do: 0.0

  defp bm25_score(doc, query_terms, %{
         doc_freq: doc_freq,
         total_docs: total_docs,
         avg_len: avg_len
       }) do
    query_terms
    |> Enum.uniq()
    |> Enum.reduce(0.0, fn term, acc ->
      tf = Map.get(doc.term_freq, term, 0)
      df = Map.get(doc_freq, term, 0)

      if tf == 0 or df == 0 or total_docs == 0 do
        acc
      else
        idf = :math.log(1 + (total_docs - df + 0.5) / (df + 0.5))
        denom = tf + @k1 * (1 - @b + @b * (doc.len / max(avg_len, 1.0)))
        acc + idf * (tf * (@k1 + 1)) / denom
      end
    end)
  end

  defp exact_score(doc, query_terms) do
    MapSet.size(MapSet.intersection(MapSet.new(doc.terms), MapSet.new(query_terms))) * 1.5
  end

  defp entity_score(left, right) do
    MapSet.size(MapSet.intersection(MapSet.new(left), MapSet.new(right))) * 2.0
  end

  defp vector_score(%{vector: left, binary_signature: signature}, %{vector: right} = embedding)
       when is_binary(left) and is_binary(right) do
    cosine = max(0.0, Vector.cosine(left, right))

    bits =
      get_in(embedding, [:metadata, :signature_bits]) || min(byte_size(signature || <<>>) * 8, 64)

    hamming = Vector.hamming_similarity(signature, Map.get(embedding, :binary_signature), bits)
    cosine * 4.0 + hamming * 4.0
  end

  defp vector_score(_doc, _embedding), do: 0.0

  defp lifecycle_score(state_key, states) do
    case Stats.latest_state(state_key, states) do
      :pinned -> 5.0
      :promoted -> 2.0
      :stale -> -2.0
      :short_term -> 0.5
      :candidate -> 0.0
      _state -> 0.0
    end
  end

  defp cue_text(%QueryContext{text: text}), do: String.downcase(text)
  defp cue_text(cue) when is_binary(cue), do: String.downcase(cue)
  defp cue_text(cue), do: cue |> inspect() |> String.downcase()

  defp emit_candidate_event(mode, total, candidates, sources, opts) do
    event =
      if mode == :candidate_first,
        do: [:durable, :candidate_collection],
        else: [:durable, :full_scan_fallback]

    Telemetry.emit(
      event,
      %{total: total, candidates: candidates, sources: sources},
      %{engine_ref: Keyword.get(opts, :engine_ref)}
    )
  end
end
