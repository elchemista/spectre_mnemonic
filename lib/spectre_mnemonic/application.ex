defmodule SpectreMnemonic.Application do
  @moduledoc """
  OTP application supervisor for Spectre Mnemonic.

  The tree is intentionally flat in V1 so it is easy to see what process owns
  each stateful concern: ETS tables, persistence, indexes, governance, and
  scheduled maintenance. Focus, recall, routing, and consolidation execute in
  their callers and therefore need no coordinator process.
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
      SpectreMnemonic.Persistence.PathLock,
      SpectreMnemonic.Persistence.Manager,
      SpectreMnemonic.Knowledge.SMEM,
      SpectreMnemonic.Governance,
      SpectreMnemonic.Durable.Index,
      SpectreMnemonic.Recall.Index,
      SpectreMnemonic.ConsolidationScheduler
    ]

    # ETSOwner is the root of every hot projection. rest_for_one guarantees that
    # a table-owner restart also rebuilds all processes which depend on those
    # tables instead of leaving them alive with incoherent projections.
    Supervisor.start_link(children, strategy: :rest_for_one, name: SpectreMnemonic.Supervisor)
  end
end
