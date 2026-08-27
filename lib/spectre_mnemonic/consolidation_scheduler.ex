defmodule SpectreMnemonic.ConsolidationScheduler do
  @moduledoc """
  Compatibility facade for Engine-owned maintenance scheduling.

  Since 0.2 every Engine owns its scheduler and its supervised maintenance
  tasks. The zero-arity functions continue to address the legacy default
  Engine; named Engines can be addressed explicitly.
  """

  alias SpectreMnemonic.Engine.MaintenanceScheduler

  @default_config [
    enabled: false,
    interval_ms: 300_000,
    deadline_ms: 60_000,
    mode: :all,
    min_attention: 1.0,
    stale_after_ms: 30 * 24 * 60 * 60 * 1_000
  ]

  @doc "Returns the legacy default Engine scheduler status."
  @spec status :: map()
  def status, do: status(SpectreMnemonic.DefaultEngine)

  @doc "Returns scheduler status for one Engine."
  @spec status(term()) :: map()
  def status(engine), do: MaintenanceScheduler.status(engine)

  @doc false
  @spec run_now :: map() | {:error, term()}
  def run_now, do: run_now(SpectreMnemonic.DefaultEngine)

  @doc false
  @spec run_now(term()) :: map() | {:error, term()}
  def run_now(engine), do: MaintenanceScheduler.run_now(engine)

  @doc false
  @spec reload :: :ok | {:error, term()}
  def reload do
    config = Application.get_env(:spectre_mnemonic, :consolidation_scheduler, [])
    MaintenanceScheduler.configure(SpectreMnemonic.DefaultEngine, config)
  end

  @doc false
  @spec normalize_config(term()) :: keyword()
  def normalize_config(config) do
    configured =
      case config do
        value when is_map(value) -> Map.to_list(value)
        value when is_list(value) -> if Keyword.keyword?(value), do: value, else: []
        _other -> []
      end

    @default_config
    |> Keyword.merge(configured)
    |> normalize_values()
  end

  @spec normalize_values(keyword()) :: keyword()
  defp normalize_values(config) do
    config
    |> normalize_value(:enabled, &is_boolean/1)
    |> normalize_value(:interval_ms, &(is_integer(&1) and &1 > 0))
    |> normalize_value(:deadline_ms, &(is_integer(&1) and &1 > 0))
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
