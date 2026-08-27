defmodule SpectreMnemonic.Persistence.PrimaryWriter do
  @moduledoc false

  use GenServer

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Runtime, as: PersistenceRuntime

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
  @spec call(Ref.t(), term(), timeout(), keyword()) :: term()
  def call(%Ref{} = ref, request, timeout, opts) do
    case Registry.lookup(@registry, {:primary_writer, ref}) do
      [{pid, registration}] -> admitted_call(pid, registration, request, timeout, opts)
      [] -> {:error, :mnemonic_engine_required}
    end
  rescue
    ArgumentError -> {:error, :mnemonic_engine_required}
  end

  @doc false
  @spec reset_all :: :ok
  def reset_all do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn
      {{:primary_writer, _ref}, pid} -> safe_reset(pid)
      _other -> :ok
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec status(Ref.t()) :: map()
  def status(%Ref{} = ref) do
    case Registry.lookup(@registry, {:primary_writer, ref}) do
      [{pid, registration}] ->
        admitted = :atomics.get(registration.admission, 1)

        %{
          running?: Process.alive?(pid),
          in_flight: min(admitted, 1),
          queue_depth: max(admitted - 1, 0),
          queue_limit: registration.max_queue
        }

      [] ->
        %{running?: false, in_flight: 0, queue_depth: 0, queue_limit: 0}
    end
  rescue
    ArgumentError -> %{running?: false, in_flight: 0, queue_depth: 0, queue_limit: 0}
  end

  @impl GenServer
  def init(%Config{} = config) do
    max_queue = config.limits.max_store_queue
    admission = :atomics.new(1, signed: false)
    registration = %{admission: admission, max_queue: max_queue}

    with :ok <- ETS.attach(config.ref),
         {:ok, _owner} <-
           Registry.register(@registry, {:primary_writer, config.ref}, registration) do
      {:ok,
       %{
         config: config,
         admission: admission,
         manager: Manager.empty_state()
       }}
    else
      {:error, {:already_registered, pid}} ->
        {:stop, {:primary_writer_already_started, config.ref, pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:execute, request}, _from, state) do
    {reply, manager} = Manager.execute_write(request, state.manager)
    if match?({:ok, _value}, reply), do: PersistenceRuntime.invalidate(state.config.ref)
    {:reply, reply, %{state | manager: manager}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | manager: Manager.reset_state(state.manager)}}
  end

  @spec admitted_call(pid(), map(), term(), timeout(), keyword()) :: term()
  defp admitted_call(pid, registration, request, timeout, opts) do
    admission = registration.admission
    requested = requested_capacity(opts, registration.max_queue)
    capacity = min(requested, registration.max_queue) + 1

    if :atomics.add_get(admission, 1, 1) > capacity do
      release(admission)
      {:error, {:queue_full, :store}}
    else
      try do
        GenServer.call(pid, {:execute, request}, timeout)
      catch
        :exit, {:timeout, _call} ->
          Process.exit(pid, :kill)
          {:error, :mnemonic_store_deadline_exceeded}

        :exit, reason ->
          {:error, {:primary_writer_crashed, reason}}
      after
        release(admission)
      end
    end
  rescue
    ArgumentError -> {:error, :mnemonic_busy}
  end

  @spec requested_capacity(keyword(), pos_integer()) :: pos_integer()
  defp requested_capacity(opts, default) do
    case Keyword.get(opts, :max_store_queue, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  @spec safe_reset(pid()) :: :ok
  defp safe_reset(pid) do
    GenServer.call(pid, :reset)
  catch
    :exit, _reason -> :ok
  end

  @spec release(:atomics.atomics_ref()) :: :ok
  defp release(admission) do
    _value = :atomics.sub_get(admission, 1, 1)
    :ok
  end
end
