defmodule SpectreMnemonic.Application do
  @moduledoc """
  OTP application supervisor for Spectre Mnemonic.

  The tree is intentionally flat in V1 so it is easy to see what process owns
  each concern: ETS tables, persistent memory, streams, focus, recall, and
  consolidation.
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      SpectreMnemonic.Active.ETSOwner,
      SpectreMnemonic.Persistence.Manager,
      {Registry, keys: :unique, name: SpectreMnemonic.Active.StreamRegistry},
      SpectreMnemonic.Active.StreamSupervisor,
      SpectreMnemonic.Active.Router,
      SpectreMnemonic.Recall.Index,
      SpectreMnemonic.Active.Focus,
      SpectreMnemonic.Recall.Engine,
      SpectreMnemonic.Knowledge.Consolidator
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SpectreMnemonic.Supervisor)
  end
end
