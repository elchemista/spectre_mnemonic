defmodule SpectreMnemonic.Compact.Adapter do
  @moduledoc """
  Optional behaviour for compacting progressive knowledge.

  Adapters receive active memory, existing `knowledge.smem` events, and loading
  budgets. They may call an LLM, a local model, or deterministic application
  logic, then return compact knowledge events or grouped event fields.
  """

  @callback compact(input :: map(), opts :: keyword()) ::
              {:ok, map() | list()} | {:error, reason :: term()}
end
