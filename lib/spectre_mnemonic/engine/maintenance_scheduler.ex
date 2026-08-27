defmodule SpectreMnemonic.Engine.MaintenanceScheduler do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.ConsolidationScheduler
  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.MaintenanceRun
  alias SpectreMnemonic.Engine.Runtime
  alias SpectreMnemonic.Telemetry

  @registry SpectreMnemonic.Engine.Registry

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
  @spec status(term()) :: map()
  def status(reference) do
    case scheduler(reference) do
      {:ok, pid} -> GenServer.call(pid, :status)
      {:error, _reason} -> unavailable_status()
    end
  catch
    :exit, _reason -> unavailable_status()
  end

  @doc false
  @spec run_now(term()) :: map() | {:error, term()}
  def run_now(reference) do
    with {:ok, pid} <- scheduler(reference) do
      GenServer.call(pid, :run_now, :infinity)
    end
  catch
    :exit, reason -> {:error, {:scheduler_run_failed, reason}}
  end

  @doc false
  @spec configure(term(), term()) :: :ok | {:error, term()}
  def configure(reference, config) do
    with {:ok, pid} <- scheduler(reference) do
      GenServer.call(pid, {:configure, config})
    end
  catch
    :exit, reason -> {:error, {:scheduler_configuration_failed, reason}}
  end

  @impl GenServer
  def init(%Config{} = config) do
    case Engine.resolve(config.ref) do
      {:ok, %Runtime{} = runtime} ->
        case Registry.register(@registry, {:maintenance_scheduler, config.ref}, nil) do
          {:ok, _owner} ->
            state = %{
              runtime: runtime,
              config: ConsolidationScheduler.normalize_config(config.scheduler),
              task: nil,
              deadline_timer: nil,
              tick_timer: nil,
              pending_tick?: false,
              waiter: nil,
              runs: 0,
              last_run_at: nil,
              last_result: nil
            }

            {:ok, schedule_tick(state)}

          {:error, {:already_registered, pid}} ->
            {:stop, {:maintenance_scheduler_already_started, config.ref, pid}}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call(:run_now, from, %{task: nil} = state) do
    {:noreply, start_run(%{state | waiter: from}, :manual)}
  end

  def handle_call(:run_now, _from, state) do
    {:reply, {:error, :mnemonic_busy}, state}
  end

  def handle_call({:configure, config}, _from, state) do
    state = cancel_tick(state)
    state = %{state | config: ConsolidationScheduler.normalize_config(config)}
    {:reply, :ok, schedule_tick(state)}
  end

  @impl GenServer
  def handle_info(:tick, %{task: nil} = state) do
    state = %{state | tick_timer: nil}
    {:noreply, state |> start_run(:scheduled) |> schedule_tick()}
  end

  def handle_info(:tick, state) do
    state = %{state | tick_timer: nil, pending_tick?: true}
    {:noreply, schedule_tick(state)}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_run(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    {:noreply, finish_run(state, {:error, {:maintenance_task_failed, reason}})}
  end

  def handle_info({:maintenance_deadline, ref}, %{task: %{ref: ref} = task} = state) do
    _result = Task.Supervisor.terminate_child(task_supervisor(state.runtime), task.pid)
    Process.demonitor(ref, [:flush])
    {:noreply, finish_run(state, {:error, :maintenance_deadline_exceeded})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec start_run(map(), :manual | :scheduled) :: map()
  defp start_run(state, trigger) do
    task =
      Task.Supervisor.async_nolink(task_supervisor(state.runtime), fn ->
        MaintenanceRun.run(state.runtime, state.config)
      end)

    deadline = Keyword.fetch!(state.config, :deadline_ms)
    timer = Process.send_after(self(), {:maintenance_deadline, task.ref}, deadline)

    task =
      task
      |> Map.put(:trigger, trigger)
      |> Map.put(:started_at, System.monotonic_time())

    %{state | task: task, deadline_timer: timer}
  end

  @spec finish_run(map(), term()) :: map()
  defp finish_run(state, result) do
    cancel_timer(state.deadline_timer)
    if state.waiter, do: GenServer.reply(state.waiter, result)

    Telemetry.emit(
      [:maintenance, :run],
      %{duration: System.monotonic_time() - state.task.started_at},
      %{
        engine_ref: state.runtime.config.ref,
        trigger: state.task.trigger,
        outcome: if(match?({:error, _reason}, result), do: :error, else: :ok)
      }
    )

    state = %{
      state
      | task: nil,
        deadline_timer: nil,
        waiter: nil,
        runs: state.runs + 1,
        last_run_at: DateTime.utc_now(),
        last_result: result
    }

    if state.pending_tick? do
      start_run(%{state | pending_tick?: false}, :scheduled)
    else
      state
    end
  end

  @spec schedule_tick(map()) :: map()
  defp schedule_tick(%{tick_timer: nil} = state) do
    if Keyword.get(state.config, :enabled, false) do
      timer = Process.send_after(self(), :tick, Keyword.fetch!(state.config, :interval_ms))
      %{state | tick_timer: timer}
    else
      state
    end
  end

  defp schedule_tick(state), do: state

  @spec cancel_tick(map()) :: map()
  defp cancel_tick(state) do
    cancel_timer(state.tick_timer)
    %{state | tick_timer: nil, pending_tick?: false}
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _result = Process.cancel_timer(timer)
    :ok
  end

  @spec scheduler(term()) :: {:ok, pid()} | {:error, term()}
  defp scheduler(reference) do
    with {:ok, runtime} <- Engine.resolve(reference) do
      case Registry.lookup(@registry, {:maintenance_scheduler, runtime.config.ref}) do
        [{pid, _value}] -> {:ok, pid}
        [] -> {:error, :scheduler_not_running}
      end
    end
  rescue
    ArgumentError -> {:error, :scheduler_not_running}
  end

  @spec task_supervisor(Runtime.t()) :: GenServer.name()
  defp task_supervisor(runtime),
    do: {:via, Registry, {@registry, {:engine_task_supervisor, runtime.config.ref}}}

  @spec status_map(map()) :: map()
  defp status_map(state) do
    %{
      running?: true,
      enabled?: Keyword.get(state.config, :enabled, false),
      interval_ms: Keyword.fetch!(state.config, :interval_ms),
      deadline_ms: Keyword.fetch!(state.config, :deadline_ms),
      run_active?: not is_nil(state.task),
      pending_tick?: state.pending_tick?,
      runs: state.runs,
      last_run_at: state.last_run_at,
      last_result: state.last_result
    }
  end

  @spec unavailable_status :: map()
  defp unavailable_status,
    do: %{running?: false, enabled?: false, run_active?: false, pending_tick?: false}
end
