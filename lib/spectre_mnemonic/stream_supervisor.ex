defmodule SpectreMnemonic.StreamSupervisor do
  @moduledoc "Dynamic supervisor for per-stream worker processes."

  use DynamicSupervisor

  @doc "Starts the stream supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Ensures a stream server exists for a stream name."
  @spec ensure_stream(stream :: term()) :: DynamicSupervisor.on_start_child()
  def ensure_stream(stream) do
    spec = {SpectreMnemonic.StreamServer, stream}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @impl true
  @spec init(:ok) :: DynamicSupervisor.on_start()
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
