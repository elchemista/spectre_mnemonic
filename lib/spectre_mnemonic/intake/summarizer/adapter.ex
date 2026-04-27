defmodule SpectreMnemonic.Intake.Summarizer.Adapter do
  @moduledoc """
  Optional behaviour for applications that want LLM or local summarization.

  The input is a map with `:scope`, `:text`, and `:metadata`. Adapters may
  return plain text or a map with `:text`, `:key_points`, `:entities`,
  `:categories`, `:relations`, `:confidence`, and `:metadata`.
  """

  @callback summarize(input :: map(), opts :: keyword()) ::
              {:ok, binary() | map() | list()} | {:error, reason :: term()}
end
