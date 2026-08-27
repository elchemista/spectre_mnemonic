defmodule SpectreMnemonic.Engine.ProjectionShard do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Active.ETS, as: ActiveETS
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.FailureInjection
  alias SpectreMnemonic.Memory.Scope

  @registry SpectreMnemonic.Engine.Registry

  @type tables :: %{
          documents: :ets.tid(),
          postings: :ets.tid(),
          recent: :ets.tid(),
          metadata: :ets.tid()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)
    index = Keyword.fetch!(opts, :index)

    %{
      id: {__MODULE__, config.ref, index},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    index = Keyword.fetch!(opts, :index)
    tables = create_tables()
    state = %{config: config, index: index, tables: tables}

    case Registry.register(@registry, {:projection_shard, config.ref, index}, tables) do
      {:ok, _owner} ->
        rebuild(state)
        {:ok, state}

      {:error, {:already_registered, pid}} ->
        {:stop, {:projection_shard_already_started, config.ref, index, pid}}
    end
  end

  @impl GenServer
  def handle_call({:upsert, moment}, _from, state) do
    upsert_moment(moment, state, [])
    {:reply, :ok, state}
  end

  def handle_call({:delete, moment}, _from, state) do
    delete_moment(moment, state)
    {:reply, :ok, state}
  end

  def handle_call({:apply_batch, commit_id, changes, opts}, _from, state) do
    marker = {:commit, commit_id}

    unless :ets.member(state.tables.metadata, marker) do
      Enum.each(changes, fn
        {:upsert, moment} -> upsert_moment(moment, state, opts)
        {:delete, moment} -> delete_moment(moment, state)
      end)

      :ets.insert(state.tables.metadata, {marker, true})
    end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(Map.values(state.tables), &:ets.delete_all_objects/1)
    {:reply, :ok, state}
  end

  @spec create_tables :: tables()
  defp create_tables do
    common = [:protected, :compressed, read_concurrency: true]

    %{
      documents: :ets.new(:documents, [:set | common]),
      postings: :ets.new(:postings, [:set | common]),
      recent: :ets.new(:recent, [:set | common]),
      metadata: :ets.new(:metadata, [:set | common])
    }
  end

  @spec rebuild(map()) :: :ok
  defp rebuild(state) do
    try do
      ActiveETS.with_engine(state.config.ref, fn ->
        :mnemonic_moments
        |> ActiveETS.tab2list()
        |> Enum.each(fn {_id, moment} ->
          if owns?(moment, state), do: upsert_moment(moment, state, [])
        end)
      end)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @spec owns?(map(), map()) :: boolean()
  defp owns?(moment, state) do
    moment.namespace == state.config.internal_namespace and
      shard_index(state.config, Scope.partition(moment)) == state.index
  end

  @spec shard_index(Config.t(), tuple()) :: non_neg_integer()
  defp shard_index(config, {namespace, scope}) do
    :erlang.phash2({config.ref, namespace, scope}, config.projection_shards)
  end

  @spec upsert_moment(map(), map(), keyword()) :: :ok
  defp upsert_moment(moment, state, opts) do
    tables = state.tables

    case :ets.lookup(tables.documents, moment.id) do
      [{_id, previous}] -> remove_indexes(previous, state)
      [] -> increment_count(Scope.partition(moment), tables.metadata)
    end

    :ets.insert(tables.documents, {moment.id, moment})

    :ok =
      FailureInjection.checkpoint(:projection_apply_after_document, opts, %{
        moment_id: moment.id,
        shard: state.index
      })

    add_indexes(moment, state)
    :ok
  end

  @spec delete_moment(map(), map()) :: :ok
  defp delete_moment(moment, state) do
    tables = state.tables

    case :ets.lookup(tables.documents, moment.id) do
      [{_id, indexed}] ->
        remove_indexes(indexed, state)
        :ets.delete(tables.documents, moment.id)
        decrement_count(Scope.partition(indexed), tables.metadata)

      [] ->
        :ok
    end

    :ok
  end

  @spec add_indexes(map(), map()) :: :ok
  defp add_indexes(moment, state) do
    partition = Scope.partition(moment)
    cap = state.config.limits.max_candidates

    Enum.each(index_keys(moment), fn key ->
      put_capped(state.tables.postings, {partition, key}, moment.id, cap)
    end)

    put_capped(state.tables.recent, partition, moment.id, cap)
    :ok
  end

  @spec remove_indexes(map(), map()) :: :ok
  defp remove_indexes(moment, state) do
    partition = Scope.partition(moment)

    Enum.each(index_keys(moment), fn key ->
      remove_id(state.tables.postings, {partition, key}, moment.id)
    end)

    remove_id(state.tables.recent, partition, moment.id)
    :ok
  end

  @spec index_keys(map()) :: [tuple()]
  defp index_keys(moment) do
    term_keys = Enum.map(Map.get(moment, :keywords, []), &{:term, normalize_term(&1)})
    entity_keys = Enum.map(Map.get(moment, :entities, []), &{:entity, normalize_term(&1)})

    field_keys = [
      {:stream, Map.get(moment, :stream)},
      {:task, Map.get(moment, :task_id)},
      {:kind, Map.get(moment, :kind)},
      {:temporal, temporal_bucket(Map.get(moment, :inserted_at))}
    ]

    (term_keys ++ entity_keys ++ field_keys)
    |> Enum.reject(fn {_axis, value} -> is_nil(value) or value == "" end)
    |> Enum.uniq()
  end

  @spec normalize_term(term()) :: binary()
  defp normalize_term(value), do: value |> to_string() |> String.downcase()

  @spec temporal_bucket(term()) :: binary() | nil
  defp temporal_bucket(%DateTime{} = datetime),
    do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp temporal_bucket(_datetime), do: nil

  @spec put_capped(:ets.tid(), term(), binary(), pos_integer()) :: true
  defp put_capped(table, key, id, cap) do
    ids =
      case :ets.lookup(table, key) do
        [{^key, existing}] -> [id | List.delete(existing, id)]
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

  @spec increment_count(tuple(), :ets.tid()) :: integer() | [integer()]
  defp increment_count(partition, table) do
    :ets.update_counter(table, {:count, partition}, {2, 1}, {{:count, partition}, 0})
  end

  @spec decrement_count(tuple(), :ets.tid()) :: integer() | [integer()]
  defp decrement_count(partition, table) do
    :ets.update_counter(table, {:count, partition}, {2, -1, 0, 0}, {{:count, partition}, 0})
  end
end
