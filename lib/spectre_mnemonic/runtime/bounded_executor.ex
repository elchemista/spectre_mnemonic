defmodule SpectreMnemonic.Runtime.BoundedExecutor do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Telemetry

  @type kind :: :partition | :store
  @type executor_opts :: [
          key: term(),
          kind: kind(),
          registry: atom(),
          max_queue: pos_integer(),
          idle_timeout: pos_integer()
        ]

  @doc false
  @spec start_link(executor_opts()) :: GenServer.on_start()
  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    registry = Keyword.fetch!(opts, :registry)
    max_queue = positive(Keyword.get(opts, :max_queue), 128)
    admission = :atomics.new(1, signed: false)
    value = %{admission: admission, max_queue: max_queue}
    name = {:via, Registry, {registry, key, value}}

    GenServer.start_link(__MODULE__, Keyword.put(opts, :admission, admission), name: name)
  end

  @doc false
  @spec execute(pid(), map(), term(), (-> result), keyword()) :: result | {:error, term()}
        when result: term()
  def execute(pid, registration, key, fun, opts) when is_pid(pid) and is_function(fun, 0) do
    if current?(pid, key) do
      fun.()
    else
      do_execute(pid, registration, key, fun, opts)
    end
  end

  @doc false
  @spec current?(pid(), term()) :: boolean()
  def current?(pid, key), do: self() == pid and Process.get({__MODULE__, :key}) == key

  @impl GenServer
  def init(opts) do
    state = %{
      key: Keyword.fetch!(opts, :key),
      kind: Keyword.fetch!(opts, :kind),
      admission: Keyword.fetch!(opts, :admission),
      idle_timeout: positive(Keyword.get(opts, :idle_timeout), 60_000)
    }

    {:ok, state, state.idle_timeout}
  end

  @impl GenServer
  def handle_info({:execute, caller, ref, ticket, deadline, enqueued_at, fun}, state) do
    case :atomics.compare_exchange(ticket, 1, 0, 1) do
      :ok ->
        execute_admitted(caller, ref, ticket, deadline, enqueued_at, fun, state)

      _cancelled_or_invalid ->
        release(state.admission)
        {:noreply, state, state.idle_timeout}
    end
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state, state.idle_timeout}

  @spec do_execute(pid(), map(), term(), (-> result), keyword()) :: result | {:error, term()}
        when result: term()
  defp do_execute(pid, registration, key, fun, opts) do
    admission = Map.fetch!(registration, :admission)
    configured_max = Map.fetch!(registration, :max_queue)
    requested_max = positive(Keyword.get(opts, queue_option(key)), configured_max)
    capacity = min(configured_max, requested_max) + 1

    if :atomics.add_get(admission, 1, 1) > capacity do
      release(admission)
      {:error, {:queue_full, queue_kind(key)}}
    else
      send_request(pid, key, admission, fun, opts)
    end
  rescue
    ArgumentError -> {:error, :mnemonic_busy}
  end

  @spec send_request(pid(), term(), :atomics.atomics_ref(), (-> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  defp send_request(pid, key, _admission, fun, opts) do
    ref = make_ref()
    ticket = :atomics.new(1, signed: false)
    deadline = deadline(opts, queue_kind(key))
    enqueued_at = System.monotonic_time()
    monitor = Process.monitor(pid)
    send(pid, {:execute, self(), ref, ticket, deadline, enqueued_at, fun})

    await_result(pid, monitor, ref, ticket, deadline, queue_kind(key))
  end

  @spec await_result(pid(), reference(), reference(), :atomics.atomics_ref(), integer(), kind()) ::
          term()
  defp await_result(pid, monitor, ref, ticket, deadline, kind) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {executor_failure(kind), reason}}
    after
      timeout ->
        cancel_or_abort(pid, monitor, ref, ticket, kind)
    end
  end

  @spec cancel_or_abort(pid(), reference(), reference(), :atomics.atomics_ref(), kind()) ::
          {:error, term()}
  defp cancel_or_abort(pid, monitor, ref, ticket, kind) do
    case :atomics.compare_exchange(ticket, 1, 0, 2) do
      :ok ->
        Process.demonitor(monitor, [:flush])
        {:error, deadline_failure(kind)}

      1 ->
        Process.exit(pid, :kill)

        receive do
          {^ref, result} -> result
          {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, deadline_failure(kind)}
        after
          1_000 -> {:error, deadline_failure(kind)}
        end

      _completed ->
        receive do
          {^ref, result} -> result
          {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {executor_failure(kind), reason}}
        after
          10 ->
            Process.demonitor(monitor, [:flush])
            {:error, deadline_failure(kind)}
        end
    end
  end

  @spec execute_admitted(
          pid(),
          reference(),
          :atomics.atomics_ref(),
          integer(),
          integer(),
          (-> term()),
          map()
        ) ::
          {:noreply, map(), pos_integer()}
  defp execute_admitted(caller, ref, ticket, deadline, enqueued_at, fun, state) do
    watcher = start_watcher(self(), caller, ref, deadline)
    previous = Process.put({__MODULE__, :key}, state.key)

    Telemetry.emit(
      [state.kind, :wait],
      %{duration: System.monotonic_time() - enqueued_at},
      %{executor: state.kind}
    )

    result = run_fun(state.key, fun)

    restore_current_key(previous)
    :atomics.put(ticket, 1, 3)
    send(watcher, {:completed, self(), ref})
    release(state.admission)
    send(caller, {ref, result})
    {:noreply, state, state.idle_timeout}
  end

  @spec start_watcher(pid(), pid(), reference(), integer()) :: pid()
  defp start_watcher(executor, caller, request_ref, deadline) do
    spawn(fn ->
      caller_monitor = Process.monitor(caller)
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:completed, ^executor, ^request_ref} ->
          Process.demonitor(caller_monitor, [:flush])

        {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
          Process.exit(executor, :kill)
      after
        timeout -> Process.exit(executor, :kill)
      end
    end)
  end

  @spec deadline(keyword(), kind()) :: integer()
  defp deadline(opts, kind) do
    now = System.monotonic_time(:millisecond)

    case Keyword.get(opts, :deadline) do
      value when is_integer(value) -> value
      %DateTime{} = value -> now + max(DateTime.diff(value, DateTime.utc_now(), :millisecond), 0)
      _missing -> now + timeout(opts, kind)
    end
  end

  @spec timeout(keyword(), kind()) :: pos_integer()
  defp timeout(opts, :partition),
    do: positive(Keyword.get(opts, :partition_timeout, Keyword.get(opts, :timeout)), 60_000)

  defp timeout(opts, :store),
    do: positive(Keyword.get(opts, :store_timeout, Keyword.get(opts, :timeout)), 120_000)

  @spec queue_option(term()) :: atom()
  defp queue_option({:partition, _key}), do: :max_partition_queue
  defp queue_option({:store, _key}), do: :max_store_queue

  @spec queue_kind(term()) :: kind()
  defp queue_kind({kind, _key}) when kind in [:partition, :store], do: kind

  @spec executor_failure(kind()) :: atom()
  defp executor_failure(:partition), do: :partition_executor_crashed
  defp executor_failure(:store), do: :store_writer_crashed

  @spec deadline_failure(kind()) :: atom()
  defp deadline_failure(:partition), do: :mnemonic_deadline_exceeded
  defp deadline_failure(:store), do: :mnemonic_store_deadline_exceeded

  @spec restore_current_key(term()) :: term()
  defp restore_current_key(nil), do: Process.delete({__MODULE__, :key})
  defp restore_current_key(previous), do: Process.put({__MODULE__, :key}, previous)

  @spec run_fun(term(), (-> result)) :: result when result: term()
  defp run_fun(
         {:partition, {:memory_partition, %Ref{} = ref, _namespace, _scope}},
         fun
       ) do
    ETS.with_engine(ref, fun)
  end

  defp run_fun({:partition, {:memory_partition, :default, _namespace, _scope}}, fun) do
    ETS.with_engine(SpectreMnemonic.DefaultEngine, fun)
  end

  defp run_fun(_key, fun), do: fun.()

  @spec release(:atomics.atomics_ref()) :: :ok
  defp release(admission) do
    _remaining = :atomics.sub_get(admission, 1, 1)
    :ok
  end

  @spec positive(term(), pos_integer()) :: pos_integer()
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
