defmodule SpectreMnemonic.Summarizer.Adapter do
  @moduledoc """
  Optional behaviour for applications that want LLM or local summarization.
  """

  @callback summarize(input :: term(), opts :: keyword()) ::
              {:ok, gist :: term()} | {:error, reason :: term()}
end
