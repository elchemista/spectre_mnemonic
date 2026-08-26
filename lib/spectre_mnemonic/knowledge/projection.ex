defmodule SpectreMnemonic.Knowledge.Projection do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Engine.Runtime
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Knowledge.SMEM
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Recall.Lexical

  @registry SpectreMnemonic.Engine.Registry

  @type tables :: %{
          documents: :ets.tid(),
          postings: :ets.tid(),
          recent: :ets.tid(),
          metadata: :ets.tid()
        }

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  @doc false
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.ref},
      start: {__MODULE__, :start_link, [config]}
    }
  end

  @doc false
  @spec upsert(map(), keyword()) :: :ok
  def upsert(event, opts) when is_map(event) and is_list(opts) do
    with {:ok, runtime} <- runtime(opts),
         {:ok, pid, _tables} <- owner(runtime.config.ref) do
      GenServer.call(pid, {:upsert, event})
    else
      _unavailable -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec rebuild(keyword()) :: :ok
  def rebuild(opts) when is_list(opts) do
    with {:ok, runtime} <- runtime(opts),
         {:ok, pid, _tables} <- owner(runtime.config.ref) do
      GenServer.call(pid, :rebuild, 60_000)
    else
      _unavailable -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec reset(Ref.t() | pid() | atom() | {:via, module(), term()}) :: :ok
  def reset(reference) do
    with {:ok, runtime} <- Engine.resolve(reference),
         {:ok, pid, _tables} <- owner(runtime.config.ref) do
      GenServer.call(pid, :reset)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec events(keyword()) :: {:ok, [map()], map()} | {:error, term()}
  def events(opts) when is_list(opts) do
    with {:ok, runtime} <- runtime(opts),
         {:ok, _pid, tables} <- owner(runtime.config.ref) do
      partition = {Identity.namespace!(opts), Scope.from_opts(opts)}
      ids = all_partition_ids(tables, partition)
      events = fetch_documents(tables.documents, partition, ids)

      {:ok, events,
       %{
         generation: generation(tables.metadata),
         candidates: length(events),
         mode: :projection
       }}
    end
  end

  @doc false
  @spec candidates([binary()], keyword()) :: {:ok, [map()], map()} | {:error, term()}
  def candidates(terms, opts) when is_list(terms) and is_list(opts) do
    with {:ok, runtime} <- runtime(opts),
         {:ok, _pid, tables} <- owner(runtime.config.ref) do
      partition = {Identity.namespace!(opts), Scope.from_opts(opts)}
      limit = candidate_limit(runtime.config, opts)

      lexical_ids =
        terms
        |> Enum.flat_map(&lookup_ids(tables.postings, {partition, {:term, normalize_term(&1)}}))

      ids = bounded_ids(lexical_ids ++ lookup_ids(tables.recent, partition), limit)
      events = fetch_documents(tables.documents, partition, ids)

      {:ok, events,
       %{
         generation: generation(tables.metadata),
         candidates: length(events),
         lexical: min(length(Enum.uniq(lexical_ids)), limit),
         mode: :candidate_first
       }}
    end
  end

  @doc false
  @spec status(Runtime.t()) :: map()
  def status(%Runtime{} = runtime) do
    case owner(runtime.config.ref) do
      {:ok, pid, tables} ->
        %{
          running?: Process.alive?(pid),
          generation: generation(tables.metadata),
          events: :ets.info(tables.documents, :size) || 0,
          bytes: table_bytes(tables)
        }

      {:error, _reason} ->
        %{running?: false, generation: nil, events: 0, bytes: 0}
    end
  rescue
    ArgumentError -> %{running?: false, generation: nil, events: 0, bytes: 0}
  end

  @impl GenServer
  def init(%Config{} = config) do
    tables = create_tables()

    case Registry.register(@registry, {:knowledge_projection, config.ref}, tables) do
      {:ok, _owner} ->
        state = %{config: config, tables: tables}
        :ok = rebuild_state(state)
        {:ok, state}

      {:error, {:already_registered, pid}} ->
        {:stop, {:knowledge_projection_already_started, config.ref, pid}}
    end
  end

  @impl GenServer
  def handle_call({:upsert, event}, _from, state) do
    apply_event(event, state)
    {:reply, :ok, state}
  end

  def handle_call(:rebuild, _from, state) do
    {:reply, rebuild_state(state), state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(Map.values(state.tables), &:ets.delete_all_objects/1)
    {:reply, :ok, state}
  end

  @spec create_tables :: tables()
  defp create_tables do
    common = [:protected, :compressed, read_concurrency: true]

    %{
      documents: :ets.new(:knowledge_documents, [:set | common]),
      postings: :ets.new(:knowledge_postings, [:set | common]),
      recent: :ets.new(:knowledge_recent, [:set | common]),
      metadata: :ets.new(:knowledge_metadata, [:set | common])
    }
  end

  @spec rebuild_state(map()) :: :ok
  defp rebuild_state(state) do
    Enum.each(Map.values(state.tables), &:ets.delete_all_objects/1)

    opts = [
      namespace: state.config.internal_namespace,
      data_root: state.config.data_root,
      engine_ref: state.config.ref,
      engine_internal?: true
    ]

    _result =
      SMEM.reduce_all(opts, :ok, fn {_sequence, _timestamp, event}, :ok ->
        apply_event(event, state)
        {:cont, :ok}
      end)

    increment_generation(state.tables.metadata)
    :ok
  end

  @spec apply_event(map(), map()) :: :ok
  defp apply_event(event, state) do
    if erasure_marker?(event) do
      purge_partition(Scope.partition(event), state)
    else
      upsert_event(event, state)
    end

    increment_generation(state.tables.metadata)
    :ok
  end

  @spec upsert_event(map(), map()) :: :ok
  defp upsert_event(event, state) do
    partition = Scope.partition(event)
    key = {partition, Map.fetch!(event, :id)}

    case :ets.lookup(state.tables.documents, key) do
      [{^key, previous}] -> remove_indexes(previous, state)
      [] -> :ok
    end

    :ets.insert(state.tables.documents, {key, event})
    add_indexes(event, state)
    :ok
  end

  @spec purge_partition(tuple(), map()) :: :ok
  defp purge_partition(partition, state) do
    all_partition_ids(state.tables, partition)
    |> Enum.each(fn id ->
      key = {partition, id}

      case :ets.lookup(state.tables.documents, key) do
        [{^key, event}] ->
          remove_indexes(event, state)
          :ets.delete(state.tables.documents, key)

        [] ->
          :ok
      end
    end)

    :ok
  end

  @spec add_indexes(map(), map()) :: :ok
  defp add_indexes(event, state) do
    partition = Scope.partition(event)
    cap = state.config.limits.max_candidates

    Enum.each(index_keys(event), fn key ->
      put_capped(state.tables.postings, {partition, key}, event.id, cap)
    end)

    put_capped(state.tables.recent, partition, event.id, cap)
    :ok
  end

  @spec remove_indexes(map(), map()) :: :ok
  defp remove_indexes(event, state) do
    partition = Scope.partition(event)

    Enum.each(index_keys(event), fn key ->
      remove_id(state.tables.postings, {partition, key}, event.id)
    end)

    remove_id(state.tables.recent, partition, event.id)
    :ok
  end

  @spec index_keys(map()) :: [tuple()]
  defp index_keys(event) do
    text =
      [
        Map.get(event, :summary),
        Map.get(event, :name),
        Map.get(event, :text),
        inspect(Map.get(event, :steps, []), limit: 20),
        inspect(Map.get(event, :value), limit: 20)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    term_keys =
      text
      |> Lexical.keywords()
      |> Enum.map(&{:term, normalize_term(&1)})

    [{:type, Map.get(event, :type, :fact)} | term_keys]
    |> Enum.uniq()
  end

  @spec all_partition_ids(tables(), tuple()) :: [binary()]
  defp all_partition_ids(tables, partition) do
    SMEM.event_types()
    |> Enum.flat_map(&lookup_ids(tables.postings, {partition, {:type, &1}}))
    |> bounded_ids(:infinity)
  end

  @spec fetch_documents(:ets.tid(), tuple(), [binary()]) :: [map()]
  defp fetch_documents(table, partition, ids) do
    Enum.flat_map(ids, fn id ->
      case :ets.lookup(table, {partition, id}) do
        [{{^partition, ^id}, event}] -> [event]
        [] -> []
      end
    end)
  end

  @spec bounded_ids([binary()], pos_integer() | :infinity) :: [binary()]
  defp bounded_ids(ids, limit) do
    {result, _seen} =
      Enum.reduce_while(ids, {[], MapSet.new()}, fn id, {acc, seen} ->
        cond do
          limit != :infinity and MapSet.size(seen) >= limit -> {:halt, {acc, seen}}
          MapSet.member?(seen, id) -> {:cont, {acc, seen}}
          true -> {:cont, {[id | acc], MapSet.put(seen, id)}}
        end
      end)

    Enum.reverse(result)
  end

  @spec put_capped(:ets.tid(), term(), binary(), pos_integer()) :: true
  defp put_capped(table, key, id, cap) do
    ids =
      case :ets.lookup(table, key) do
        [{^key, current}] -> [id | List.delete(current, id)]
        [] -> [id]
      end

    :ets.insert(table, {key, Enum.take(ids, cap)})
  end

  @spec remove_id(:ets.tid(), term(), binary()) :: true
  defp remove_id(table, key, id) do
    case :ets.lookup(table, key) do
      [{^key, ids}] ->
        case List.delete(ids, id) do
          [] -> :ets.delete(table, key)
          remaining -> :ets.insert(table, {key, remaining})
        end

      [] ->
        true
    end
  end

  @spec lookup_ids(:ets.tid(), term()) :: [binary()]
  defp lookup_ids(table, key) do
    case :ets.lookup(table, key) do
      [{^key, ids}] -> ids
      [] -> []
    end
  end

  @spec erasure_marker?(map()) :: boolean()
  defp erasure_marker?(event) do
    metadata = Map.get(event, :metadata, %{})
    Map.get(event, :type) == :compaction_marker and Map.get(metadata, :erasure?, false)
  end

  @spec candidate_limit(Config.t(), keyword()) :: pos_integer()
  defp candidate_limit(config, opts) do
    requested = Keyword.get(opts, :max_candidates, config.limits.max_candidates)
    requested |> max(1) |> min(config.limits.max_candidates)
  end

  @spec runtime(keyword()) :: {:ok, Runtime.t()} | {:error, term()}
  defp runtime(opts) do
    case Keyword.get(opts, :engine_ref) do
      %Ref{} = ref -> Engine.resolve(ref)
      _missing -> Engine.resolve_internal_namespace(Identity.namespace!(opts))
    end
  end

  @spec owner(Ref.t()) :: {:ok, pid(), tables()} | {:error, term()}
  defp owner(ref) do
    case Registry.lookup(@registry, {:knowledge_projection, ref}) do
      [{pid, tables}] -> {:ok, pid, tables}
      [] -> {:error, :knowledge_projection_unavailable}
    end
  rescue
    ArgumentError -> {:error, :knowledge_projection_unavailable}
  end

  @spec normalize_term(term()) :: binary()
  defp normalize_term(term), do: term |> to_string() |> String.downcase()

  @spec generation(:ets.tid()) :: non_neg_integer()
  defp generation(table) do
    case :ets.lookup(table, :generation) do
      [{:generation, value}] -> value
      [] -> 0
    end
  end

  @spec increment_generation(:ets.tid()) :: integer()
  defp increment_generation(table),
    do: :ets.update_counter(table, :generation, {2, 1}, {:generation, 0})

  @spec table_bytes(tables()) :: non_neg_integer()
  defp table_bytes(tables) do
    words =
      tables
      |> Map.values()
      |> Enum.reduce(0, fn table, total -> total + (:ets.info(table, :memory) || 0) end)

    words * :erlang.system_info(:wordsize)
  end
end
