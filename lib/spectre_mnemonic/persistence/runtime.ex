defmodule SpectreMnemonic.Persistence.Runtime do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Persistence.Manager

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
  @spec call(Ref.t(), term(), timeout()) :: term()
  def call(%Ref{} = ref, request, timeout) do
    case Registry.lookup(@registry, {:persistence_runtime, ref}) do
      [{pid, _value}] when is_pid(pid) -> call_runtime(pid, request, timeout)
      [] -> {:error, :mnemonic_engine_required}
    end
  end

  @spec call_runtime(pid(), term(), timeout()) :: term()
  defp call_runtime(pid, request, timeout) do
    if Process.alive?(pid), do: GenServer.call(pid, request, timeout), else: engine_required()
  catch
    :exit, {:noproc, _call} -> engine_required()
    :exit, {:timeout, _call} -> {:error, {:persistent_memory_timeout, timeout}}
    :exit, reason -> {:error, {:persistent_memory_runtime_unavailable, reason}}
  end

  @spec engine_required :: {:error, :mnemonic_engine_required}
  defp engine_required, do: {:error, :mnemonic_engine_required}

  @doc false
  @spec invalidate(Ref.t()) :: :ok
  def invalidate(%Ref{} = ref) do
    case Registry.lookup(@registry, {:persistence_runtime, ref}) do
      [{pid, _value}] -> GenServer.cast(pid, :invalidate)
      [] -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec reset_all :: :ok
  def reset_all do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn
      {{:persistence_runtime, _ref}, pid} -> GenServer.cast(pid, :reset)
      _other -> :ok
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec status(Ref.t()) :: map()
  def status(%Ref{} = ref) do
    case Registry.lookup(@registry, {:persistence_runtime, ref}) do
      [{pid, registration}] ->
        code = :atomics.get(registration.operation, 1)
        started_at = :atomics.get(registration.operation, 2)

        %{
          running?: Process.alive?(pid),
          operation: operation_name(code),
          operation_started_at: if(started_at == 0, do: nil, else: started_at),
          queue_depth: message_queue_len(pid)
        }

      [] ->
        %{running?: false, operation: :unavailable, operation_started_at: nil, queue_depth: 0}
    end
  rescue
    ArgumentError ->
      %{running?: false, operation: :unavailable, operation_started_at: nil, queue_depth: 0}
  end

  @impl GenServer
  def init(%Config{} = config) do
    operation = :atomics.new(2, signed: true)
    registration = %{operation: operation}

    with :ok <- ETS.attach(config.ref),
         {:ok, _owner} <-
           Registry.register(@registry, {:persistence_runtime, config.ref}, registration) do
      {:ok, %{manager: Manager.empty_state(), operation: operation}}
    else
      {:error, {:already_registered, pid}} ->
        {:stop, {:persistence_runtime_already_started, config.ref, pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(request, _from, state) do
    set_operation(state.operation, request)

    {reply, manager} =
      try do
        Manager.execute_request(request, state.manager)
      after
        clear_operation(state.operation)
      end

    {:reply, reply, %{state | manager: manager}}
  end

  @impl GenServer
  def handle_cast(:invalidate, state),
    do: {:noreply, %{state | manager: Manager.invalidate_state(state.manager)}}

  def handle_cast(:reset, state),
    do: {:noreply, %{state | manager: Manager.reset_state(state.manager)}}

  @spec set_operation(:atomics.atomics_ref(), term()) :: :ok
  defp set_operation(operation, request) do
    :atomics.put(operation, 1, operation_code(request))
    :atomics.put(operation, 2, System.monotonic_time(:millisecond))
    :ok
  end

  @spec clear_operation(:atomics.atomics_ref()) :: :ok
  defp clear_operation(operation) do
    :atomics.put(operation, 1, 0)
    :atomics.put(operation, 2, 0)
    :ok
  end

  @spec operation_code(term()) :: non_neg_integer()
  defp operation_code({:compact, _opts}), do: 1
  defp operation_code({kind, _opts}) when kind in [:replay, :replay_all, :replay_fold], do: 2
  defp operation_code({:replay_fold, _opts, _acc, _fun}), do: 2
  defp operation_code({:get, _family, _id, _opts}), do: 3

  defp operation_code({kind, _opts}) when kind in [:ensure_erasure_supported, :evict_dedupe],
    do: 4

  defp operation_code({:verify_erased, _targets, _opts}), do: 4
  defp operation_code(_request), do: 5

  @spec operation_name(non_neg_integer()) :: atom()
  defp operation_name(0), do: :idle
  defp operation_name(1), do: :compaction
  defp operation_name(2), do: :replay
  defp operation_name(3), do: :lookup
  defp operation_name(4), do: :erasure
  defp operation_name(_other), do: :other

  @spec message_queue_len(pid()) :: non_neg_integer()
  defp message_queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> 0
    end
  end
end
