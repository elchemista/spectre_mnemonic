defmodule SpectreMnemonic.Persistence.Compact.Adapter do
  @moduledoc """
  Optional behaviour for semantic persistent-memory compaction.

  This adapter receives replayed durable records for stores that do not provide
  native semantic compaction. Applications can use it to summarize, merge, or
  choose records with an LLM or custom deterministic policy.
  """

  @callback compact(input :: map(), opts :: keyword()) ::
              {:ok, map() | list()} | {:error, reason :: term()}
end
