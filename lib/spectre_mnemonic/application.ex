defmodule SpectreMnemonic.Application do
  @moduledoc """
  OTP application supervisor for Spectre Mnemonic.

  The tree is intentionally flat in V1 so it is easy to see what process owns
  each concern: ETS tables, persistent memory, streams, focus, recall, and
  consolidation.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SpectreMnemonic.Store.ETSOwner,
      SpectreMnemonic.PersistentMemory,
      {Registry, keys: :unique, name: SpectreMnemonic.StreamRegistry},
      SpectreMnemonic.StreamSupervisor,
      SpectreMnemonic.Router,
      SpectreMnemonic.Recall.Index,
      SpectreMnemonic.Focus,
      SpectreMnemonic.Recall,
      SpectreMnemonic.Consolidator
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SpectreMnemonic.Supervisor)
  end
end
