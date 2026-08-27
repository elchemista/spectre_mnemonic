defmodule SpectreMnemonic.Engine.PartitionExecutor do
  @moduledoc false

  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Runtime.BoundedExecutor

  @engine_registry SpectreMnemonic.Engine.Registry
  @registry SpectreMnemonic.Engine.PartitionRegistry

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

  @doc "Runs a mutation inside the bounded executor that owns a memory partition."
  @spec trans(term(), (-> result), keyword()) :: result | {:error, term()} when result: term()
  def trans(key, fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    execute({:partition, key}, fun, opts)
  end

  @doc false
  @spec key(keyword() | map()) :: tuple()
  def key(opts) when is_list(opts) do
    engine = Keyword.get(opts, :engine_ref, :default)
    {:memory_partition, engine, Identity.namespace!(opts), Scope.from_opts(opts)}
  end

  def key(record) when is_map(record) do
    engine =
      record
      |> Map.get(:metadata, %{})
      |> then(fn metadata ->
        if is_map(metadata), do: Map.get(metadata, :engine_ref, :default), else: :default
      end)

    {namespace, scope} = Scope.partition(record)
    {:memory_partition, engine, namespace, scope}
  end

  @doc false
  @spec status(term()) :: map()
  def status(engine_ref) do
    executors =
      @registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.filter(fn
        {{:partition, {:memory_partition, ^engine_ref, _namespace, _scope}}, _pid, _value} -> true
        _entry -> false
      end)

    {queue_depth, queue_limit} =
      Enum.reduce(executors, {0, 0}, fn {_key, _pid, registration}, {depth, limit} ->
        admitted = :atomics.get(registration.admission, 1)
        {depth + max(admitted - 1, 0), limit + registration.max_queue}
      end)

    %{executors: length(executors), queue_depth: queue_depth, queue_limit: queue_limit}
  rescue
    ArgumentError -> %{executors: 0, queue_depth: 0, queue_limit: 0}
  end

  @spec execute(term(), (-> result), keyword()) :: result | {:error, term()} when result: term()
  defp execute(registry_key, fun, opts) do
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
        start_executor(key, opts)
    end
  rescue
    ArgumentError -> {:error, :mnemonic_busy}
  end

  defp start_executor(key, opts) do
    with {:ok, supervisor} <- partition_supervisor(key) do
      child_opts = defaults() |> Keyword.merge(opts) |> Keyword.put(:key, key)
      start_child(supervisor, child_opts, key)
    end
  end

  defp start_child(supervisor, child_opts, key) do
    case DynamicSupervisor.start_child(supervisor, {__MODULE__, child_opts}) do
      {:ok, _pid} -> lookup_started(key)
      {:error, {:already_started, _pid}} -> lookup_started(key)
      {:error, _reason} -> {:error, :mnemonic_busy}
    end
  end

  @spec lookup_started(term()) :: {:ok, pid(), map()} | {:error, :mnemonic_busy}
  defp lookup_started(key) do
    case Registry.lookup(@registry, key) do
      [{pid, registration}] -> {:ok, pid, registration}
      [] -> {:error, :mnemonic_busy}
    end
  end

  @spec partition_supervisor(term()) :: {:ok, pid()} | {:error, :mnemonic_busy}
  defp partition_supervisor({:partition, {:memory_partition, engine_ref, _namespace, _scope}}) do
    with {:ok, ref} <- normalize_engine_ref(engine_ref),
         [{pid, _value}] <- Registry.lookup(@engine_registry, {:partition_supervisor, ref}) do
      {:ok, pid}
    else
      _missing -> {:error, :mnemonic_busy}
    end
  rescue
    ArgumentError -> {:error, :mnemonic_busy}
  end

  defp partition_supervisor(_key), do: {:error, :mnemonic_busy}

  @spec normalize_engine_ref(term()) :: {:ok, term()} | {:error, :mnemonic_busy}
  defp normalize_engine_ref(:default) do
    case SpectreMnemonic.Engine.resolve(SpectreMnemonic.DefaultEngine) do
      {:ok, runtime} -> {:ok, runtime.config.ref}
      {:error, _reason} -> {:error, :mnemonic_busy}
    end
  end

  defp normalize_engine_ref(ref), do: {:ok, ref}

  @spec defaults :: keyword()
  defp defaults do
    [
      registry: @registry,
      kind: :partition,
      max_queue: 128,
      idle_timeout: 60_000
    ]
  end
end
