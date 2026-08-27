defmodule SpectreMnemonic.Persistence.RepairQueue do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.RepairJob
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Telemetry

  @registry SpectreMnemonic.Engine.Registry

  @doc false
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  @doc false
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.ref},
      start: {__MODULE__, :start_link, [config]}
    }
  end

  @doc false
  @spec enqueue(RepairJob.t()) :: :ok
  def enqueue(%RepairJob{} = job) do
    cast_for_storage(Map.get(job.record, :storage_id), {:enqueue, job})
  end

  @doc false
  @spec delivered(binary(), binary(), term()) :: :ok
  def delivered(storage_id, commit_id, target),
    do: cast_for_storage(storage_id, {:delivered, commit_id, target})

  @doc false
  @spec failed(binary(), binary(), term(), term()) :: :ok
  def failed(storage_id, commit_id, target, reason),
    do: cast_for_storage(storage_id, {:failed, commit_id, target, reason})

  @doc false
  @spec restore(Config.t()) :: :ok
  def restore(%Config{} = config), do: cast(config.ref, :restore)

  @doc false
  @spec jobs :: [RepairJob.t()]
  def jobs do
    queue_pids()
    |> Enum.flat_map(&safe_call(&1, :jobs, []))
    |> Enum.sort_by(& &1.id)
  end

  @doc false
  @spec summary :: map()
  def summary do
    jobs = jobs()

    %{
      total: length(jobs),
      pending: Enum.count(jobs, &(&1.status in [:pending, :retrying])),
      completed: Enum.count(jobs, &(&1.status == :completed))
    }
  end

  @doc false
  @spec summary(binary()) :: map()
  def summary(storage_id) when is_binary(storage_id) do
    jobs =
      case server_for_storage(storage_id) do
        {:ok, pid} -> safe_call(pid, :jobs, [])
        {:error, _reason} -> []
      end

    %{
      total: length(jobs),
      pending: Enum.count(jobs, &(&1.status in [:pending, :retrying])),
      completed: Enum.count(jobs, &(&1.status == :completed))
    }
  end

  @doc false
  @spec reset :: :ok
  def reset do
    Enum.each(queue_pids(), &safe_call(&1, :reset, :ok))
    :ok
  end

  @impl GenServer
  def init(%Config{} = config) do
    case Registry.register(@registry, {:repair_queue, config.ref}, nil) do
      {:ok, _owner} ->
        send(self(), :restore)

        repair_opts =
          config.persistent_memory
          |> Keyword.get(:repair, [])
          |> normalize_opts()

        {:ok,
         %{
           config: config,
           jobs: %{},
           max_attempts: positive(Keyword.get(repair_opts, :max_attempts), 8),
           base_backoff: positive(Keyword.get(repair_opts, :base_backoff), 100)
         }}

      {:error, {:already_registered, pid}} ->
        {:stop, {:repair_queue_already_started, config.ref, pid}}
    end
  end

  @impl GenServer
  def handle_cast({:enqueue, job}, state) do
    key = key(job.commit_id, job.target_store)
    {:noreply, put_in(state, [:jobs, key], job)}
  end

  def handle_cast({:delivered, commit_id, target}, state) do
    {:noreply, update_job(state, commit_id, target, &complete/1)}
  end

  def handle_cast({:failed, commit_id, target, reason}, state) do
    state = update_job(state, commit_id, target, &mark_failed(&1, reason))
    schedule_retry(state, commit_id, target)
    {:noreply, state}
  end

  def handle_cast(:restore, state), do: {:noreply, restore_config(state)}

  @impl GenServer
  def handle_call(:jobs, _from, state) do
    jobs = state.jobs |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, jobs, state}
  end

  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | jobs: %{}}}

  @impl GenServer
  def handle_info(:restore, state), do: {:noreply, restore_config(state)}

  def handle_info({:retry, commit_id, target}, state) do
    case Map.get(state.jobs, key(commit_id, target)) do
      %RepairJob{status: :completed} ->
        {:noreply, state}

      %RepairJob{} = job ->
        {result, job} = attempt(job)
        state = put_in(state, [:jobs, key(commit_id, target)], job)

        case result do
          :ok -> :ok
          {:error, _reason} -> schedule_retry(state, commit_id, target)
        end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  @spec attempt(RepairJob.t()) :: {:ok | {:error, term()}, RepairJob.t()}
  defp attempt(job) do
    started_at = System.monotonic_time()
    result = safe_put(job.store, job.record)
    now = DateTime.utc_now()

    Telemetry.emit(
      [:repair, :attempt],
      %{duration: System.monotonic_time() - started_at},
      %{
        target_store: job.target_store,
        outcome: if(result == :ok, do: :ok, else: :error),
        attempt: job.attempts + 1
      }
    )

    case result do
      :ok ->
        {:ok,
         %{job | status: :completed, attempts: job.attempts + 1, updated_at: now, last_error: nil}}

      {:error, reason} ->
        {{:error, reason},
         %{
           job
           | status: :pending,
             attempts: job.attempts + 1,
             updated_at: now,
             last_error: reason
         }}
    end
  end

  @spec safe_put(map(), SpectreMnemonic.Persistence.Store.Record.t()) ::
          :ok | {:error, term()}
  defp safe_put(store, record) do
    case store.adapter.put(record, store.opts) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_adapter_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec update_job(map(), binary(), term(), (RepairJob.t() -> RepairJob.t())) :: map()
  defp update_job(state, commit_id, target, fun) do
    update_in(state, [:jobs, key(commit_id, target)], fn
      %RepairJob{} = job -> fun.(job)
      nil -> nil
    end)
  end

  @spec complete(RepairJob.t()) :: RepairJob.t()
  defp complete(job),
    do: %{job | status: :completed, updated_at: DateTime.utc_now(), last_error: nil}

  @spec mark_failed(RepairJob.t(), term()) :: RepairJob.t()
  defp mark_failed(job, reason),
    do: %{job | status: :pending, updated_at: DateTime.utc_now(), last_error: reason}

  @spec schedule_retry(map(), binary(), term()) :: reference() | nil
  defp schedule_retry(state, commit_id, target) do
    case Map.get(state.jobs, key(commit_id, target)) do
      %RepairJob{status: :pending, attempts: attempts} when attempts < state.max_attempts ->
        delay = min(state.base_backoff * Integer.pow(2, attempts), 60_000)
        Process.send_after(self(), {:retry, commit_id, target}, delay)

      _completed_or_exhausted ->
        nil
    end
  end

  @spec restore_config(map()) :: map()
  defp restore_config(%{config: config} = state) do
    stores = normalized_stores(config.persistent_memory)

    config
    |> replay_options()
    |> Manager.replay_all()
    |> case do
      {:ok, records} ->
        records
        |> Enum.filter(&repair_record?(&1, config.storage_id))
        |> Enum.reduce(state, &restore_record(&1, &2, stores))

      {:error, _reason} ->
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec restore_record(Record.t(), map(), map()) :: map()
  defp restore_record(%Record{payload: payload}, state, stores) do
    target = Map.get(payload, :target_store)
    stored_record = Map.get(payload, :record)

    case {stored_record, Map.get(stores, target)} do
      {%Record{} = record, store} when is_map(store) ->
        commit_id = Map.get(payload, :commit_id) || record.commit_id
        job_key = key(commit_id, target)

        job = %RepairJob{
          id: Map.get(payload, :id, "repair:#{commit_id}:#{target}"),
          commit_id: commit_id,
          target_store: target,
          attempts: Map.get(payload, :attempts, 0),
          status: :pending,
          inserted_at: Map.get(payload, :inserted_at, DateTime.utc_now()),
          updated_at: DateTime.utc_now(),
          record: Record.upgrade(record),
          store: store
        }

        if Map.has_key?(state.jobs, job_key) do
          state
        else
          send(self(), {:retry, commit_id, target})
          put_in(state, [:jobs, job_key], job)
        end

      _legacy_or_missing_store ->
        state
    end
  end

  @spec repair_record?(Record.t(), binary()) :: boolean()
  defp repair_record?(
         %Record{family: :repair_jobs, storage_id: storage_id, payload: payload},
         expected
       ),
       do: storage_id == expected and is_map(payload)

  defp repair_record?(_record, _storage_id), do: false

  @spec replay_options(Config.t()) :: keyword()
  defp replay_options(config) do
    [
      engine_ref: config.ref,
      engine_internal?: true,
      namespace: config.internal_namespace,
      storage_id: config.storage_id,
      data_root: config.data_root,
      persistent_memory: config.persistent_memory
    ]
  end

  @spec normalized_stores(keyword()) :: map()
  defp normalized_stores(config) do
    config
    |> Keyword.get(:stores, [])
    |> Enum.map(&normalize_store/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.id, &1})
  end

  @spec normalize_store(keyword() | map()) :: map() | nil
  defp normalize_store(store) when is_map(store), do: normalize_store(Map.to_list(store))

  defp normalize_store(store) when is_list(store) do
    if Keyword.keyword?(store) do
      %{
        id: Keyword.get(store, :id),
        adapter: Keyword.get(store, :adapter),
        role: Keyword.get(store, :role, :replica),
        opts: normalize_opts(Keyword.get(store, :opts, []))
      }
    end
  end

  defp normalize_store(_store), do: nil

  @spec normalize_opts(term()) :: keyword()
  defp normalize_opts(opts) when is_list(opts), do: if(Keyword.keyword?(opts), do: opts, else: [])
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(_opts), do: []

  @spec cast(Ref.t(), term()) :: :ok
  defp cast(%Ref{} = ref, message) do
    case Registry.lookup(@registry, {:repair_queue, ref}) do
      [{pid, _value}] -> GenServer.cast(pid, message)
      [] -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @spec cast_for_storage(term(), term()) :: :ok
  defp cast_for_storage(storage_id, message) do
    case server_for_storage(storage_id) do
      {:ok, pid} -> GenServer.cast(pid, message)
      {:error, _reason} -> :ok
    end
  end

  @spec server_for_storage(term()) :: {:ok, pid()} | {:error, term()}
  defp server_for_storage(storage_id) when is_binary(storage_id) do
    with {:ok, runtime} <- Engine.resolve_storage_id(storage_id),
         [{pid, _value}] <- Registry.lookup(@registry, {:repair_queue, runtime.config.ref}) do
      {:ok, pid}
    else
      _missing -> {:error, :repair_queue_unavailable}
    end
  rescue
    ArgumentError -> {:error, :repair_queue_unavailable}
  end

  defp server_for_storage(_storage_id), do: {:error, :repair_queue_unavailable}

  @spec queue_pids :: [pid()]
  defp queue_pids do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {{:repair_queue, %Ref{}}, pid} -> [pid]
      _other -> []
    end)
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  @spec safe_call(pid(), term(), result) :: result when result: term()
  defp safe_call(pid, request, fallback) do
    GenServer.call(pid, request)
  catch
    :exit, _reason -> fallback
  end

  @spec key(binary(), term()) :: tuple()
  defp key(commit_id, target), do: {commit_id, target}

  @spec positive(term(), pos_integer()) :: pos_integer()
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
