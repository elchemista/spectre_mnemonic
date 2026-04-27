defmodule SpectreMnemonic.Embedding.EmbeddingGemma do
  @moduledoc """
  Disabled-by-default deep embedding provider placeholder.

  The v1 live recall path uses `SpectreMnemonic.Embedding.Model2VecStatic`.
  This module reserves the configured deep consolidation provider name until
  Bumblebee/Nx support is wired in.
  """

  @doc "Returns an explicit disabled-provider error for v1."
  @spec embed(term(), keyword()) :: {:error, :deep_embedding_disabled}
  def embed(_input, _opts), do: {:error, :deep_embedding_disabled}
end
