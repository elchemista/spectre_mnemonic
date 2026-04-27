defmodule SpectreMnemonic.Persistence.Store.Mongo do
  @moduledoc """
  MongoDB adapter placeholder for persistent memory envelopes.

  A real app adapter should store each envelope as a document and index
  `family`, `payload.id`, `dedupe_key`, and `inserted_at`.
  """

  use SpectreMnemonic.Persistence.Store.Placeholder, [:append, :lookup, :search, :event_log]
end
