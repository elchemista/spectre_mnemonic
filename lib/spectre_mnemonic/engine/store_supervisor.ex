defmodule SpectreMnemonic.Engine.StoreSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias SpectreMnemonic.Engine.Config

  @registry SpectreMnemonic.Engine.Registry

  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(%Config{} = config), do: DynamicSupervisor.start_link(__MODULE__, config)

  @doc false
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.ref},
      start: {__MODULE__, :start_link, [config]},
      type: :supervisor
    }
  end

  @impl DynamicSupervisor
  def init(%Config{} = config) do
    case Registry.register(@registry, {:store_supervisor, config.ref}, nil) do
      {:ok, _owner} ->
        DynamicSupervisor.init(strategy: :one_for_one)

      {:error, {:already_registered, pid}} ->
        raise "store supervisor already started for #{inspect(config.ref)}: #{inspect(pid)}"
    end
  end
end
