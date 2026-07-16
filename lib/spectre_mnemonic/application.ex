defmodule SpectreMnemonic.Application do
  @moduledoc """
  OTP application supervisor for Spectre Mnemonic.

  The tree is intentionally flat in V1 so it is easy to see what process owns
  each concern: ETS tables, persistent memory, streams, focus, recall, and
  consolidation.
  """

  use Application

  @impl Application
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    with {:ok, _namespace} <- SpectreMnemonic.Identity.configured_namespace() do
      start_supervisor()
    end
  end

  @spec start_supervisor() :: Supervisor.on_start()
  defp start_supervisor do
    # The tree is deliberately boring: owners before users, indexes before
    # callers, background work last. OTP does the babysitting so agents dont
    # cosplay as infrastructure.
    children = [
      SpectreMnemonic.Active.ETSOwner,
      SpectreMnemonic.Persistence.Manager,
      SpectreMnemonic.Knowledge.SMEM,
      SpectreMnemonic.Governance,
      SpectreMnemonic.Durable.Index,
      {Registry, keys: :unique, name: SpectreMnemonic.Active.StreamRegistry},
      SpectreMnemonic.Active.StreamSupervisor,
      SpectreMnemonic.Active.Router,
      SpectreMnemonic.Recall.Index,
      SpectreMnemonic.Active.Focus,
      SpectreMnemonic.Recall.Engine,
      SpectreMnemonic.Knowledge.Consolidator,
      SpectreMnemonic.ConsolidationScheduler
    ]

    # ETSOwner is the root of every hot projection. rest_for_one guarantees that
    # a table-owner restart also rebuilds all processes which depend on those
    # tables instead of leaving them alive with incoherent projections.
    Supervisor.start_link(children, strategy: :rest_for_one, name: SpectreMnemonic.Supervisor)
  end
end
