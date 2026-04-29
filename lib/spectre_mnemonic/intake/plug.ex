defmodule SpectreMnemonic.Intake.Plug do
  @moduledoc """
  Behaviour for composable `remember/2` intake plugs.

  Plugs receive a `%SpectreMnemonic.Intake.Memory{}` draft and may return an
  updated draft, halt the pipeline, or return a final result that SpectreMnemonic
  normalizes into an intake packet.
  """

  alias SpectreMnemonic.Intake.Memory

  @typedoc "Accepted return values from a remember intake plug."
  @type result ::
          Memory.t()
          | {:cont, Memory.t()}
          | {:halt, Memory.t()}
          | {:ok, term()}
          | term()

  @doc """
  Transforms or finalizes a draft memory during `SpectreMnemonic.remember/2`.

  Return the updated memory or `{:cont, memory}` to continue. Return
  `{:halt, memory}` to stop later plugs and store the current draft. Returning
  `{:ok, result}` or another non-memory result halts the pipeline and asks
  intake to normalize the result into a packet.
  """
  @callback call(Memory.t(), keyword()) ::
              result()
end
