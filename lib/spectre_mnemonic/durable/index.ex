defmodule SpectreMnemonic.Durable.Index do
  @moduledoc """
  Rebuildable local hybrid index for durable memory records.

  The append-only persistent store remains the source of truth. This process
  keeps derived BM25/vector state for fast local durable search.
  """

  use GenServer

  require Logger

  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.SearchResult

  @indexed_families [
    :moments,
    :knowledge,
    :summaries,
    :categories,
    :embeddings,
    :observations,
    :mental_models
  ]
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
  @spec search(term(), keyword()) :: {:ok, [SearchResult.t()]}
  def search(cue, opts \\ []), do: call_if_running({:search, cue, opts}, {:ok, []})

  @doc "Rebuilds the index from persistent replay."
  @spec rebuild(keyword()) :: :ok | {:error, term()}
  def rebuild(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        case GenServer.call(__MODULE__, :begin_rebuild) do
          {:ok, ref} ->
            replay = replay_for_rebuild(opts)
            GenServer.call(__MODULE__, {:finish_rebuild, ref, replay})

          {:error, _reason} = error ->
            error
        end
    end
  catch
    :exit, reason -> {:error, {:durable_index_rebuild_failed, reason}}
  end

  @doc "Clears all derived index state."
  @spec reset :: :ok
  def reset, do: call_if_running(:reset)

  @impl GenServer
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    send(self(), :rebuild)
    {:ok, empty_state()}
  end

  @impl GenServer
  def handle_info(:rebuild, state) do
    Task.start(fn ->
      case rebuild() do
        :ok -> :ok
        {:error, reason} -> Logger.warning("durable index rebuild failed: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:begin_rebuild, _from, %{rebuild: nil} = state) do
    ref = make_ref()
    {:reply, {:ok, ref}, %{state | rebuild: %{ref: ref, pending: []}}}
  end

  def handle_call(:begin_rebuild, _from, state) do
    {:reply, {:error, :rebuild_in_progress}, state}
  end

  def handle_call({:finish_rebuild, ref, {:ok, records}}, _from, state) do
    case state.rebuild do
      %{ref: ^ref, pending: pending} ->
        state =
          records
          |> merge_rebuild_records(Enum.reverse(pending))
          |> index_records()
          |> persist_snapshot()

        {:reply, :ok, state}

      _stale ->
        {:reply, {:error, :stale_rebuild}, state}
    end
  end

  def handle_call({:finish_rebuild, ref, {:error, reason}}, _from, state) do
    case state.rebuild do
      %{ref: ^ref} -> {:reply, {:error, reason}, %{state | rebuild: nil}}
      _stale -> {:reply, {:error, :stale_rebuild}, state}
    end
  end

  def handle_call({:upsert, record}, _from, state) do
    state = state |> upsert_record(record) |> track_rebuild_record(record)
    {:reply, :ok, state}
  end

  def handle_call({:search, cue, opts}, _from, state) do
    state = ensure_stats(state)
    {:reply, {:ok, search_state(state, cue, opts)}, state}
  end

  def handle_call(:reset, _from, _state) do
    state = empty_state()
    File.rm(snapshot_path([]))
    {:reply, :ok, state}
  end

  @spec index_records([Record.t()]) :: map()
  defp index_records(records) do
    records
    |> Enum.reduce(empty_state(), &absorb_record/2)
    |> recompute_stats()
  end

  @spec empty_state :: map()
  defp empty_state do
    %{
      docs: %{},
      states: %{},
      doc_freq: %{},
      avg_len: 0.0,
      total_docs: 0,
      dirty?: false,
      rebuild: nil
    }
  end

  @spec replay_for_rebuild(keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  defp replay_for_rebuild(opts) do
    Manager.replay_all(opts)
  catch
    :exit, reason -> {:error, {:persistent_memory_replay_exit, reason}}
  end

  @spec merge_rebuild_records([Record.t()], [Record.t()]) :: [Record.t()]
  defp merge_rebuild_records(replayed, pending) do
    (replayed ++ pending)
    |> Map.new(fn record -> {{record.dedupe_key || record.id, record.family}, record} end)
    |> Map.values()
  end

  @spec upsert_record(map(), Record.t()) :: map()
  defp upsert_record(state, record) do
    updated = absorb_record(record, state)
    if updated == state, do: state, else: %{updated | dirty?: true}
  end

  @spec track_rebuild_record(map(), Record.t()) :: map()
  defp track_rebuild_record(%{rebuild: %{pending: pending} = rebuild} = state, record) do
    %{state | rebuild: %{rebuild | pending: [record | pending]}}
  end

  defp track_rebuild_record(state, _record), do: state

  @spec ensure_stats(map()) :: map()
  defp ensure_stats(%{dirty?: true} = state), do: recompute_stats(state)
  defp ensure_stats(state), do: state

  @spec absorb_record(Record.t(), map()) :: map()
  defp absorb_record(%Record{family: :memory_states, payload: payload} = record, state)
       when is_map(payload) do
    memory_id = payload_value(payload, :memory_id)

    if is_binary(memory_id) do
      state_key = {record.namespace, record.scope, memory_id}

      Map.update!(state, :states, fn states ->
        Map.update(states, state_key, [payload], &[payload | &1])
      end)
    else
      state
    end
  end

  defp absorb_record(%Record{family: :tombstones, payload: payload} = record, state)
       when is_map(payload) do
    payload
    |> payload_value(:id)
    |> absorb_tombstone(record, payload, state)
  end

  defp absorb_record(%Record{family: family} = record, state) when family in @indexed_families do
    case doc_from_record(record) do
      nil -> state
      doc -> put_in(state, [:docs, doc.key], doc)
    end
  end

  defp absorb_record(_record, state), do: state

  @spec absorb_tombstone(term(), Record.t(), map(), map()) :: map()
  defp absorb_tombstone(memory_id, record, payload, state) when is_binary(memory_id) do
    doc_key = {record.namespace, record.scope, payload_family(payload), memory_id}

    Map.update!(state, :docs, &Map.delete(&1, doc_key))
  end

  defp absorb_tombstone(_memory_id, _record, _payload, state), do: state

  @spec doc_from_record(Record.t()) :: doc() | nil
  defp doc_from_record(%Record{} = record) do
    # Not every durable record deserves search surface. Empty envelopes can stay
    # in the log and enjoy their quiet retirement.
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
        state_key = {record.namespace, record.scope, payload_lifecycle_id(record, memory_id)}

        %{
          key: {record.namespace, record.scope, record.family, memory_id},
          id: record.id,
          memory_id: memory_id,
          state_key: state_key,
          namespace: record.namespace,
          scope: record.scope,
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

    %{
      state
      | docs: docs,
        doc_freq: doc_freq,
        avg_len: avg_len,
        total_docs: total_docs,
        dirty?: false
    }
  end

  @spec apply_hidden_states(map(), map()) :: map()
  defp apply_hidden_states(docs, states) do
    Enum.reject(docs, fn {_key, doc} ->
      latest_state(doc.state_key, states) in @hidden_states
    end)
    |> Map.new()
  end

  @spec search_state(map(), term(), keyword()) :: [SearchResult.t()]
  defp search_state(%{docs: docs, total_docs: total_docs} = state, cue, opts) do
    limit = Keyword.get(opts, :limit, 10)
    query = cue_text(cue)
    query_terms = terms(query)
    query_entities = entities(query)
    embedding = query_embedding(cue, opts)

    docs
    |> Map.values()
    |> Enum.filter(&visible?(&1.record, opts))
    |> Enum.map(fn doc ->
      score_doc(doc, query, query_terms, query_entities, embedding, state)
    end)
    |> Enum.filter(&(&1.score > 0 and total_docs > 0))
    |> Enum.sort_by(fn result ->
      {-result.score, -result_timestamp(result), result.id}
    end)
    |> Enum.take(limit)
  end

  @spec query_embedding(term(), keyword()) :: map()
  defp query_embedding(%QueryContext{embedding: embedding}, _opts), do: embedding || %{}
  defp query_embedding(cue, opts), do: Service.embed(cue, opts)

  @spec result_timestamp(SearchResult.t()) :: integer()
  defp result_timestamp(%SearchResult{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp result_timestamp(_result), do: 0

  @spec visible?(Record.t(), keyword()) :: boolean()
  defp visible?(%Record{} = record, opts),
    do: Scope.match?(record, opts) and Temporal.match?(record.payload, opts)

  @spec score_doc(doc(), binary(), [binary()], [binary()], map(), map()) :: SearchResult.t()
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
      state: latest_state(doc.state_key, state.states),
      record: doc.record.payload,
      text: doc.text,
      provenance: doc.provenance,
      inserted_at: doc.inserted_at,
      scores: %{bm25: bm25, vector: vector, lifecycle: lifecycle},
      metadata: %{namespace: doc.namespace, scope: doc.scope}
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

  @spec lifecycle_score(term(), map()) :: float()
  defp lifecycle_score(state_key, states) do
    case latest_state(state_key, states) do
      :pinned -> 5.0
      :promoted -> 2.0
      :stale -> -2.0
      :short_term -> 0.5
      :candidate -> 0.0
      _state -> 0.0
    end
  end

  @spec latest_state(term(), map()) :: atom() | nil
  defp latest_state(state_key, states) do
    states
    |> Map.get(state_key, [])
    |> Enum.max_by(&DateTime.to_unix(&1.inserted_at, :microsecond), fn -> nil end)
    |> case do
      nil -> nil
      %{state: state} -> state
    end
  end

  @spec payload_text(term()) :: binary()
  defp payload_text(payload) when is_map(payload) do
    text = payload_value(payload, :text)
    summary = payload_value(payload, :summary)
    statement = payload_value(payload, :statement)
    query = payload_value(payload, :query)
    answer = payload_value(payload, :answer)
    name = payload_value(payload, :name)

    cond do
      is_binary(text) -> text
      is_binary(summary) -> summary
      is_binary(statement) -> statement
      is_binary(query) and is_binary(answer) -> query <> "\n" <> answer
      is_binary(name) -> name
      true -> payload |> inspect(limit: 20) |> to_string()
    end
  end

  defp payload_text(_payload), do: ""

  @spec payload_memory_id(Record.t()) :: binary() | nil
  defp payload_memory_id(%Record{
         payload: payload,
         source_event_id: source_event_id,
         id: record_id
       })
       when is_map(payload) do
    case payload_value(payload, :id) || payload_value(payload, :source_id) || source_event_id ||
           record_id do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp payload_memory_id(%Record{source_event_id: id}) when is_binary(id), do: id
  defp payload_memory_id(%Record{id: id}) when is_binary(id), do: id
  defp payload_memory_id(_record), do: nil

  @spec payload_lifecycle_id(Record.t(), binary()) :: binary()
  defp payload_lifecycle_id(%Record{family: family, payload: payload}, memory_id)
       when family in [:knowledge, :embeddings] and is_map(payload) do
    case payload_value(payload, :source_id) do
      source_id when is_binary(source_id) -> source_id
      _missing -> memory_id
    end
  end

  defp payload_lifecycle_id(_record, memory_id), do: memory_id

  @spec payload_vector(term()) :: binary() | nil
  defp payload_vector(payload) when is_map(payload) do
    case payload_value(payload, :vector) do
      vector when is_binary(vector) -> vector
      _other -> nil
    end
  end

  defp payload_vector(_payload), do: nil

  @spec payload_signature(term()) :: binary() | nil
  defp payload_signature(payload) when is_map(payload) do
    case payload_value(payload, :binary_signature) do
      signature when is_binary(signature) -> signature
      _other -> nil
    end
  end

  defp payload_signature(_payload), do: nil

  @spec payload_provenance(term()) :: map()
  defp payload_provenance(payload) when is_map(payload) do
    with metadata when is_map(metadata) <- payload_value(payload, :metadata),
         provenance when is_map(provenance) <- payload_value(metadata, :provenance) do
      provenance
    else
      _missing -> %{}
    end
  end

  defp payload_provenance(_payload), do: %{}

  @spec payload_family(map()) :: atom() | nil
  defp payload_family(payload) do
    case payload_value(payload, :family) do
      family when is_atom(family) -> family
      family when is_binary(family) -> family |> Family.from_string() |> elem_or_nil()
      _other -> nil
    end
  end

  @spec elem_or_nil({:ok, term()} | :error) :: term() | nil
  defp elem_or_nil({:ok, value}), do: value
  defp elem_or_nil(:error), do: nil

  @spec payload_value(map(), atom()) :: term()
  defp payload_value(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end

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
  defp cue_text(%QueryContext{text: text}), do: String.downcase(text)
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
