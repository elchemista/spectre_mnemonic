defmodule SpectreMnemonic.Recall.Index do
  @moduledoc """
  Active-memory embedding index.

  The index keeps a small ETS mirror of dense vectors and packed binary
  signatures. Vettore provides the partition-local dense ANN path. The ETS
  mirror remains the deterministic brute-force fallback and the source for
  binary Hamming reranking.
  """

  use GenServer

  alias SpectreMnemonic.Active.ETS, as: ActiveETS
  alias SpectreMnemonic.Embedding.Space
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Projection
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Telemetry

  @registry SpectreMnemonic.Engine.Registry
  @tables_key {__MODULE__, :tables}
  @config_key {__MODULE__, :config}

  @type state :: %{
          vettore: %{optional(tuple()) => map()}
        }

  @doc "Starts the index process."
  @spec start_link(keyword() | Config.t()) :: GenServer.on_start()
  def start_link(opts \\ [])
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  @spec child_spec(keyword() | Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.ref},
      start: {__MODULE__, :start_link, [config]}
    }
  end

  def child_spec(opts) when is_list(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Indexes or replaces one moment."
  @spec upsert(SpectreMnemonic.Memory.Moment.t() | SpectreMnemonic.Memory.Secret.t()) :: :ok
  def upsert(%{namespace: namespace} = moment),
    do: call_if_running(server_for_namespace(namespace), {:upsert, moment})

  def upsert(_moment), do: :ok

  @doc "Removes one moment from the index."
  @spec delete(binary() | map(), keyword()) :: :ok
  def delete(moment_or_id, opts \\ [])

  def delete(%{id: moment_id, namespace: namespace}, _opts),
    do: call_if_running(server_for_namespace(namespace), {:delete, moment_id})

  def delete(moment_id, opts) when is_binary(moment_id),
    do: call_if_running(server_for_opts(opts), {:delete, moment_id})

  @doc "Queries indexed active moments by cue embedding."
  @spec query(map(), keyword()) :: {:ok, [map()]}
  def query(cue, opts \\ []) do
    Telemetry.span([:vector, :query], Telemetry.metadata(opts), fn ->
      with_tables(
        opts,
        fn ->
          limit = query_limit(opts)

          results =
            (query_vettore_scoped(cue, limit, opts) || brute_force(cue, limit, opts))
            |> filter_similarity(opts)
            |> Enum.take(limit)

          {:ok, results}
        end,
        {:ok, []}
      )
    end)
  rescue
    ArgumentError -> {:ok, []}
  end

  @doc "Clears ETS index state."
  @spec reset :: :ok
  def reset do
    Enum.each(index_servers(), &safe_call(&1, :reset))
    if pid = Process.whereis(__MODULE__), do: safe_call(pid, :reset)
    :ok
  end

  @doc false
  @spec rebuild(keyword()) :: :ok
  def rebuild(opts \\ []), do: call_if_running(server_for_opts(opts), :rebuild)

  @doc false
  @spec purge_partition(keyword()) :: :ok
  def purge_partition(opts),
    do: call_if_running(server_for_opts(opts), {:purge_partition, opts})

  @doc false
  @spec server(keyword() | binary() | Ref.t()) :: pid() | nil
  def server(%Ref{} = ref), do: server_for_ref(ref)
  def server(namespace) when is_binary(namespace), do: server_for_namespace(namespace)
  def server(opts) when is_list(opts), do: server_for_opts(opts)

  @doc false
  @spec tables(keyword()) :: map() | nil
  def tables(opts \\ []) do
    case registration_for_opts(opts) do
      %{tables: tables} -> tables
      nil -> nil
    end
  end

  @impl GenServer
  @spec init(keyword() | Config.t()) :: {:ok, state()} | {:stop, term()}
  def init(%Config{} = config) do
    tables = create_tables()
    put_runtime(tables, config)

    case Registry.register(@registry, {:recall_index, config.ref}, %{
           tables: tables,
           config: config
         }) do
      {:ok, _owner} ->
        {:ok, rebuild_from_hot(config.internal_namespace)}

      {:error, {:already_registered, pid}} ->
        {:stop, {:recall_index_already_started, config.ref, pid}}
    end
  end

  def init(opts) when is_list(opts) do
    tables = create_tables()
    put_runtime(tables, nil)
    {:ok, rebuild_from_hot(Keyword.get(opts, :namespace))}
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:upsert, moment}, _from, state) do
    # The active index is a helper, not the source of truth. ETS focus owns the
    # memory; this process just keeps vector shortcuts warm.
    case indexable(moment) do
      {:ok, entry} ->
        state = maybe_delete_vettore(state, moment.id)
        :ets.insert(index_table(), {moment.id, entry})
        state = maybe_upsert_vettore(state, moment.id, entry)

        {:reply, :ok, state}

      :skip ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete, moment_id}, _from, state) do
    state = maybe_delete_vettore(state, moment_id)
    :ets.delete(index_table(), moment_id)
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    close_vettore_collections(state)
    :ets.delete_all_objects(index_table())
    :ets.delete_all_objects(collection_table())

    {:reply, :ok, %{state | vettore: %{}}}
  end

  def handle_call(:rebuild, _from, state) do
    close_vettore_collections(state)
    config = Process.get(@config_key)
    namespace = if match?(%Config{}, config), do: config.internal_namespace, else: nil
    {:reply, :ok, rebuild_from_hot(namespace)}
  end

  def handle_call({:purge_partition, opts}, _from, state) do
    partition = {Identity.namespace!(opts), Scope.from_opts(opts)}

    ids =
      index_table()
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {id, %{namespace: namespace, scope: scope}} when {namespace, scope} == partition -> [id]
        _other -> []
      end)

    Enum.each(ids, &:ets.delete(index_table(), &1))

    state =
      state.vettore
      |> Map.keys()
      |> Enum.filter(&collection_for_partition?(&1, partition))
      |> Enum.reduce(state, fn collection_key, acc ->
        {indexed, vettore} = Map.pop(acc.vettore, collection_key)
        _result = Vettore.close(indexed.collection)
        :ets.delete(collection_table(), collection_key)
        %{acc | vettore: vettore}
      end)

    {:reply, :ok, state}
  end

  def handle_call(:runtime, _from, state) do
    {:reply, %{tables: Process.get(@tables_key), config: Process.get(@config_key)}, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_vettore_collections(state)
    :ok
  end

  @spec rebuild_from_hot(binary() | nil) :: state()
  defp rebuild_from_hot(namespace) do
    :ets.delete_all_objects(index_table())
    :ets.delete_all_objects(collection_table())

    namespace
    |> hot_moments()
    |> Enum.reduce(%{vettore: %{}}, fn
      {_id, moment}, state ->
        case indexable_for_namespace(moment, namespace) do
          {:ok, entry} ->
            :ets.insert(index_table(), {moment.id, entry})
            maybe_upsert_vettore(state, moment.id, entry)

          :skip ->
            state
        end
    end)
  rescue
    ArgumentError -> %{vettore: %{}}
  end

  @spec hot_moments(binary() | nil) :: [tuple()]
  defp hot_moments(namespace) do
    reference =
      case namespace do
        value when is_binary(value) ->
          case Engine.resolve_internal_namespace(value) do
            {:ok, runtime} -> runtime.config.ref
            {:error, _reason} -> SpectreMnemonic.DefaultEngine
          end

        _missing ->
          SpectreMnemonic.DefaultEngine
      end

    ActiveETS.with_engine(reference, fn -> ActiveETS.tab2list(:mnemonic_moments) end)
  rescue
    ArgumentError -> []
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
    partition = entry_partition(entry)

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
        :ets.insert(collection_table(), {partition, indexed})
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
        indexed = %{indexed | count: count}
        :ets.insert(collection_table(), {partition, indexed})
        put_in(state, [:vettore, partition], indexed)

      {:error, _reason} ->
        state
    end
  end

  @spec maybe_delete_vettore(state(), binary()) :: state()
  defp maybe_delete_vettore(state, moment_id) do
    case :ets.lookup(index_table(), moment_id) do
      [{^moment_id, entry}] -> delete_vettore_entry(state, moment_id, entry)
      _missing -> state
    end
  end

  @spec delete_vettore_entry(state(), binary(), map()) :: state()
  defp delete_vettore_entry(state, moment_id, entry) do
    partition = entry_partition(entry)

    case Map.get(state.vettore, partition) do
      nil ->
        state

      indexed ->
        _result = Vettore.delete(indexed.collection, moment_id)
        indexed = %{indexed | count: max(indexed.count - 1, 0)}
        :ets.insert(collection_table(), {partition, indexed})
        put_in(state, [:vettore, partition], indexed)
    end
  rescue
    _exception -> state
  end

  @spec query_vettore_scoped(map(), non_neg_integer(), keyword()) :: [map()] | nil
  defp query_vettore_scoped(%{vector: nil}, _limit, _opts), do: nil
  defp query_vettore_scoped(_cue, limit, _opts) when limit <= 0, do: []

  defp query_vettore_scoped(cue, limit, opts) do
    space_id = cue_space_id(cue, opts)
    partition = {Identity.namespace!(opts), Scope.from_opts(opts), space_id}

    with true <- space_id != :any,
         true <- vettore_enabled?(),
         [{^partition, %{count: count} = indexed}] when count > 0 <-
           :ets.lookup(collection_table(), partition),
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
    case :ets.lookup(index_table(), moment_id) do
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

    cue
    |> brute_force_entries(opts)
    |> Enum.reduce([], fn {moment_id, entry}, ranked ->
      if Scope.match?(entry, opts) and compatible_space?(entry, cue, opts) do
        moment_id
        |> score_entry(entry, cue_vector, cue_signature)
        |> insert_ranked_entry(ranked, limit)
      else
        ranked
      end
    end)
    |> Enum.sort_by(&entry_rank_key/1)
  end

  @spec brute_force_entries(map(), keyword()) :: [{binary(), map()}]
  defp brute_force_entries(%QueryContext{} = cue, opts) do
    case Projection.candidates(cue, [], opts) do
      {:ok, moments, _meta} ->
        Enum.flat_map(moments, fn moment ->
          case :ets.lookup(index_table(), moment.id) do
            [{id, entry}] -> [{id, entry}]
            [] -> []
          end
        end)

      {:fallback, _meta} ->
        :ets.tab2list(index_table())
    end
  end

  defp brute_force_entries(_cue, _opts), do: :ets.tab2list(index_table())

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
       space_id: Space.id(metadata, []),
       signature_bits: Map.get(metadata, :signature_bits) || byte_size(signature) * 8,
       metadata: metadata
     }}
  end

  defp indexable(_moment), do: :skip

  @spec indexable_for_namespace(map(), binary() | nil) :: {:ok, map()} | :skip
  defp indexable_for_namespace(moment, nil), do: indexable(moment)

  defp indexable_for_namespace(%{namespace: namespace} = moment, namespace),
    do: indexable(moment)

  defp indexable_for_namespace(_moment, _namespace), do: :skip

  @spec entry_partition(map()) :: tuple()
  defp entry_partition(entry) do
    {entry.namespace, entry.scope, Map.get(entry, :space_id, "default")}
  end

  @spec collection_for_partition?(tuple(), tuple()) :: boolean()
  defp collection_for_partition?({namespace, scope, _space_id}, {namespace, scope}), do: true
  defp collection_for_partition?(_collection, _partition), do: false

  @spec compatible_space?(map(), map(), keyword()) :: boolean()
  defp compatible_space?(entry, cue, opts) do
    case cue_space_id(cue, opts) do
      :any -> true
      space_id -> Map.get(entry, :space_id, "default") == space_id
    end
  end

  @spec cue_space_id(map(), keyword()) :: binary() | :any
  defp cue_space_id(cue, opts) do
    metadata =
      case Map.get(cue, :embedding) do
        %{metadata: metadata} when is_map(metadata) -> metadata
        _missing -> Map.get(cue, :metadata, %{})
      end

    if metadata == %{} and not Keyword.has_key?(opts, :embedding_space),
      do: :any,
      else: Space.id(metadata, opts)
  end

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
    case Keyword.get(opts, :min_vector_similarity, 0.15) do
      value when is_number(value) -> (value * 1.0) |> max(0.0) |> min(1.0)
      _invalid -> 0.0
    end
  end

  @spec index_config :: map()
  defp index_config do
    embedding_config()
    |> raw_index_config()
    |> normalize_index_config()
  end

  @spec embedding_config :: term()
  defp embedding_config do
    case Process.get(@config_key) do
      %Config{legacy?: false, embedding: configured} -> configured || []
      _legacy_or_direct -> Application.get_env(:spectre_mnemonic, :embedding, [])
    end
  end

  @spec raw_index_config(term()) :: term()
  defp raw_index_config(embedding) when is_list(embedding) do
    if Keyword.keyword?(embedding), do: Keyword.get(embedding, :index, []), else: []
  end

  defp raw_index_config(embedding) when is_map(embedding),
    do: Map.get(embedding, :index, Map.get(embedding, "index", %{}))

  defp raw_index_config(_embedding), do: []

  @spec normalize_index_config(term()) :: map()
  defp normalize_index_config(index) when is_map(index), do: index

  defp normalize_index_config(index) when is_list(index) do
    if Keyword.keyword?(index), do: Map.new(index), else: %{}
  end

  defp normalize_index_config(_index), do: %{}

  @spec with_tables(keyword(), (-> result), result) :: result when result: term()
  defp with_tables(opts, fun, fallback) do
    case registration_for_opts(opts) do
      %{tables: tables, config: config} ->
        previous_tables = Process.put(@tables_key, tables)
        previous_config = Process.put(@config_key, config)

        try do
          fun.()
        after
          restore_process_value(@tables_key, previous_tables)
          restore_process_value(@config_key, previous_config)
        end

      nil ->
        fallback
    end
  end

  @spec registration_for_opts(keyword()) :: map() | nil
  defp registration_for_opts(opts) do
    case engine_ref_for_opts(opts) do
      %Ref{} = ref -> registration_for_ref(ref)
      nil -> legacy_registration()
    end
  end

  @spec engine_ref_for_opts(keyword()) :: Ref.t() | nil
  defp engine_ref_for_opts(opts) do
    case Keyword.get(opts, :engine_ref) do
      %Ref{} = ref -> ref
      _missing -> engine_ref_for_namespace(opts)
    end
  end

  @spec engine_ref_for_namespace(keyword()) :: Ref.t() | nil
  defp engine_ref_for_namespace(opts) do
    with {:ok, namespace} <- Identity.fetch_namespace(opts),
         {:ok, runtime} <- Engine.resolve_internal_namespace(namespace) do
      runtime.config.ref
    else
      {:error, _reason} -> nil
    end
  end

  @spec registration_for_ref(Ref.t()) :: map() | nil
  defp registration_for_ref(%Ref{} = ref) do
    case Registry.lookup(@registry, {:recall_index, ref}) do
      [{_pid, registration}] -> registration
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec legacy_registration :: map() | nil
  defp legacy_registration do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :runtime)
    end
  catch
    :exit, _reason -> nil
  end

  @spec server_for_opts(keyword()) :: pid() | nil
  defp server_for_opts(opts) do
    case engine_ref_for_opts(opts) do
      %Ref{} = ref -> server_for_ref(ref)
      nil -> Process.whereis(__MODULE__)
    end
  end

  @spec server_for_namespace(term()) :: pid() | nil
  defp server_for_namespace(namespace) when is_binary(namespace) do
    case Engine.resolve_internal_namespace(namespace) do
      {:ok, runtime} -> server_for_ref(runtime.config.ref)
      {:error, _reason} -> Process.whereis(__MODULE__)
    end
  end

  defp server_for_namespace(_namespace), do: Process.whereis(__MODULE__)

  @spec server_for_ref(Ref.t()) :: pid() | nil
  defp server_for_ref(%Ref{} = ref) do
    case Registry.lookup(@registry, {:recall_index, ref}) do
      [{pid, _registration}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec index_servers :: [pid()]
  defp index_servers do
    @registry
    |> Registry.select([{{{:recall_index, :"$1"}, :"$2", :_}, [], [:"$2"]}])
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  @spec call_if_running(pid() | nil, term(), term()) :: term()
  defp call_if_running(pid, message, fallback \\ :ok) do
    case pid do
      nil -> fallback
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _reason -> fallback
  end

  @spec safe_call(pid(), term()) :: :ok
  defp safe_call(pid, message) do
    _reply = GenServer.call(pid, message)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec create_tables :: map()
  defp create_tables do
    common = [:protected, :compressed, read_concurrency: true]

    %{
      index: :ets.new(:embedding_index, [:set | common]),
      collections: :ets.new(:vettore_collections, [:set | common])
    }
  end

  @spec put_runtime(map(), Config.t() | nil) :: map()
  defp put_runtime(tables, config) do
    Process.put(@tables_key, tables)
    Process.put(@config_key, config)
    tables
  end

  @spec index_table :: :ets.tid()
  defp index_table, do: Process.get(@tables_key) |> Map.fetch!(:index)

  @spec collection_table :: :ets.tid()
  defp collection_table, do: Process.get(@tables_key) |> Map.fetch!(:collections)

  @spec restore_process_value(term(), term()) :: term()
  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
