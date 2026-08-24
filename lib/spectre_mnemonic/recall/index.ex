defmodule SpectreMnemonic.Recall.Index do
  @moduledoc """
  Active-memory embedding index.

  The index keeps a small ETS mirror of dense vectors and packed binary
  signatures. Vettore provides the partition-local dense ANN path. The ETS
  mirror remains the deterministic brute-force fallback and the source for
  binary Hamming reranking.
  """

  use GenServer

  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope

  @index_table :mnemonic_embedding_index

  @type state :: %{
          vettore: %{optional(tuple()) => map()}
        }

  @doc "Starts the index process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Indexes or replaces one moment."
  @spec upsert(SpectreMnemonic.Memory.Moment.t() | SpectreMnemonic.Memory.Secret.t()) :: :ok
  def upsert(moment) do
    call_if_running({:upsert, moment})
  end

  @doc "Removes one moment from the index."
  @spec delete(binary()) :: :ok
  def delete(moment_id) do
    call_if_running({:delete, moment_id})
  end

  @doc "Queries indexed active moments by cue embedding."
  @spec query(map(), keyword()) :: {:ok, [map()]}
  def query(cue, opts \\ []) do
    call_if_running({:query, cue, opts}, {:ok, []})
  end

  @doc "Clears ETS index state."
  @spec reset :: :ok
  def reset do
    call_if_running(:reset)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    ensure_table(@index_table)

    {:ok, %{vettore: %{}}}
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:upsert, moment}, _from, state) do
    # The active index is a helper, not the source of truth. ETS focus owns the
    # memory; this process just keeps vector shortcuts warm.
    case indexable(moment) do
      {:ok, entry} ->
        :ets.insert(@index_table, {moment.id, entry})
        state = maybe_upsert_vettore(state, moment.id, entry)

        {:reply, :ok, state}

      :skip ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete, moment_id}, _from, state) do
    state = maybe_delete_vettore(state, moment_id)
    :ets.delete(@index_table, moment_id)
    {:reply, :ok, state}
  end

  def handle_call({:query, cue, opts}, _from, state) do
    limit = query_limit(opts)

    results =
      (query_vettore_scoped(state, cue, limit, opts) || brute_force(cue, limit, opts))
      |> filter_similarity(opts)
      |> Enum.take(limit)

    {:reply, {:ok, results}, state}
  end

  def handle_call(:reset, _from, state) do
    close_vettore_collections(state)
    :ets.delete_all_objects(@index_table)

    {:reply, :ok, %{state | vettore: %{}}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_vettore_collections(state)
    :ok
  end

  @spec maybe_upsert_vettore(state(), binary(), map()) :: state()
  defp maybe_upsert_vettore(state, moment_id, entry) do
    if vettore_enabled?() and vettore_available?() do
      upsert_vettore(state, moment_id, entry)
    else
      state
    end
  rescue
    _exception -> state
  catch
    _kind, _reason -> state
  end

  @spec upsert_vettore(state(), binary(), map()) :: state()
  defp upsert_vettore(state, moment_id, entry) do
    partition = {entry.namespace, entry.scope}

    case ensure_vettore_collection(state, partition, entry.dimensions) do
      {:ok, state, indexed} ->
        replace_vettore_embedding(state, indexed, partition, moment_id, entry)

      {:error, _reason} ->
        state
    end
  end

  @spec ensure_vettore_collection(state(), tuple(), pos_integer()) ::
          {:ok, state(), map()} | {:error, term()}
  defp ensure_vettore_collection(state, partition, dimensions) do
    case Map.get(state.vettore, partition) do
      %{dimensions: ^dimensions} = indexed ->
        {:ok, state, indexed}

      %{dimensions: _other} ->
        {:error, :dimension_mismatch}

      nil ->
        new_vettore_collection(state, partition, dimensions)
    end
  end

  @spec new_vettore_collection(state(), tuple(), pos_integer()) ::
          {:ok, state(), map()} | {:error, term()}
  defp new_vettore_collection(state, partition, dimensions) do
    config = index_config()

    opts = [
      name: vettore_collection_name(partition),
      dimensions: dimensions,
      metric: :cosine,
      normalize: :l2,
      index: Map.get(config, :vettore_index, :hnsw),
      index_options: vettore_index_options(config)
    ]

    case Vettore.new(opts) do
      {:ok, collection} ->
        indexed = %{collection: collection, dimensions: dimensions, count: 0}
        state = put_in(state, [:vettore, partition], indexed)
        {:ok, state, indexed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec replace_vettore_embedding(state(), map(), tuple(), binary(), map()) :: state()
  defp replace_vettore_embedding(state, indexed, partition, moment_id, entry) do
    existing? = match?({:ok, _embedding}, Vettore.get(indexed.collection, moment_id))
    if existing?, do: Vettore.delete(indexed.collection, moment_id)

    embedding = %{
      id: moment_id,
      value: moment_id,
      vector: Vector.to_list(entry.vector),
      metadata: %{namespace: entry.namespace, scope: entry.scope}
    }

    case Vettore.put(indexed.collection, embedding) do
      :ok ->
        count = if existing?, do: indexed.count, else: indexed.count + 1
        put_in(state, [:vettore, partition], %{indexed | count: count})

      {:error, _reason} ->
        state
    end
  end

  @spec maybe_delete_vettore(state(), binary()) :: state()
  defp maybe_delete_vettore(state, moment_id) do
    case :ets.lookup(@index_table, moment_id) do
      [{^moment_id, entry}] -> delete_vettore_entry(state, moment_id, entry)
      _missing -> state
    end
  end

  @spec delete_vettore_entry(state(), binary(), map()) :: state()
  defp delete_vettore_entry(state, moment_id, entry) do
    partition = {entry.namespace, entry.scope}

    case Map.get(state.vettore, partition) do
      nil ->
        state

      indexed ->
        _result = Vettore.delete(indexed.collection, moment_id)
        put_in(state, [:vettore, partition], %{indexed | count: max(indexed.count - 1, 0)})
    end
  rescue
    _exception -> state
  end

  @spec query_vettore_scoped(state(), map(), non_neg_integer(), keyword()) :: [map()] | nil
  defp query_vettore_scoped(_state, %{vector: nil}, _limit, _opts), do: nil
  defp query_vettore_scoped(_state, _cue, limit, _opts) when limit <= 0, do: []

  defp query_vettore_scoped(state, cue, limit, opts) do
    partition = {Identity.namespace!(opts), Scope.from_opts(opts)}

    with true <- vettore_enabled?(),
         %{count: count} = indexed when count > 0 <- Map.get(state.vettore, partition),
         query when query != [] <- Vector.to_list(cue.vector),
         {:ok, results} <- search_vettore(indexed, query, min(limit, count)) do
      results
      |> Enum.flat_map(&vettore_result(&1, cue))
      |> Enum.sort_by(&entry_rank_key/1)
    else
      _fallback -> nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  @spec search_vettore(map(), [float()], pos_integer()) ::
          {:ok, [Vettore.Result.t()]} | {:error, term()}
  defp search_vettore(indexed, query, limit) do
    case Map.get(index_config(), :strategy, :hybrid) do
      :hybrid ->
        case Vettore.hybrid_search(indexed.collection, query, limit: limit, rerank: :exact) do
          {:ok, _results} = ok -> ok
          {:error, _reason} -> Vettore.search(indexed.collection, query, limit: limit)
        end

      :quantized ->
        Vettore.quantized_search(indexed.collection, query,
          candidates: max(limit * 4, limit),
          limit: limit
        )

      _exact_or_ann ->
        Vettore.search(indexed.collection, query, limit: limit)
    end
  end

  @spec vettore_result(Vettore.Result.t(), map()) :: [map()]
  defp vettore_result(%Vettore.Result{id: moment_id}, cue) do
    case :ets.lookup(@index_table, moment_id) do
      [{^moment_id, entry}] ->
        [score_entry(moment_id, entry, cue.vector, Map.get(cue, :binary_signature))]

      _missing ->
        []
    end
  end

  @spec close_vettore_collections(state()) :: :ok
  defp close_vettore_collections(state) do
    state.vettore
    |> Map.values()
    |> Enum.each(fn indexed -> Vettore.close(indexed.collection) end)

    :ok
  rescue
    _exception -> :ok
  end

  @spec vettore_enabled? :: boolean()
  defp vettore_enabled? do
    config = index_config()
    Map.get(config, :enabled, true) and Map.get(config, :backend, :vettore) == :vettore
  end

  @spec vettore_available? :: boolean()
  defp vettore_available?, do: Code.ensure_loaded?(Vettore)

  @spec vettore_collection_name(tuple()) :: binary()
  defp vettore_collection_name(partition) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(partition, [:deterministic]))
    "mnemonic_" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 24))
  end

  @spec vettore_index_options(map()) :: keyword()
  defp vettore_index_options(config) do
    case Map.get(config, :vettore_index_options, []) do
      opts when is_list(opts) -> opts
      _invalid -> []
    end
  end

  @spec brute_force(map(), non_neg_integer(), keyword()) :: [map()]
  defp brute_force(%{vector: nil}, _limit, _opts), do: []

  defp brute_force(cue, limit, opts) do
    # Small hot sets can survive without an approximate neighbor oracle.
    cue_vector = Map.get(cue, :vector)
    cue_signature = Map.get(cue, :binary_signature)

    :ets.foldl(
      fn {moment_id, entry}, ranked ->
        if Scope.match?(entry, opts) do
          moment_id
          |> score_entry(entry, cue_vector, cue_signature)
          |> insert_ranked_entry(ranked, limit)
        else
          ranked
        end
      end,
      [],
      @index_table
    )
    |> Enum.sort_by(&entry_rank_key/1)
  end

  @spec insert_ranked_entry(map(), [map()], pos_integer()) :: [map()]
  defp insert_ranked_entry(candidate, ranked, limit) do
    [candidate | ranked]
    |> Enum.sort_by(&entry_rank_key/1)
    |> Enum.take(limit)
  end

  @spec entry_rank_key(map()) :: {number(), non_neg_integer() | :infinity, binary()}
  defp entry_rank_key(entry), do: {-entry.score, entry.hamming_distance, entry.id}

  @spec score_entry(binary(), map(), binary() | nil, binary() | nil) :: map()
  defp score_entry(moment_id, entry, cue_vector, cue_signature) do
    cosine = max(0.0, Vector.cosine(entry.vector, cue_vector))

    signature_bits =
      Map.get(entry, :signature_bits, byte_size(entry.binary_signature || <<>>) * 8)

    hamming = Vector.hamming_distance(entry.binary_signature, cue_signature)

    hamming_similarity =
      Vector.hamming_similarity(entry.binary_signature, cue_signature, signature_bits)

    %{
      id: moment_id,
      namespace: Map.get(entry, :namespace),
      scope: Map.get(entry, :scope),
      score: cosine * 4.0 + hamming_similarity * 4.0,
      cosine: cosine,
      hamming_distance: hamming,
      hamming_similarity: hamming_similarity
    }
  end

  @spec indexable(map()) :: {:ok, map()} | :skip
  defp indexable(
         %{id: id, vector: vector, binary_signature: signature, embedding: embedding} = moment
       )
       when is_binary(id) and is_binary(vector) and is_binary(signature) do
    metadata = embedding_metadata(embedding)

    {:ok,
     %{
       namespace: Scope.namespace(moment),
       scope: Scope.scope(moment),
       vector: vector,
       binary_signature: signature,
       dimensions: Map.get(metadata, :dimensions) || Vector.dimensions(vector),
       signature_bits: Map.get(metadata, :signature_bits) || byte_size(signature) * 8,
       metadata: metadata
     }}
  end

  defp indexable(_moment), do: :skip

  @spec embedding_metadata(term()) :: map()
  defp embedding_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp embedding_metadata(_embedding), do: %{}

  @spec query_limit(keyword()) :: non_neg_integer()
  defp query_limit(opts) do
    case Keyword.get(opts, :overfetch) || get_in(index_config(), [:overfetch]) || 40 do
      limit when is_integer(limit) and limit >= 0 -> limit
      _invalid -> 40
    end
  end

  @spec filter_similarity([map()], keyword()) :: [map()]
  defp filter_similarity(results, opts) do
    minimum = similarity_floor(opts)
    Enum.filter(results, &(Map.get(&1, :cosine, 0.0) >= minimum))
  end

  @spec similarity_floor(keyword()) :: float()
  defp similarity_floor(opts) do
    case Keyword.get(opts, :min_vector_similarity, 0.0) do
      value when is_number(value) -> (value * 1.0) |> max(0.0) |> min(1.0)
      _invalid -> 0.0
    end
  end

  @spec index_config :: map()
  defp index_config do
    embedding = Application.get_env(:spectre_mnemonic, :embedding, [])

    index =
      cond do
        is_list(embedding) and Keyword.keyword?(embedding) -> Keyword.get(embedding, :index, [])
        is_map(embedding) -> Map.get(embedding, :index, Map.get(embedding, "index", %{}))
        true -> []
      end

    cond do
      is_map(index) -> index
      is_list(index) and Keyword.keyword?(index) -> Map.new(index)
      true -> %{}
    end
  end

  @spec call_if_running(term(), term()) :: term()
  defp call_if_running(message, fallback \\ :ok) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, message)
    else
      fallback
    end
  end

  @spec ensure_table(atom()) :: :ok | :ets.tid()
  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:named_table, :public, :compressed, read_concurrency: true])
      _tid -> :ok
    end
  end
end
