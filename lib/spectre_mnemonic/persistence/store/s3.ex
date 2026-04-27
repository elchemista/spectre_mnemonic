defmodule SpectreMnemonic.Persistence.Store.S3 do
  @moduledoc """
  S3/object storage adapter placeholder for persistent memory envelopes.

  Object stores are treated as archive/blob targets unless a concrete adapter
  advertises search capabilities of its own.
  """

  use SpectreMnemonic.Persistence.Store.Placeholder, [:append, :artifact_blob, :event_log]
end
