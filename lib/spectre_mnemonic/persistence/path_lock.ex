defmodule SpectreMnemonic.Persistence.PathLock do
  @moduledoc false

  use GenServer

  @type key :: term()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs a storage operation under a node-local, owner-monitored path lock."
  @spec trans(key(), (-> result)) :: result | {:error, :path_lock_not_running} when result: term()
  def trans(key, fun) when is_function(fun, 0) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :path_lock_not_running}

      _pid ->
        :ok = GenServer.call(__MODULE__, {:acquire, key}, :infinity)

        try do
          fun.()
        after
          GenServer.call(__MODULE__, {:release, key}, :infinity)
        end
    end
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{locks: %{}, waiters: %{}, monitor_keys: %{}}}

  @impl GenServer
  def handle_call({:acquire, key}, {pid, _tag} = from, state) do
    case Map.get(state.locks, key) do
      nil ->
        {:reply, :ok, grant_lock(state, key, pid, 1)}

      %{owner: ^pid, depth: depth} = lock ->
        locks = Map.put(state.locks, key, %{lock | depth: depth + 1})
        {:reply, :ok, %{state | locks: locks}}

      _locked ->
        waiters =
          Map.update(state.waiters, key, :queue.in(from, :queue.new()), &:queue.in(from, &1))

        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_call({:release, key}, {pid, _tag}, state) do
    case Map.get(state.locks, key) do
      %{owner: ^pid, depth: depth} = lock when depth > 1 ->
        locks = Map.put(state.locks, key, %{lock | depth: depth - 1})
        {:reply, :ok, %{state | locks: locks}}

      %{owner: ^pid} ->
        {:reply, :ok, hand_off(state, key)}

      _not_owner ->
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitor_keys, monitor) do
      {nil, _monitor_keys} ->
        {:noreply, state}

      {key, monitor_keys} ->
        state = %{state | monitor_keys: monitor_keys}
        {:noreply, hand_off(state, key, false)}
    end
  end

  @spec grant_lock(map(), key(), pid(), pos_integer()) :: map()
  defp grant_lock(state, key, pid, depth) do
    monitor = Process.monitor(pid)
    lock = %{owner: pid, monitor: monitor, depth: depth}

    %{
      state
      | locks: Map.put(state.locks, key, lock),
        monitor_keys: Map.put(state.monitor_keys, monitor, key)
    }
  end

  @spec hand_off(map(), key(), boolean()) :: map()
  defp hand_off(state, key, demonitor? \\ true) do
    state = drop_lock(state, key, demonitor?)
    queue = Map.get(state.waiters, key, :queue.new())
    grant_next_waiter(state, key, queue)
  end

  @spec drop_lock(map(), key(), boolean()) :: map()
  defp drop_lock(state, key, demonitor?) do
    case Map.pop(state.locks, key) do
      {nil, _locks} ->
        state

      {%{monitor: monitor}, locks} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])
        %{state | locks: locks, monitor_keys: Map.delete(state.monitor_keys, monitor)}
    end
  end

  @spec grant_next_waiter(map(), key(), :queue.queue(GenServer.from())) :: map()
  defp grant_next_waiter(state, key, queue) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        %{state | waiters: Map.delete(state.waiters, key)}

      {{:value, {pid, _tag} = from}, remaining} ->
        if Process.alive?(pid) do
          GenServer.reply(from, :ok)

          state
          |> Map.put(:waiters, put_remaining_waiters(state.waiters, key, remaining))
          |> grant_lock(key, pid, 1)
        else
          grant_next_waiter(state, key, remaining)
        end
    end
  end

  @spec put_remaining_waiters(map(), key(), :queue.queue(GenServer.from())) :: map()
  defp put_remaining_waiters(waiters, key, remaining) do
    if :queue.is_empty(remaining),
      do: Map.delete(waiters, key),
      else: Map.put(waiters, key, remaining)
  end
end
