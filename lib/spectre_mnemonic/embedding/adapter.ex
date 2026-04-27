defmodule SpectreMnemonic.Embedding.Adapter do
  @moduledoc """
  Behaviour for user-provided embedding adapters.

  Configure with:

      config :spectre_mnemonic, embedding_adapter: MyApp.EmbeddingAdapter
  """

  @callback embed(input :: term(), opts :: keyword()) ::
              {:ok, vector :: [number()]}
              | {:ok, embedding_result :: map()}
              | {:error, reason :: term()}
end
