defmodule SpectreMnemonic.Telemetry do
  @moduledoc false

  @prefix [:spectre_mnemonic]

  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      # Telemetry remains optional for consumers that use Mnemonic standalone.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(:telemetry, :execute, [@prefix ++ event, measurements, metadata])
    end

    :ok
  end

  @spec span([atom()], map(), (-> result)) :: result when result: term()
  def span(event, metadata, fun)
      when is_list(event) and is_map(metadata) and is_function(fun, 0) do
    started = System.monotonic_time()
    emit(event ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()

      emit(
        event ++ [:stop],
        %{duration: System.monotonic_time() - started},
        Map.put(metadata, :outcome, outcome(result))
      )

      result
    catch
      kind, reason ->
        emit(
          event ++ [:exception],
          %{duration: System.monotonic_time() - started},
          metadata
          |> Map.put(:kind, kind)
          |> Map.put(:reason, safe_reason(reason))
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @spec metadata(term()) :: map()
  def metadata(opts) when is_list(opts) do
    %{
      engine_ref: Keyword.get(opts, :engine_ref) || Keyword.get(opts, :engine),
      operation_id: Keyword.get(opts, :operation_id)
    }
  end

  def metadata(_opts), do: %{engine_ref: nil, operation_id: nil}

  defp outcome({:ok, _value}), do: :ok
  defp outcome(:ok), do: :ok
  defp outcome({:error, _reason}), do: :error
  defp outcome(_result), do: :unknown

  defp safe_reason(reason) when is_atom(reason) or is_number(reason), do: reason

  defp safe_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp safe_reason(reason) when is_tuple(reason), do: :tuple
  defp safe_reason(reason) when is_exception(reason), do: reason.__struct__
  defp safe_reason(_reason), do: :redacted
end
