defmodule SpectreMnemonic.Intake.Extraction.Adapter do
  @moduledoc """
  Behaviour for optional structured entity timeline extraction.

  Adapters receive source text and return a normalized, language-aware graph
  fragment. SpectreMnemonic merges adapter output with its deterministic
  fallback and stores the result as regular memory moments and associations.
  """

  @typedoc "A structured graph fragment extracted from source text."
  @type extraction :: %{
          optional(:entities) => [map()],
          optional(:events) => [map()],
          optional(:times) => [map()],
          optional(:values) => [map()],
          optional(:relations) => [map()],
          optional(:metadata) => map()
        }

  @callback extract(text :: binary(), opts :: keyword()) ::
              {:ok, extraction()} | {:error, term()} | extraction()
end
