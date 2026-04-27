defmodule SpectreMnemonic.ActionRuntime.Adapter do
  @moduledoc """
  Optional boundary for external Action Language runtimes.

  SpectreMnemonic never interprets or executes Action Language itself. A runtime
  such as `spectre_kinetic` can implement this behaviour and be configured as
  the explicit adapter for analysis and execution.
  """

  alias SpectreMnemonic.ActionRecipe

  @callback analyze(ActionRecipe.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback run(ActionRecipe.t(), context :: term(), keyword()) ::
              {:ok, term()} | {:error, term()}
end
