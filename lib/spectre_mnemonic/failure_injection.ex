defmodule SpectreMnemonic.FailureInjection do
  @moduledoc false

  alias SpectreMnemonic.FailureInjection.Injector

  @type point :: atom() | tuple()
  @type context :: map()
  @type action ::
          :ok
          | :pass
          | {:error, term()}
          | {:return, term()}
          | {:raise, Exception.t() | module() | binary()}
          | {:exit, term()}

  @doc false
  @spec checkpoint(point(), keyword(), context()) :: term()
  def checkpoint(point, opts, context \\ %{}) when is_list(opts) and is_map(context) do
    opts
    |> Keyword.get(:failure_injector)
    |> dispatch(point, context)
    |> apply_action(point)
  end

  @spec dispatch(term(), point(), context()) :: action() | term()
  defp dispatch(nil, _point, _context), do: :ok

  defp dispatch(%Injector{server: server}, point, context),
    do: Injector.checkpoint(server, point, context)

  defp dispatch(server, point, context) when is_pid(server) or is_atom(server),
    do: Injector.checkpoint(server, point, context)

  defp dispatch(fun, point, context) when is_function(fun, 2), do: fun.(point, context)
  defp dispatch(fun, point, _context) when is_function(fun, 1), do: fun.(point)

  defp dispatch({module, state}, point, context) when is_atom(module),
    do: module.checkpoint(point, context, state)

  defp dispatch(invalid, _point, _context),
    do: {:error, {:invalid_failure_injector, invalid}}

  @spec apply_action(action() | term(), point()) :: term()
  defp apply_action(action, _point) when action in [:ok, :pass], do: :ok
  defp apply_action({:return, value}, _point), do: value
  defp apply_action({:error, _reason} = error, _point), do: error
  defp apply_action({:exit, reason}, _point), do: exit(reason)

  defp apply_action({:raise, exception}, _point) when is_exception(exception),
    do: raise(exception)

  defp apply_action({:raise, module}, _point) when is_atom(module), do: raise(module)
  defp apply_action({:raise, message}, _point) when is_binary(message), do: raise(message)

  defp apply_action(invalid, point),
    do: {:error, {:invalid_failure_injection_action, point, invalid}}
end

defmodule SpectreMnemonic.FailureInjection.Injector do
  @moduledoc false

  use GenServer

  @enforce_keys [:server]
  defstruct [:server]

  @type t :: %__MODULE__{server: GenServer.server()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {genserver_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc false
  @spec new(GenServer.server()) :: t()
  def new(server), do: %__MODULE__{server: server}

  @doc false
  @spec checkpoint(GenServer.server(), SpectreMnemonic.FailureInjection.point(), map()) :: term()
  def checkpoint(server, point, context \\ %{}) do
    GenServer.call(server, {:checkpoint, point, context})
  end

  @doc false
  @spec history(GenServer.server()) :: [map()]
  def history(server), do: GenServer.call(server, :history)

  @impl GenServer
  def init(opts) do
    script = opts |> Keyword.get(:script, []) |> normalize_script()
    {:ok, %{script: script, history: []}}
  end

  @impl GenServer
  def handle_call({:checkpoint, point, context}, _from, state) do
    {action, script} = pop_action(state.script, point)
    event = %{point: point, context: context, action: action}
    {:reply, action, %{state | script: script, history: [event | state.history]}}
  end

  def handle_call(:history, _from, state), do: {:reply, Enum.reverse(state.history), state}

  @spec normalize_script(keyword() | map()) :: map()
  defp normalize_script(script) when is_map(script), do: normalize_script(Map.to_list(script))

  defp normalize_script(script) when is_list(script) do
    Enum.reduce(script, %{}, fn {point, actions}, acc ->
      actions = if is_list(actions), do: actions, else: [actions]

      Map.update(
        acc,
        point,
        :queue.from_list(actions),
        &:queue.join(&1, :queue.from_list(actions))
      )
    end)
  end

  @spec pop_action(map(), SpectreMnemonic.FailureInjection.point()) :: {term(), map()}
  defp pop_action(script, point) do
    case script |> Map.get(point, :queue.new()) |> :queue.out() do
      {:empty, _queue} ->
        {:ok, script}

      {{:value, action}, remaining} ->
        next =
          if :queue.is_empty(remaining),
            do: Map.delete(script, point),
            else: Map.put(script, point, remaining)

        {action, next}
    end
  end
end
