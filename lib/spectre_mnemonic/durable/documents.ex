defmodule SpectreMnemonic.Durable.Documents do
  @moduledoc false

  alias SpectreMnemonic.Durable.Postings
  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Recall.Lexical

  @indexed_families [
    :moments,
    :knowledge,
    :summaries,
    :categories,
    :embeddings,
    :observations,
    :mental_models
  ]
  @candidate_limit 1_000

  @type doc :: map()
  @type tables :: %{
          documents: :ets.tid(),
          lifecycle: :ets.tid(),
          doc_freq: :ets.tid(),
          postings: :ets.tid(),
          entity_postings: :ets.tid(),
          recent: :ets.tid(),
          partition_counts: :ets.tid(),
          metadata: :ets.tid()
        }

  @spec empty_state() :: map()
  def empty_state do
    tables = %{
      documents: table(:durable_documents, :set),
      lifecycle: table(:durable_lifecycle, :bag),
      doc_freq: table(:durable_doc_freq, :set),
      postings: table(:durable_postings, :bag),
      entity_postings: table(:durable_entity_postings, :bag),
      recent: table(:durable_recent, :set),
      partition_counts: table(:durable_partition_counts, :set),
      metadata: table(:durable_generation_metadata, :set)
    }

    %{
      tables: tables,
      total_len: 0,
      avg_len: 0.0,
      total_docs: 0,
      dirty?: false,
      revision: 0,
      stats_revision: 0,
      last_rebuild_at: nil,
      rebuild: nil
    }
    |> sync_metadata()
  end

  @spec reset(map()) :: map()
  def reset(%{tables: tables} = state) do
    Enum.each(tables, fn {_name, table} -> :ets.delete_all_objects(table) end)

    %{
      state
      | total_len: 0,
        avg_len: 0.0,
        total_docs: 0,
        dirty?: false,
        stats_revision: state.revision,
        rebuild: nil,
        last_rebuild_at: nil
    }
    |> sync_metadata()
  end

  @spec destroy(map()) :: :ok
  def destroy(%{tables: tables}) do
    Enum.each(tables, fn {_name, table} ->
      if :ets.info(table) != :undefined, do: :ets.delete(table)
    end)

    :ok
  end

  @spec index_records(map(), Enumerable.t()) :: map()
  def index_records(state, records), do: Enum.reduce(records, state, &absorb/2)

  @spec upsert(map(), Record.t()) :: map()
  def upsert(state, record) do
    case do_absorb(record, state) do
      {updated, true} ->
        revision = state.revision + 1

        %{updated | dirty?: true, revision: revision, stats_revision: revision}
        |> sync_metadata()

      {updated, false} ->
        updated
    end
  end

  @spec absorb(Record.t(), map()) :: map()
  def absorb(record, state), do: record |> do_absorb(state) |> elem(0)

  @spec fetch(map(), [term()]) :: %{optional(term()) => doc()}
  def fetch(%{tables: %{documents: documents}}, keys) do
    Enum.reduce(keys, %{}, fn key, docs ->
      case :ets.lookup(documents, key) do
        [{^key, doc}] -> Map.put(docs, key, doc)
        [] -> docs
      end
    end)
  end

  @spec fetch_lifecycle(map(), [term()]) :: %{optional(term()) => [map()]}
  def fetch_lifecycle(%{tables: %{lifecycle: lifecycle}}, keys) do
    keys
    |> Enum.uniq()
    |> Map.new(fn key ->
      values = Enum.map(:ets.lookup(lifecycle, key), fn {^key, value} -> value end)
      {key, values}
    end)
  end

  @spec count_namespace(map(), binary() | :all) :: non_neg_integer()
  def count_namespace(%{total_docs: total_docs}, :all), do: total_docs

  def count_namespace(%{tables: %{documents: documents}}, namespace) when is_binary(namespace) do
    :ets.select_count(documents, [
      {{{namespace, :_, :_, :_}, :_}, [], [true]}
    ])
  end

  @spec from_record(Record.t()) :: doc() | nil
  def from_record(%Record{} = record) do
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

  @spec terms(binary()) :: [binary()]
  def terms(text), do: Lexical.keywords(text, 2)

  @spec entities(binary()) :: [binary()]
  def entities(text), do: Lexical.entities(text)

  @spec sync_metadata(map()) :: map()
  def sync_metadata(%{tables: %{metadata: metadata}} = state) do
    :ets.insert(metadata, [
      {:revision, state.revision},
      {:stats_revision, state.stats_revision},
      {:total_docs, state.total_docs},
      {:total_len, state.total_len},
      {:avg_len, state.avg_len},
      {:last_rebuild_at, state.last_rebuild_at}
    ])

    state
  end

  defp do_absorb(%Record{family: :memory_states, payload: payload} = record, state)
       when is_map(payload) do
    memory_id = payload_value(payload, :memory_id)

    if is_binary(memory_id) do
      state_key = {record.namespace, record.scope, memory_id}
      :ets.insert(state.tables.lifecycle, {state_key, payload})
      {state, true}
    else
      {state, false}
    end
  end

  defp do_absorb(%Record{family: :tombstones, payload: payload} = record, state)
       when is_map(payload) do
    payload
    |> payload_value(:id)
    |> absorb_tombstone(record, payload, state)
  end

  defp do_absorb(%Record{family: family} = record, state) when family in @indexed_families do
    case from_record(record) do
      nil -> {state, false}
      doc -> put(state, doc)
    end
  end

  defp do_absorb(_record, state), do: {state, false}

  defp absorb_tombstone(memory_id, record, payload, state) when is_binary(memory_id) do
    doc_key = {record.namespace, record.scope, payload_family(payload), memory_id}
    state_key = {record.namespace, record.scope, memory_id}
    lifecycle? = :ets.member(state.tables.lifecycle, state_key)
    {state, document?} = remove(state, doc_key)
    :ets.delete(state.tables.lifecycle, state_key)
    {state, document? or lifecycle?}
  end

  defp absorb_tombstone(_memory_id, _record, _payload, state), do: {state, false}

  defp put(state, doc) do
    current = lookup_document(state.tables.documents, doc.key)

    if current == doc do
      {state, false}
    else
      {state, _removed?} = remove(state, doc.key)
      partition = {doc.namespace, doc.scope}
      total_docs = state.total_docs + 1
      total_len = state.total_len + doc.len

      :ets.insert(state.tables.documents, {doc.key, doc})
      Postings.update_doc_freq(state.tables.doc_freq, doc.terms, 1)
      Postings.update(state.tables.postings, partition, doc.terms, doc.key, :add)
      Postings.update(state.tables.entity_postings, partition, doc.entities, doc.key, :add)
      Postings.put_recent(state.tables.recent, partition, doc.key, @candidate_limit)
      Postings.increment_count(state.tables.partition_counts, partition)

      {%{
         state
         | total_docs: total_docs,
           total_len: total_len,
           avg_len: total_len / total_docs
       }, true}
    end
  end

  defp remove(state, key) do
    case lookup_document(state.tables.documents, key) do
      nil ->
        {state, false}

      doc ->
        partition = {doc.namespace, doc.scope}
        total_docs = max(state.total_docs - 1, 0)
        total_len = max(state.total_len - doc.len, 0)

        :ets.delete(state.tables.documents, key)
        Postings.update_doc_freq(state.tables.doc_freq, doc.terms, -1)
        Postings.update(state.tables.postings, partition, doc.terms, key, :delete)
        Postings.update(state.tables.entity_postings, partition, doc.entities, key, :delete)
        Postings.delete_recent(state.tables.recent, partition, key)
        Postings.decrement_count(state.tables.partition_counts, partition)

        {%{
           state
           | total_docs: total_docs,
             total_len: total_len,
             avg_len: if(total_docs == 0, do: 0.0, else: total_len / total_docs)
         }, true}
    end
  end

  defp lookup_document(table, key) do
    case :ets.lookup(table, key) do
      [{^key, doc}] -> doc
      [] -> nil
    end
  end

  defp table(name, type) do
    :ets.new(name, [
      type,
      :protected,
      :compressed,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

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
      true -> ""
    end
  end

  defp payload_text(_payload), do: ""

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

  defp payload_lifecycle_id(%Record{family: family, payload: payload}, memory_id)
       when family in [:knowledge, :embeddings] and is_map(payload) do
    case payload_value(payload, :source_id) do
      source_id when is_binary(source_id) -> source_id
      _missing -> memory_id
    end
  end

  defp payload_lifecycle_id(_record, memory_id), do: memory_id

  defp payload_vector(payload) when is_map(payload) do
    case payload_value(payload, :vector) do
      vector when is_binary(vector) -> vector
      _other -> nil
    end
  end

  defp payload_vector(_payload), do: nil

  defp payload_signature(payload) when is_map(payload) do
    case payload_value(payload, :binary_signature) do
      signature when is_binary(signature) -> signature
      _other -> nil
    end
  end

  defp payload_signature(_payload), do: nil

  defp payload_provenance(payload) when is_map(payload) do
    with metadata when is_map(metadata) <- payload_value(payload, :metadata),
         provenance when is_map(provenance) <- payload_value(metadata, :provenance) do
      provenance
    else
      _missing -> %{}
    end
  end

  defp payload_provenance(_payload), do: %{}

  defp payload_family(payload) do
    case payload_value(payload, :family) do
      family when is_atom(family) -> family
      family when is_binary(family) -> family |> Family.from_string() |> elem_or_nil()
      _other -> nil
    end
  end

  defp elem_or_nil({:ok, value}), do: value
  defp elem_or_nil(:error), do: nil

  defp payload_value(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end
end
