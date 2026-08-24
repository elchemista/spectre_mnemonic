defmodule SpectreMnemonic.ConsolidationScheduler do
  @moduledoc """
  Opt-in background consolidation, freshness decay, and durable index upkeep.
  """

  use GenServer

  alias SpectreMnemonic.Durable.Index
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Knowledge.Consolidator
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

  @impl GenServer
  def handle_info(:tick, state) do
    cfg = config()
    result = run_once(cfg)
    if Keyword.get(cfg, :enabled, false), do: schedule_tick(cfg)

    {:noreply,
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
    consolidate_opts = [
      min_attention: Keyword.get(cfg, :min_attention, 1.0),
      graph_depth: Keyword.get(cfg, :graph_depth, 1)
    ]

    consolidation =
      case Consolidator.consolidate(consolidate_opts) do
        {:ok, records} -> {:ok, length(records)}
        {:error, reason} -> {:error, reason}
      end

    decay = Governance.decay(stale_after_ms: Keyword.get(cfg, :stale_after_ms))
    graph_decay = Plasticity.decay_all()

    compact =
      case Keyword.get(cfg, :mode, :all) do
        :none -> {:ok, :skipped}
        mode -> Manager.compact(mode: mode)
      end

    Index.rebuild()

    %{consolidation: consolidation, decay: decay, graph_decay: graph_decay, compact: compact}
  end

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
  end

  @spec normalize_value(keyword(), atom(), (term() -> boolean())) :: keyword()
  defp normalize_value(config, key, valid?) do
    if valid?.(Keyword.get(config, key)),
      do: config,
      else: Keyword.put(config, key, Keyword.fetch!(@default_config, key))
  end
end
