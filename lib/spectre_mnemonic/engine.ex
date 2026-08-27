defmodule SpectreMnemonic.Engine do
  @moduledoc """
  Supervised, single-node memory-engine identity and configuration boundary.

  Multiple Engines may coexist in one VM. A `storage_id` may be active only
  once in that VM, and a deployment must guarantee that the same storage is not
  written concurrently from another node.
  """

  use Supervisor

  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.HotStore
  alias SpectreMnemonic.Engine.MaintenanceScheduler
  alias SpectreMnemonic.Engine.PartitionExecutor
  alias SpectreMnemonic.Engine.PartitionSupervisor
  alias SpectreMnemonic.Engine.Projection
  alias SpectreMnemonic.Engine.ProjectionSupervisor
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Engine.Runtime
  alias SpectreMnemonic.Engine.RuntimeOwner
  alias SpectreMnemonic.Engine.StoreSupervisor
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Knowledge.Projection, as: KnowledgeProjection
  alias SpectreMnemonic.Persistence.PrimaryWriter
  alias SpectreMnemonic.Persistence.RepairQueue
  alias SpectreMnemonic.Persistence.Runtime, as: PersistenceRuntime
  alias SpectreMnemonic.Persistence.Store.Adapter, as: StoreAdapter
  alias SpectreMnemonic.Recall.Index, as: RecallIndex

  @registry SpectreMnemonic.Engine.Registry

  @doc "Starts one independently addressed Engine."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    with {:ok, config} <- Config.new(opts),
         :ok <- ensure_available(config) do
      Supervisor.start_link(__MODULE__, config, name: config.name)
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :ref) || Keyword.get(opts, :storage_id) || Keyword.get(opts, :name)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Resolves a PID, registered name, via tuple, or `%Engine.Ref{}`."
  @spec resolve(pid() | atom() | {:via, module(), term()} | Ref.t()) ::
          {:ok, Runtime.t()} | {:error, term()}
  def resolve(%Ref{} = ref), do: registry_lookup(ref)

  def resolve(pid) when is_pid(pid), do: registry_lookup({:pid, pid})

  def resolve(name) when is_atom(name) and not is_nil(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> resolve(pid)
      nil -> missing_engine(name)
    end
  end

  def resolve({:via, module, _term} = name) when is_atom(module) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> resolve(pid)
      nil -> missing_engine(name)
    end
  end

  def resolve(reference), do: {:error, {:invalid_mnemonic_engine, reference}}

  @doc false
  @spec runtime(Ref.t()) :: {:ok, Runtime.t()} | {:error, term()}
  def runtime(ref), do: resolve(ref)

  @doc false
  @spec resolve_internal_namespace(term()) :: {:ok, Runtime.t()} | {:error, term()}
  def resolve_internal_namespace(namespace) when is_binary(namespace),
    do: registry_lookup({:namespace, namespace})

  def resolve_internal_namespace(namespace),
    do: {:error, {:mnemonic_engine_not_found, {:namespace, namespace}}}

  @doc false
  @spec resolve_storage_id(term()) :: {:ok, Runtime.t()} | {:error, term()}
  def resolve_storage_id(storage_id) when is_binary(storage_id),
    do: registry_lookup({:storage_id, storage_id})

  def resolve_storage_id(storage_id),
    do: {:error, {:mnemonic_engine_not_found, {:storage_id, storage_id}}}

  @doc false
  @spec internal_namespace?(term()) :: boolean()
  def internal_namespace?(namespace) when is_binary(namespace) do
    match?([_entry], Registry.lookup(@registry, {:namespace, namespace}))
  rescue
    ArgumentError -> false
  end

  def internal_namespace?(_namespace), do: false

  @doc "Returns content-free runtime health and bounded queue diagnostics."
  @spec health(pid() | atom() | {:via, module(), term()} | Ref.t()) ::
          {:ok, map()} | {:error, term()}
  def health(reference) do
    with {:ok, runtime} <- resolve(reference) do
      config = runtime.config
      projection = Projection.status(runtime)
      writer = PrimaryWriter.status(config.ref)
      partitions = PartitionExecutor.status(config.ref)
      repairs = RepairQueue.summary(config.storage_id)
      durable = DurableIndex.status(config.internal_namespace)
      knowledge = KnowledgeProjection.status(runtime)
      persistence = PersistenceRuntime.status(config.ref)
      scheduler = scheduler_status(runtime)
      stores = store_health(config.persistent_memory)

      degraded =
        []
        |> maybe_degraded(:projection, not projection.healthy?)
        |> maybe_degraded(:primary_writer, not writer.running?)
        |> maybe_degraded(:durable_index, not durable.running?)
        |> maybe_degraded(:knowledge_projection, not knowledge.running?)
        |> maybe_degraded(:persistence_runtime, not persistence.running?)
        |> maybe_degraded(
          :stores,
          Enum.any?(stores, fn {_id, status} -> status.status != :ok end)
        )

      {:ok,
       %{
         engine: config.ref,
         storage_id: config.storage_id,
         running?: Process.alive?(runtime.engine_pid),
         queues: %{partition: partitions, store: writer},
         projection: projection,
         stores: stores,
         repair_jobs: repairs,
         durable_index: durable,
         knowledge_projection: knowledge,
         persistence: persistence,
         compaction: %{status: persistence.operation},
         scheduler: scheduler,
         degraded_sources: Enum.reverse(degraded)
       }}
    end
  end

  @impl Supervisor
  def init(%Config{} = config) do
    children = [
      {RuntimeOwner, config: config, engine_pid: self(), registry: @registry},
      {HotStore, config},
      {PartitionSupervisor, config},
      {StoreSupervisor, config},
      {ProjectionSupervisor, config},
      {KnowledgeProjection, config},
      {PersistenceRuntime, config},
      {RepairQueue, config},
      {PrimaryWriter, config},
      {Governance, config},
      {DurableIndex, config},
      {RecallIndex, config},
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name(config.ref)},
        id: {Task.Supervisor, config.ref}
      ),
      {MaintenanceScheduler, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec ensure_available(Config.t()) :: :ok | {:error, term()}
  defp ensure_available(config) do
    [config.ref, {:storage_id, config.storage_id}]
    |> Enum.find_value(:ok, fn key ->
      case Registry.lookup(@registry, key) do
        [{pid, _runtime}] -> {:error, {:mnemonic_engine_already_started, key, pid}}
        [] -> false
      end
    end)
  rescue
    ArgumentError -> {:error, :mnemonic_engine_registry_unavailable}
  end

  @spec registry_lookup(term()) :: {:ok, Runtime.t()} | {:error, term()}
  defp registry_lookup(key) do
    case Registry.lookup(@registry, key) do
      [{_pid, %Runtime{} = runtime}] -> {:ok, runtime}
      [] -> missing_engine(key)
    end
  rescue
    ArgumentError -> missing_engine(key)
  end

  @spec missing_engine(term()) :: {:error, term()}
  defp missing_engine(SpectreMnemonic.DefaultEngine), do: {:error, :mnemonic_engine_required}
  defp missing_engine(reference), do: {:error, {:mnemonic_engine_not_found, reference}}

  @spec store_health(keyword()) :: map()
  defp store_health(config) do
    config
    |> Keyword.get(:stores, [])
    |> Enum.map(fn store ->
      store = if is_map(store), do: Map.to_list(store), else: store
      id = Keyword.get(store, :id, :unknown)
      adapter = Keyword.get(store, :adapter)
      opts = Keyword.get(store, :opts, [])

      {id,
       %{
         status: adapter_health(adapter, opts),
         role: Keyword.get(store, :role),
         contract: adapter_conformance(adapter, opts)
       }}
    end)
    |> Map.new()
  end

  @spec adapter_health(term(), term()) :: :ok | {:error, term()}
  defp adapter_health(adapter, opts) when is_atom(adapter) and is_list(opts) do
    cond do
      not Code.ensure_loaded?(adapter) ->
        {:error, :adapter_unavailable}

      function_exported?(adapter, :health, 1) ->
        case adapter.health(opts) do
          {:ok, _diagnostics} -> :ok
          {:error, reason} -> {:error, safe_health_reason(reason)}
          _unexpected -> {:error, :invalid_health_result}
        end

      function_exported?(adapter, :capabilities, 1) ->
        :ok

      true ->
        {:error, :adapter_unavailable}
    end
  rescue
    _exception -> {:error, :health_check_failed}
  catch
    _kind, _reason -> {:error, :health_check_failed}
  end

  defp adapter_health(_adapter, _opts), do: {:error, :adapter_unavailable}

  defp safe_health_reason(reason) when is_atom(reason) or is_number(reason), do: reason

  defp safe_health_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp safe_health_reason(reason) when is_exception(reason), do: reason.__struct__
  defp safe_health_reason(_reason), do: :redacted

  @spec adapter_conformance(term(), term()) :: :conformant | :legacy | :placeholder | :invalid
  defp adapter_conformance(adapter, opts) when is_atom(adapter) and is_list(opts) do
    case StoreAdapter.describe(adapter, opts) do
      {:ok, %{placeholder?: true}} -> :placeholder
      {:ok, %{conformant?: true}} -> :conformant
      {:ok, _contract} -> :legacy
      {:error, _reason} -> :invalid
    end
  end

  defp adapter_conformance(_adapter, _opts), do: :invalid

  @spec scheduler_status(Runtime.t()) :: map()
  defp scheduler_status(runtime) do
    status = MaintenanceScheduler.status(runtime.config.ref)
    interval = Map.get(status, :interval_ms)
    last_run = Map.get(status, :last_run_at)

    lag_ms =
      case {last_run, interval} do
        {%DateTime{} = timestamp, value} when is_integer(value) ->
          max(DateTime.diff(DateTime.utc_now(), timestamp, :millisecond) - value, 0)

        _missing ->
          nil
      end

    status
    |> Map.take([:running?, :enabled?, :interval_ms, :runs, :last_run_at])
    |> Map.put(:lag_ms, lag_ms)
  end

  @spec task_supervisor_name(Ref.t()) :: GenServer.name()
  defp task_supervisor_name(ref),
    do: {:via, Registry, {@registry, {:engine_task_supervisor, ref}}}

  @spec maybe_degraded([atom()], atom(), boolean()) :: [atom()]
  defp maybe_degraded(sources, source, true), do: [source | sources]
  defp maybe_degraded(sources, _source, false), do: sources
end
