defmodule SpectreMnemonic.Engine.HotStore do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Ref

  @registry SpectreMnemonic.Engine.Registry

  @table_definitions [
    mnemonic_signals: :set,
    mnemonic_moments: :set,
    mnemonic_moments_by_stream: :bag,
    mnemonic_moments_by_task: :bag,
    mnemonic_moments_by_scope: :bag,
    mnemonic_moments_by_signal: :set,
    mnemonic_moment_counts: :set,
    mnemonic_moment_sizes: :set,
    mnemonic_hot_bytes: :set,
    mnemonic_moment_eviction: :ordered_set,
    mnemonic_moment_eviction_keys: :set,
    mnemonic_status: :set,
    mnemonic_associations: :set,
    mnemonic_associations_by_scope: :bag,
    mnemonic_associations_by_memory: :bag,
    mnemonic_entity_registry: :set,
    mnemonic_episodes: :set,
    mnemonic_episodes_by_scope: :bag,
    mnemonic_atlas_dirty: :bag,
    mnemonic_erasure_markers: :set,
    mnemonic_batch_commits: :set,
    mnemonic_attention: :set,
    mnemonic_artifacts: :set,
    mnemonic_action_recipes: :set,
    mnemonic_observations: :set,
    mnemonic_observations_by_scope: :bag,
    mnemonic_mental_models: :set,
    mnemonic_mental_models_by_scope: :bag,
    mnemonic_governance_states: :set,
    mnemonic_governance_states_by_scope: :bag,
    mnemonic_governance_facts: :set
  ]

  @type tables :: %{required(atom()) => :ets.tid()}

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
  @spec tables(Ref.t()) :: {:ok, tables()} | {:error, :hot_store_unavailable}
  def tables(%Ref{} = ref) do
    case Registry.lookup(@registry, {:hot_store, ref}) do
      [{pid, tables}] when is_pid(pid) and is_map(tables) -> {:ok, tables}
      [] -> {:error, :hot_store_unavailable}
    end
  rescue
    ArgumentError -> {:error, :hot_store_unavailable}
  end

  @impl GenServer
  def init(%Config{} = config) do
    tables = create_tables()

    case Registry.register(@registry, {:hot_store, config.ref}, tables) do
      {:ok, _owner} ->
        {:ok, %{config: config, tables: tables}}

      {:error, {:already_registered, pid}} ->
        {:stop, {:hot_store_already_started, config.ref, pid}}
    end
  end

  @impl GenServer
  def handle_call({:ets_write, table, operation}, _from, state) do
    if table in Map.values(state.tables) do
      {:reply, apply_ets_write(table, operation), state}
    else
      {:reply, {:error, :unknown_hot_store_table}, state}
    end
  end

  @spec create_tables :: tables()
  defp create_tables do
    Map.new(@table_definitions, fn {logical_name, type} ->
      options = [
        type,
        :protected,
        :compressed,
        read_concurrency: true,
        write_concurrency: true
      ]

      {logical_name, :ets.new(logical_name, options)}
    end)
  end

  @spec apply_ets_write(:ets.tid(), tuple()) :: term()
  defp apply_ets_write(table, {:insert, object}), do: :ets.insert(table, object)
  defp apply_ets_write(table, {:delete, key}), do: :ets.delete(table, key)
  defp apply_ets_write(table, {:delete_object, object}), do: :ets.delete_object(table, object)
  defp apply_ets_write(table, :delete_all_objects), do: :ets.delete_all_objects(table)
  defp apply_ets_write(table, {:match_delete, pattern}), do: :ets.match_delete(table, pattern)

  defp apply_ets_write(table, {:update_counter, key, update}),
    do: :ets.update_counter(table, key, update)

  defp apply_ets_write(table, {:update_counter, key, update, default}),
    do: :ets.update_counter(table, key, update, default)
end
