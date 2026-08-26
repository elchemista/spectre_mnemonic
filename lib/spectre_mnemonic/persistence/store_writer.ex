defmodule SpectreMnemonic.Persistence.StoreWriter do
  @moduledoc false

  alias SpectreMnemonic.Runtime.BoundedExecutor

  @engine_registry SpectreMnemonic.Engine.Registry
  @registry SpectreMnemonic.Persistence.StoreWriter.Registry
  @fallback_supervisor SpectreMnemonic.Persistence.StoreWriter.Supervisor

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    key = Keyword.fetch!(opts, :key)

    %{
      id: {__MODULE__, key},
      start: {BoundedExecutor, :start_link, [Keyword.merge(defaults(), opts)]},
      restart: :temporary
    }
  end

  @doc "Runs the smallest physical store critical section with bounded admission."
  @spec trans(term(), (-> result), keyword()) :: result | {:error, term()} when result: term()
  def trans(key, fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    registry_key = {:store, key}

    with {:ok, pid, registration} <- executor(registry_key, opts) do
      BoundedExecutor.execute(pid, registration, registry_key, fun, opts)
    end
  end

  @spec executor(term(), keyword()) :: {:ok, pid(), map()} | {:error, :mnemonic_busy}
  defp executor(key, opts) do
    case Registry.lookup(@registry, key) do
      [{pid, registration}] ->
        {:ok, pid, registration}

      [] ->
        child_opts = defaults() |> Keyword.merge(opts) |> Keyword.put(:key, key)

        case DynamicSupervisor.start_child(supervisor(opts), {__MODULE__, child_opts}) do
          {:ok, _pid} -> lookup_started(key)
          {:error, {:already_started, _pid}} -> lookup_started(key)
          {:error, _reason} -> {:error, :mnemonic_busy}
        end
    end
  rescue
    ArgumentError -> {:error, :mnemonic_busy}
  end

  @spec supervisor(keyword()) :: pid() | atom()
  defp supervisor(opts) do
    with %SpectreMnemonic.Engine.Ref{} = ref <- Keyword.get(opts, :engine_ref),
         [{pid, _value}] <- Registry.lookup(@engine_registry, {:store_supervisor, ref}) do
      pid
    else
      _missing -> @fallback_supervisor
    end
  rescue
    ArgumentError -> @fallback_supervisor
  end

  @spec lookup_started(term()) :: {:ok, pid(), map()} | {:error, :mnemonic_busy}
  defp lookup_started(key) do
    case Registry.lookup(@registry, key) do
      [{pid, registration}] -> {:ok, pid, registration}
      [] -> {:error, :mnemonic_busy}
    end
  end

  @spec defaults :: keyword()
  defp defaults do
    [
      registry: @registry,
      kind: :store,
      max_queue: 256,
      idle_timeout: 60_000
    ]
  end
end
