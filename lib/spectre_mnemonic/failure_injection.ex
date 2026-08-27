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
