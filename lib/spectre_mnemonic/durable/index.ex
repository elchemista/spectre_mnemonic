defmodule SpectreMnemonic.Durable.Index do
  @moduledoc """
  Rebuildable local hybrid index for durable memory records.

  The append-only persistent store remains the source of truth. This process
  keeps derived BM25/vector state for fast local durable search.
  """

  use GenServer

  alias SpectreMnemonic.Embedding.{Service, Vector}
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile
  alias SpectreMnemonic.Persistence.Store.Record

  @indexed_families [:moments, :knowledge, :summaries, :categories, :embeddings]
  @hidden_states [:forgotten, :contradicted]
  @k1 1.4
  @b 0.75

  @type doc :: map()

  @doc "Starts the durable search index."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Adds or replaces one durable record in the derived index."
  @spec upsert(Record.t()) :: :ok
  def upsert(%Record{} = record), do: call_if_running({:upsert, record})
  def upsert(_record), do: :ok

  @doc "Searches durable memory with local hybrid scoring."
  @spec search(term(), keyword()) :: {:ok, [map()]}
  def search(cue, opts \\ []), do: call_if_running({:search, cue, opts}, {:ok, []})

  @doc "Rebuilds the index from persistent replay."
  @spec rebuild(keyword()) :: :ok
  def rebuild(opts \\ []), do: call_if_running({:rebuild, opts})

  @doc "Clears all derived index state."
  @spec reset :: :ok
  def reset, do: call_if_running(:reset)

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    send(self(), :rebuild)
    {:ok, empty_state()}
  end

  @impl true
  def handle_info(:rebuild, state) do
    {:noreply, rebuild_state(state, [])}
  end

  @impl true
  def handle_call({:rebuild, opts}, _from, state) do
    {:reply, :ok, rebuild_state(state, opts)}
  end

  def handle_call({:upsert, record}, _from, state) do
    {:reply, :ok, absorb_record(record, state)}
  end

  def handle_call({:search, cue, opts}, _from, state) do
    state = recompute_stats(state)
    {:reply, {:ok, search_state(state, cue, opts)}, state}
  end

  def handle_call(:reset, _from, _state) do
    state = empty_state()
    File.rm(snapshot_path([]))
    {:reply, :ok, state}
  end

  @spec rebuild_state(map(), keyword()) :: map()
  defp rebuild_state(_state, opts) do
    {:ok, records} = Manager.replay(opts)

    records
    |> Enum.reduce(empty_state(), &absorb_record/2)
    |> recompute_stats()
    |> persist_snapshot()
  end

  @spec empty_state :: map()
  defp empty_state do
    %{docs: %{}, states: %{}, doc_freq: %{}, avg_len: 0.0, total_docs: 0}
  end

  @spec absorb_record(Record.t(), map()) :: map()
  defp absorb_record(%Record{family: :memory_states, payload: payload}, state)
       when is_map(payload) do
    memory_id = Map.get(payload, :memory_id)

    if is_binary(memory_id) do
      Map.update!(state, :states, fn states ->
        Map.update(states, memory_id, [payload], &[payload | &1])
      end)
    else
      state
    end
  end

  defp absorb_record(%Record{family: :tombstones, payload: payload}, state)
       when is_map(payload) do
    payload
    |> Map.get(:id)
    |> absorb_tombstone(payload, state)
  end

  defp absorb_record(%Record{family: family} = record, state) when family in @indexed_families do
    case doc_from_record(record) do
      nil -> state
      doc -> put_in(state, [:docs, doc.key], doc)
    end
  end

  defp absorb_record(_record, state), do: state

  @spec absorb_tombstone(term(), map(), map()) :: map()
  defp absorb_tombstone(memory_id, payload, state) when is_binary(memory_id) do
    state
    |> Map.update!(:states, &put_tombstone_state(&1, memory_id, payload))
    |> Map.update!(:docs, &remove_docs_for_memory(&1, memory_id))
  end

  defp absorb_tombstone(_memory_id, _payload, state), do: state

  @spec put_tombstone_state(map(), binary(), map()) :: map()
  defp put_tombstone_state(states, memory_id, payload) do
    tombstone = %{
      id: "mstate_tombstone_#{memory_id}",
      memory_id: memory_id,
      state: :forgotten,
      reason: :tombstone,
      metadata: %{},
      inserted_at: Map.get(payload, :forgotten_at, DateTime.utc_now())
    }

    Map.update(states, memory_id, [tombstone], &[tombstone | &1])
  end

  @spec remove_docs_for_memory(map(), binary()) :: map()
  defp remove_docs_for_memory(docs, memory_id) do
    docs
    |> Enum.reject(fn {_key, doc} -> doc.memory_id == memory_id end)
    |> Map.new()
  end

  @spec doc_from_record(Record.t()) :: doc() | nil
  defp doc_from_record(%Record{} = record) do
    text = payload_text(record.payload)
    memory_id = payload_memory_id(record)
    vector = payload_vector(record.payload)
    signature = payload_signature(record.payload)

    cond do
      is_nil(memory_id) ->
        nil

      text == "" and not is_binary(vector) ->
        nil

      true ->
        terms = terms(text)

        %{
          key: "#{record.family}:#{memory_id}",
          id: record.id,
          memory_id: memory_id,
          family: record.family,
          record: record,
          text: text,
          terms: terms,
          term_freq: Enum.frequencies(terms),
          len: max(length(terms), 1),
          entities: entities(text),
          vector: vector,
          binary_signature: signature,
          inserted_at: record.inserted_at,
          provenance: payload_provenance(record.payload)
        }
    end
  end

  @spec recompute_stats(map()) :: map()
  defp recompute_stats(%{docs: docs} = state) do
    docs = docs |> apply_hidden_states(state.states)
    total_docs = map_size(docs)
    total_len = docs |> Map.values() |> Enum.map(& &1.len) |> Enum.sum()
    avg_len = if total_docs == 0, do: 0.0, else: total_len / total_docs

    doc_freq =
      docs
      |> Map.values()
      |> Enum.reduce(%{}, fn doc, acc ->
        doc.terms
        |> MapSet.new()
        |> Enum.reduce(acc, fn term, acc -> Map.update(acc, term, 1, &(&1 + 1)) end)
      end)

    %{state | docs: docs, doc_freq: doc_freq, avg_len: avg_len, total_docs: total_docs}
  end

  @spec apply_hidden_states(map(), map()) :: map()
  defp apply_hidden_states(docs, states) do
    Enum.reject(docs, fn {_key, doc} ->
      latest_state(doc.memory_id, states) in @hidden_states
    end)
    |> Map.new()
  end

  @spec search_state(map(), term(), keyword()) :: [map()]
  defp search_state(%{docs: docs, total_docs: total_docs} = state, cue, opts) do
    limit = Keyword.get(opts, :limit, 10)
    query = cue_text(cue)
    query_terms = terms(query)
    query_entities = entities(query)
    embedding = Service.embed(cue, opts)

    docs
    |> Map.values()
    |> Enum.map(fn doc ->
      score_doc(doc, query, query_terms, query_entities, embedding, state)
    end)
    |> Enum.filter(&(&1.score > 0 and total_docs > 0))
    |> Enum.sort_by(fn result ->
      {-result.score, -DateTime.to_unix(result.inserted_at, :microsecond), result.id}
    end)
    |> Enum.take(limit)
    |> Enum.map(&Map.drop(&1, [:inserted_at]))
  end

  @spec score_doc(doc(), binary(), [binary()], [binary()], map(), map()) :: map()
  defp score_doc(doc, query, query_terms, query_entities, embedding, state) do
    bm25 = bm25_score(doc, query_terms, state)

    phrase =
      if query != "" and String.contains?(String.downcase(doc.text), query), do: 4.0, else: 0.0

    exact = exact_score(doc, query_terms)
    entity = entity_score(doc.entities, query_entities)
    vector = vector_score(doc, embedding)
    lifecycle = lifecycle_score(doc.memory_id, state.states)
    score = bm25 + phrase + exact + entity + vector + lifecycle

    %{
      source: :persistent,
      family: doc.family,
      id: doc.memory_id,
      record_id: doc.id,
      score: score,
      bm25_score: bm25,
      vector_score: vector,
      lifecycle_score: lifecycle,
      state: latest_state(doc.memory_id, state.states),
      text: doc.text,
      record: doc.record.payload,
      provenance: doc.provenance,
      inserted_at: doc.inserted_at
    }
  end

  @spec bm25_score(doc(), [binary()], map()) :: float()
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

  @spec exact_score(doc(), [binary()]) :: float()
  defp exact_score(doc, query_terms) do
    overlap = MapSet.size(MapSet.intersection(MapSet.new(doc.terms), MapSet.new(query_terms)))
    overlap * 1.5
  end

  @spec entity_score([binary()], [binary()]) :: float()
  defp entity_score(left, right) do
    MapSet.size(MapSet.intersection(MapSet.new(left), MapSet.new(right))) * 2.0
  end

  @spec vector_score(doc(), map()) :: float()
  defp vector_score(%{vector: left, binary_signature: signature}, %{vector: right} = embedding)
       when is_binary(left) and is_binary(right) do
    cosine = max(0.0, Vector.cosine(left, right))

    bits =
      get_in(embedding, [:metadata, :signature_bits]) || min(byte_size(signature || <<>>) * 8, 64)

    hamming = Vector.hamming_similarity(signature, Map.get(embedding, :binary_signature), bits)
    cosine * 4.0 + hamming * 4.0
  end

  defp vector_score(_doc, _embedding), do: 0.0

  @spec lifecycle_score(binary(), map()) :: float()
  defp lifecycle_score(memory_id, states) do
    case latest_state(memory_id, states) do
      :pinned -> 5.0
      :promoted -> 2.0
      :stale -> -2.0
      :short_term -> 0.5
      :candidate -> 0.0
      _state -> 0.0
    end
  end

  @spec latest_state(binary(), map()) :: atom() | nil
  defp latest_state(memory_id, states) do
    states
    |> Map.get(memory_id, [])
    |> Enum.max_by(&DateTime.to_unix(&1.inserted_at, :microsecond), fn -> nil end)
    |> case do
      nil -> nil
      %{state: state} -> state
    end
  end

  @spec payload_text(term()) :: binary()
  defp payload_text(%{text: text}) when is_binary(text), do: text
  defp payload_text(%{summary: summary}) when is_binary(summary), do: summary
  defp payload_text(%{name: name}) when is_binary(name), do: name

  defp payload_text(payload) when is_map(payload),
    do: payload |> inspect(limit: 20) |> to_string()

  defp payload_text(_payload), do: ""

  @spec payload_memory_id(Record.t()) :: binary() | nil
  defp payload_memory_id(%Record{payload: %{id: id}}) when is_binary(id), do: id
  defp payload_memory_id(%Record{payload: %{source_id: id}}) when is_binary(id), do: id
  defp payload_memory_id(%Record{source_event_id: id}) when is_binary(id), do: id
  defp payload_memory_id(%Record{id: id}) when is_binary(id), do: id
  defp payload_memory_id(_record), do: nil

  @spec payload_vector(term()) :: binary() | nil
  defp payload_vector(%{vector: vector}) when is_binary(vector), do: vector
  defp payload_vector(_payload), do: nil

  @spec payload_signature(term()) :: binary() | nil
  defp payload_signature(%{binary_signature: signature}) when is_binary(signature), do: signature
  defp payload_signature(_payload), do: nil

  @spec payload_provenance(term()) :: map()
  defp payload_provenance(%{metadata: %{provenance: provenance}}) when is_map(provenance),
    do: provenance

  defp payload_provenance(_payload), do: %{}

  @spec terms(binary()) :: [binary()]
  defp terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b\p{Lu}[\p{L}\p{N}_]+\b/u, text)
    |> List.flatten()
    |> Enum.uniq()
  end

  @spec cue_text(term()) :: binary()
  defp cue_text(cue) when is_binary(cue), do: String.downcase(cue)
  defp cue_text(cue), do: cue |> inspect() |> String.downcase()

  @spec persist_snapshot(map()) :: map()
  defp persist_snapshot(state) do
    path = snapshot_path([])
    File.mkdir_p!(Path.dirname(path))
    File.write(path, :erlang.term_to_binary(state, [:compressed]), [:binary])
    state
  rescue
    _exception -> state
  end

  @spec snapshot_path(keyword()) :: Path.t()
  defp snapshot_path(opts) do
    root =
      Keyword.get(opts, :data_root) ||
        Application.get_env(:spectre_mnemonic, :data_root, StoreFile.data_root())

    Path.join([root, "index", "durable.term"])
  end

  @spec call_if_running(term(), term()) :: term()
  defp call_if_running(message, default \\ :ok) do
    case Process.whereis(__MODULE__) do
      nil -> default
      _pid -> GenServer.call(__MODULE__, message)
    end
  catch
    :exit, _reason -> default
  end
end
