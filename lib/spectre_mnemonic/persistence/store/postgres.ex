defmodule SpectreMnemonic.Persistence.Store.Postgres do
  @moduledoc """
  Postgres adapter placeholder for persistent memory envelopes.

  Applications can replace this module with a project-specific adapter that
  writes `%SpectreMnemonic.Persistence.Store.Record{}` into an Ecto schema or
  JSONB table. Use `SpectreMnemonic.Persistence.Store.Codec.encode_record/1`
  and `decode_record/1` when the adapter needs JSON-safe storage for arbitrary
  memory structs, including encrypted `%SpectreMnemonic.Memory.Secret{}` values.
  The core library does not depend on Ecto, so this module advertises the
  intended SQL capabilities and returns a clear setup error when used directly.
  """

  use SpectreMnemonic.Persistence.Store.Placeholder,
      [:append, :lookup, :search, :vector_search, :fulltext_search, :event_log]
end
