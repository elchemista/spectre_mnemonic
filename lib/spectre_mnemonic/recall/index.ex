defmodule SpectreMnemonic.Recall.Index do
  @moduledoc """
  Active-memory embedding index.

  The index keeps a small ETS mirror of dense vectors and packed binary
  signatures. When `hnswlib` is available and enabled, it is used for dense ANN
  candidate retrieval; the ETS mirror remains the deterministic brute-force
  fallback and the source for binary Hamming reranking.
  """

  use GenServer

  alias SpectreMnemonic.Embedding.Vector

  @index_table :mnemonic_embedding_index
  @label_table :mnemonic_embedding_labels
  @hnsw_index Module.concat(HNSWLib, Index)

  @type state :: %{
          next_label: pos_integer(),
          hnsw: term(),
          hnsw_dim: pos_integer() | nil,
          hnsw_max: pos_integer() | nil
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

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    ensure_table(@index_table)
    ensure_table(@label_table)

    {:ok, %{next_label: 1, hnsw: nil, hnsw_dim: nil, hnsw_max: nil}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:upsert, moment}, _from, state) do
    case indexable(moment) do
      {:ok, entry} ->
        label = existing_label(moment.id) || state.next_label
        :ets.insert(@index_table, {moment.id, Map.put(entry, :label, label)})
        :ets.insert(@label_table, {label, moment.id})

        state =
          maybe_add_hnsw(%{state | next_label: max(state.next_label, label + 1)}, entry, label)

        {:reply, :ok, state}

      :skip ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete, moment_id}, _from, state) do
    case :ets.lookup(@index_table, moment_id) do
      [{^moment_id, %{label: label}}] ->
        maybe_mark_deleted(state.hnsw, label)
        :ets.delete(@label_table, label)

      _missing ->
        :ok
    end

    :ets.delete(@index_table, moment_id)
    {:reply, :ok, state}
  end

  def handle_call({:query, cue, opts}, _from, state) do
    limit = Keyword.get(opts, :overfetch) || get_in(index_config(), [:overfetch]) || 40
    results = query_hnsw(state, cue, limit) || brute_force(cue, limit)
    {:reply, {:ok, results}, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@index_table)
    :ets.delete_all_objects(@label_table)
    {:reply, :ok, %{state | hnsw: nil, hnsw_dim: nil, hnsw_max: nil, next_label: 1}}
  end

  @spec brute_force(map(), pos_integer()) :: [map()]
  defp brute_force(%{vector: nil}, _limit), do: []
  defp brute_force(_cue, limit) when limit <= 0, do: []

  defp brute_force(cue, limit) do
    cue_vector = Map.get(cue, :vector)
    cue_signature = Map.get(cue, :binary_signature)

    :ets.foldl(
      fn {moment_id, entry}, ranked ->
        moment_id
        |> score_entry(entry, cue_vector, cue_signature)
        |> insert_ranked_entry(ranked, limit)
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

  @spec query_hnsw(state(), map(), pos_integer()) :: [map()] | nil
  defp query_hnsw(%{hnsw: nil}, _cue, _limit), do: nil
  defp query_hnsw(_state, %{vector: nil}, _limit), do: nil

  defp query_hnsw(state, cue, limit) do
    k = min(limit, indexed_count())

    if k > 0, do: query_hnsw_neighbors(state, cue, k)
  rescue
    _exception -> nil
  end

  @spec query_hnsw_neighbors(state(), map(), pos_integer()) :: [map()] | nil
  defp query_hnsw_neighbors(state, cue, k) do
    case hnsw_knn_query(state.hnsw, cue.vector, k) do
      {:ok, labels, _distances} ->
        labels
        |> Nx.to_flat_list()
        |> Enum.flat_map(&entry_for_label/1)
        |> Enum.map(fn {moment_id, entry} ->
          score_entry(moment_id, entry, cue.vector, cue.binary_signature)
        end)
        |> Enum.sort_by(&{-&1.score, &1.hamming_distance, &1.id})

      {:error, _reason} ->
        nil
    end
  end

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
      score: cosine * 4.0 + hamming_similarity * 4.0,
      cosine: cosine,
      hamming_distance: hamming,
      hamming_similarity: hamming_similarity
    }
  end

  @spec indexable(map()) :: {:ok, map()} | :skip
  defp indexable(%{id: id, vector: vector, binary_signature: signature, embedding: embedding})
       when is_binary(id) and is_binary(vector) and is_binary(signature) do
    metadata = embedding_metadata(embedding)

    {:ok,
     %{
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

  @spec existing_label(binary()) :: pos_integer() | nil
  defp existing_label(moment_id) do
    case :ets.lookup(@index_table, moment_id) do
      [{^moment_id, %{label: label}}] -> label
      _missing -> nil
    end
  end

  @spec maybe_add_hnsw(state(), map(), pos_integer()) :: state()
  defp maybe_add_hnsw(state, entry, label) do
    with true <- hnsw_enabled?(),
         true <- hnsw_available?(),
         true <- Code.ensure_loaded?(Nx),
         {:ok, state} <- ensure_hnsw(state, entry.dimensions),
         :ok <- ensure_hnsw_capacity(state, label),
         tensor <- Nx.tensor([Vector.to_list(entry.vector)], type: :f32),
         :ok <- hnsw_add_items(state.hnsw, tensor, label) do
      state
    else
      _fallback -> state
    end
  rescue
    _exception -> state
  end

  @spec ensure_hnsw(state(), pos_integer()) :: {:ok, state()} | {:error, term()}
  defp ensure_hnsw(%{hnsw: nil} = state, dimensions) do
    config = index_config()
    max_elements = Map.get(config, :max_elements, 10_000)

    opts = [
      m: Map.get(config, :m, 16),
      ef_construction: Map.get(config, :ef_construction, 200),
      allow_replace_deleted: true
    ]

    case hnsw_new(Map.get(config, :space, :cosine), dimensions, max_elements, opts) do
      {:ok, index} ->
        if ef = Map.get(config, :ef) do
          hnsw_set_ef(index, ef)
        end

        {:ok, %{state | hnsw: index, hnsw_dim: dimensions, hnsw_max: max_elements}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_hnsw(%{hnsw_dim: dimensions} = state, dimensions), do: {:ok, state}
  defp ensure_hnsw(_state, _dimensions), do: {:error, :dimension_mismatch}

  @spec ensure_hnsw_capacity(state(), pos_integer()) :: :ok | {:error, term()}
  defp ensure_hnsw_capacity(%{hnsw: nil}, _label), do: :ok

  defp ensure_hnsw_capacity(%{hnsw: index, hnsw_max: max_elements}, label)
       when is_integer(max_elements) and label >= max_elements do
    hnsw_resize_index(index, max(max_elements * 2, label + 1))
  end

  defp ensure_hnsw_capacity(_state, _label), do: :ok

  @spec maybe_mark_deleted(term(), pos_integer()) :: :ok
  defp maybe_mark_deleted(nil, _label), do: :ok

  defp maybe_mark_deleted(index, label) do
    hnsw_mark_deleted(index, label)
  rescue
    _exception -> :ok
  end

  @spec entry_for_label(pos_integer()) :: [{binary(), map()}]
  defp entry_for_label(label) do
    with [{^label, moment_id}] <- :ets.lookup(@label_table, label),
         [{^moment_id, entry}] <- :ets.lookup(@index_table, moment_id) do
      [{moment_id, entry}]
    else
      _missing -> []
    end
  end

  @spec indexed_count :: non_neg_integer()
  defp indexed_count, do: :ets.info(@index_table, :size) || 0

  @spec hnsw_enabled? :: boolean()
  defp hnsw_enabled? do
    config = index_config()
    Map.get(config, :enabled, true) and Map.get(config, :backend, :hnsw) == :hnsw
  end

  @spec hnsw_available? :: boolean()
  defp hnsw_available?, do: Code.ensure_loaded?(@hnsw_index)

  @spec hnsw_new(atom(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp hnsw_new(space, dimensions, max_elements, opts) do
    apply(@hnsw_index, :new, [space, dimensions, max_elements, opts])
  end

  @spec hnsw_set_ef(term(), non_neg_integer()) :: :ok | {:error, term()}
  defp hnsw_set_ef(index, ef) do
    apply(@hnsw_index, :set_ef, [index, ef])
  end

  @spec hnsw_knn_query(term(), binary(), pos_integer()) ::
          {:ok, Nx.Tensor.t(), Nx.Tensor.t()} | {:error, term()}
  defp hnsw_knn_query(index, vector, k) do
    apply(@hnsw_index, :knn_query, [index, vector, [k: k]])
  end

  @spec hnsw_add_items(term(), Nx.Tensor.t(), pos_integer()) :: :ok | {:error, term()}
  defp hnsw_add_items(index, tensor, label) do
    apply(@hnsw_index, :add_items, [index, tensor, [ids: [label], replace_deleted: true]])
  end

  @spec hnsw_resize_index(term(), pos_integer()) :: :ok | {:error, term()}
  defp hnsw_resize_index(index, max_elements) do
    apply(@hnsw_index, :resize_index, [index, max_elements])
  end

  @spec hnsw_mark_deleted(term(), pos_integer()) :: :ok | {:error, term()}
  defp hnsw_mark_deleted(index, label) do
    apply(@hnsw_index, :mark_deleted, [index, label])
  end

  @spec index_config :: map()
  defp index_config do
    :spectre_mnemonic
    |> Application.get_env(:embedding, [])
    |> Keyword.get(:index, [])
    |> Map.new()
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
