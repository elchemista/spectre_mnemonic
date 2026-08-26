defmodule SpectreMnemonic.Engine.ProjectionSupervisor do
  @moduledoc false

  use Supervisor

  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.ProjectionShard

  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(%Config{} = config), do: Supervisor.start_link(__MODULE__, config)

  @doc false
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.ref},
      start: {__MODULE__, :start_link, [config]},
      type: :supervisor
    }
  end

  @impl Supervisor
  def init(%Config{} = config) do
    children =
      for index <- 0..(config.projection_shards - 1) do
        {ProjectionShard, config: config, index: index}
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
