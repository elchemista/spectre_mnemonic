defmodule SpectreMnemonic.ActionRuntime do
  @moduledoc """
  Explicit delegation boundary for Action Language runtimes.

  This module only forwards to a configured adapter. It provides no default
  execution engine and does not evaluate recipe text.
  """

  alias SpectreMnemonic.ActionRecipe

  @doc "Delegates recipe analysis to the configured runtime adapter."
  @spec analyze(ActionRecipe.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def analyze(%ActionRecipe{} = recipe, opts \\ []) do
    with {:ok, adapter} <- adapter(opts) do
      adapter.analyze(recipe, opts)
    end
  end

  @doc "Delegates recipe execution to the configured runtime adapter."
  @spec run(ActionRecipe.t(), context :: term(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(%ActionRecipe{} = recipe, context, opts \\ []) do
    with {:ok, adapter} <- adapter(opts) do
      adapter.run(recipe, context, opts)
    end
  end

  @spec adapter(keyword()) :: {:ok, module()} | {:error, :runtime_not_configured | term()}
  defp adapter(opts) do
    configured =
      Keyword.get(opts, :adapter) ||
        Application.get_env(:spectre_mnemonic, :action_runtime_adapter)

    cond do
      is_nil(configured) ->
        {:error, :runtime_not_configured}

      Code.ensure_loaded?(configured) and function_exported?(configured, :analyze, 2) and
          function_exported?(configured, :run, 3) ->
        {:ok, configured}

      true ->
        {:error, {:runtime_not_available, configured}}
    end
  end
end
