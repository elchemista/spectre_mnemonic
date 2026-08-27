defmodule SpectreMnemonic.Application do
  @moduledoc """
  OTP application supervisor for Spectre Mnemonic.

  The application owns only VM-local registries, bounded-executor supervisors,
  shared task infrastructure, and the optional legacy DefaultEngine. Memory,
  stores, indexes, governance, repair, and maintenance are owned by each Engine.
  """

  use Application

  alias SpectreMnemonic.Engine.Config

  @impl Application
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args), do: start_supervisor()

  @spec start_supervisor() :: Supervisor.on_start()
  defp start_supervisor do
    children =
      [
        {Registry, keys: :unique, name: SpectreMnemonic.Engine.Registry},
        {Registry, keys: :unique, name: SpectreMnemonic.Engine.PartitionRegistry},
        {Registry, keys: :unique, name: SpectreMnemonic.Persistence.StoreWriter.Registry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: SpectreMnemonic.Persistence.StoreWriter.Supervisor},
        {Task.Supervisor, name: SpectreMnemonic.SharedTaskSupervisor},
        SpectreMnemonic.Embedding.ModelCache
      ] ++ default_engine_children()

    Supervisor.start_link(children, strategy: :rest_for_one, name: SpectreMnemonic.Supervisor)
  end

  @spec default_engine_children :: [Supervisor.child_spec() | {module(), keyword()}]
  defp default_engine_children do
    case Config.default_engine_opts() do
      nil -> []
      opts -> [{SpectreMnemonic.Engine, opts}]
    end
  end
end
