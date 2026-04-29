defmodule SpectreMnemonic.Intake.PlugPipeline do
  @moduledoc false

  alias SpectreMnemonic.Intake.Memory

  @type plug :: module() | {module(), keyword()}

  @doc "Runs global plugs followed by per-call plugs."
  @spec run(Memory.t(), keyword()) :: {:ok, Memory.t()} | {:halt, Memory.t()} | {:error, term()}
  def run(%Memory{} = memory, opts) do
    opts
    |> plugs()
    |> Enum.reduce_while({:ok, memory}, fn plug, {:ok, acc} ->
      case call_plug(plug, acc, opts) do
        {:cont, %Memory{} = next} -> {:cont, {:ok, next}}
        {:halt, %Memory{} = next} -> {:halt, {:halt, %{next | halted?: true}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec plugs(keyword()) :: [plug()]
  defp plugs(opts) do
    global = Application.get_env(:spectre_mnemonic, :plugs, [])
    local = Keyword.get(opts, :plugs, [])
    List.wrap(global) ++ List.wrap(local)
  end

  @spec call_plug(plug(), Memory.t(), keyword()) ::
          {:cont, Memory.t()} | {:halt, Memory.t()} | {:error, term()}
  defp call_plug({module, plug_opts}, memory, opts) when is_atom(module) do
    call_plug(module, memory, Keyword.merge(opts, plug_opts))
  end

  defp call_plug(module, memory, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 2) do
      module.call(memory, opts)
      |> normalize_result(memory)
    else
      {:error, {:plug_not_available, module}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call_plug(other, _memory, _opts), do: {:error, {:invalid_plug, other}}

  @spec normalize_result(term(), Memory.t()) :: {:cont, Memory.t()} | {:halt, Memory.t()}
  defp normalize_result(%Memory{} = memory, _previous), do: {:cont, memory}
  defp normalize_result({:cont, %Memory{} = memory}, _previous), do: {:cont, memory}
  defp normalize_result({:halt, %Memory{} = memory}, _previous), do: {:halt, memory}

  defp normalize_result({:ok, %Memory{} = memory}, _previous), do: {:cont, memory}
  defp normalize_result({:ok, result}, previous), do: {:halt, %{previous | result: result}}

  defp normalize_result(result, previous), do: {:halt, %{previous | result: result}}
end
