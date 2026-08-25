defmodule SpectreMnemonic.ConsolidationScheduler do
  @moduledoc """
  Opt-in background consolidation, freshness decay, and durable index upkeep.
  """

  use GenServer

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Durable.Index
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Knowledge.Consolidator
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Manager

  @default_config [
    enabled: false,
    interval_ms: 300_000,
    mode: :all,
    min_attention: 1.0,
    stale_after_ms: 30 * 24 * 60 * 60 * 1_000
  ]

  @doc "Starts the scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns current scheduler status."
  @spec status :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil -> %{running?: false, enabled?: false}
      _pid -> GenServer.call(__MODULE__, :status)
    end
  catch
    :exit, _reason -> %{running?: false, enabled?: false}
  end

  @doc false
  @spec run_now :: map() | {:error, term()}
  def run_now do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :scheduler_not_running}
      _pid -> GenServer.call(__MODULE__, :run_now, 60_000)
    end
  catch
    :exit, reason -> {:error, {:scheduler_run_failed, reason}}
  end

  @impl GenServer
  def init(_opts) do
    cfg = config()
    state = %{config: cfg, runs: 0, last_run_at: nil, last_result: nil}
    if Keyword.get(cfg, :enabled, false), do: schedule_tick(cfg)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running?: true,
       enabled?: Keyword.get(state.config, :enabled, false),
       interval_ms: Keyword.get(state.config, :interval_ms),
       runs: state.runs,
       last_run_at: state.last_run_at,
       last_result: state.last_result
     }, state}
  end

  def handle_call(:run_now, _from, state) do
    cfg = config()
    {result, state} = execute_run(cfg, state)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    cfg = config()
    {_result, state} = execute_run(cfg, state)
    if Keyword.get(cfg, :enabled, false), do: schedule_tick(cfg)
    {:noreply, state}
  end

  @spec execute_run(keyword(), map()) :: {map(), map()}
  defp execute_run(cfg, state) do
    result = run_once(cfg)

    {result,
     %{
       state
       | config: cfg,
         runs: state.runs + 1,
         last_run_at: DateTime.utc_now(),
         last_result: result
     }}
  end

  @spec run_once(keyword()) :: map()
  defp run_once(cfg) do
    # This is opt-in because background memory jobs are helpful until they start
    # moving furniture while you are still sitting on it. Boring cron energy.
    base_opts = [
      min_attention: Keyword.get(cfg, :min_attention, 1.0),
      graph_depth: Keyword.get(cfg, :graph_depth, 1)
    ]

    partitions = known_partitions()

    consolidation =
      partition_results(partitions, base_opts, fn opts ->
        case Consolidator.consolidate(opts) do
          {:ok, records} -> {:ok, length(records)}
          {:error, reason} -> {:error, reason}
        end
      end)

    decay_opts = [stale_after_ms: Keyword.get(cfg, :stale_after_ms)]
    decay = partition_results(partitions, decay_opts, &Governance.decay/1)

    graph_decay =
      Plasticity.decay_all(stale_after_ms: Keyword.get(cfg, :stale_after_ms))

    attention_decay =
      Focus.decay_attention_all(stale_after_ms: Keyword.get(cfg, :stale_after_ms))

    compact = compact_partitions(partitions, Keyword.get(cfg, :mode, :all))

    Index.rebuild()

    %{
      partitions: partitions,
      consolidation: consolidation,
      decay: decay,
      graph_decay: graph_decay,
      attention_decay: attention_decay,
      compact: compact
    }
  end

  @spec known_partitions :: [{binary(), term()}]
  defp known_partitions do
    namespace = Identity.namespace!([])

    active =
      :mnemonic_moments_by_scope
      |> :ets.tab2list()
      |> Enum.map(fn {{record_namespace, scope}, _id} -> {record_namespace, scope} end)

    durable =
      case Manager.replay_all(namespace: namespace) do
        {:ok, records} -> Enum.map(records, &{&1.namespace, Scope.scope(&1)})
        {:error, _reason} -> []
      end

    [{namespace, nil} | active ++ durable]
    |> Enum.filter(fn {record_namespace, _scope} -> record_namespace == namespace end)
    |> Enum.uniq()
    |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic]))
  rescue
    ArgumentError -> [{Identity.namespace!([]), nil}]
  catch
    :exit, _reason -> [{Identity.namespace!([]), nil}]
  end

  @spec partition_results([{binary(), term()}], keyword(), (keyword() -> term())) :: map()
  defp partition_results(partitions, base_opts, fun) do
    results =
      Enum.map(partitions, fn {namespace, scope} ->
        opts = base_opts |> Keyword.put(:namespace, namespace) |> Keyword.put(:scope, scope)
        {{namespace, scope}, fun.(opts)}
      end)

    %{partitions: length(partitions), results: results}
  end

  @spec compact_partitions([{binary(), term()}], atom()) :: term()
  defp compact_partitions(_partitions, :none), do: {:ok, :skipped}
  defp compact_partitions(_partitions, :physical), do: Manager.compact(mode: :physical)

  defp compact_partitions(partitions, mode) when mode in [:semantic, :all] do
    semantic =
      partition_results(partitions, [], fn opts ->
        Manager.compact(Keyword.put(opts, :mode, :semantic))
      end)

    if mode == :all do
      %{mode: :all, semantic: semantic, physical: Manager.compact(mode: :physical)}
    else
      semantic
    end
  end

  defp compact_partitions(_partitions, mode), do: {:error, {:invalid_compact_mode, mode}}

  @spec config :: keyword()
  defp config do
    configured =
      :spectre_mnemonic
      |> Application.get_env(:consolidation_scheduler, [])
      |> normalize_config()

    @default_config
    |> Keyword.merge(configured)
    |> normalize_values()
  end

  @spec schedule_tick(keyword()) :: reference()
  defp schedule_tick(cfg) do
    Process.send_after(self(), :tick, Keyword.get(cfg, :interval_ms, 300_000))
  end

  @spec normalize_config(term()) :: keyword()
  defp normalize_config(config) when is_map(config), do: Map.to_list(config)

  defp normalize_config(config) when is_list(config) do
    if Keyword.keyword?(config), do: config, else: []
  end

  defp normalize_config(_config), do: []

  @spec normalize_values(keyword()) :: keyword()
  defp normalize_values(config) do
    config
    |> normalize_value(:enabled, &is_boolean/1)
    |> normalize_value(:interval_ms, &(is_integer(&1) and &1 > 0))
    |> normalize_value(:min_attention, &is_number/1)
    |> normalize_value(:stale_after_ms, &(is_integer(&1) and &1 >= 0))
    |> normalize_value(:mode, &(&1 in [:none, :physical, :semantic, :all]))
  end

  @spec normalize_value(keyword(), atom(), (term() -> boolean())) :: keyword()
  defp normalize_value(config, key, valid?) do
    if valid?.(Keyword.get(config, key)),
      do: config,
      else: Keyword.put(config, key, Keyword.fetch!(@default_config, key))
  end
end
