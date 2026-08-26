defmodule SpectreMnemonic.Engine.RuntimeOwner do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Engine.Runtime

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  @spec runtime(pid()) :: Runtime.t()
  def runtime(owner), do: GenServer.call(owner, :runtime)

  @impl GenServer
  def init(opts) do
    runtime = %Runtime{
      config: Keyword.fetch!(opts, :config),
      engine_pid: Keyword.fetch!(opts, :engine_pid),
      owner: self()
    }

    registry = Keyword.fetch!(opts, :registry)

    with :ok <- register(registry, runtime.config.ref, runtime),
         :ok <- register(registry, {:storage_id, runtime.config.storage_id}, runtime),
         :ok <- register(registry, {:namespace, runtime.config.internal_namespace}, runtime),
         :ok <- register(registry, {:pid, runtime.engine_pid}, runtime) do
      {:ok, runtime}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:runtime, _from, runtime), do: {:reply, runtime, runtime}

  @spec register(atom(), term(), Runtime.t()) :: :ok | {:error, term()}
  defp register(registry, key, runtime) do
    case Registry.register(registry, key, runtime) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, pid}} ->
        {:error, {:mnemonic_engine_already_started, key, pid}}
    end
  end
end
