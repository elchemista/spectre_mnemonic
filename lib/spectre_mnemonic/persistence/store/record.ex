defmodule SpectreMnemonic.Persistence.Store.Record do
  @moduledoc """
  Backend-neutral persistent memory envelope.

  Adapters receive this shape instead of family-specific structs so SQL,
  document, append-only, and object stores can choose their own physical model
  without changing the focus write path.
  """

  defstruct [
    :id,
    :namespace,
    :scope,
    :family,
    :operation,
    :payload,
    :dedupe_key,
    :inserted_at,
    :source_event_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          namespace: binary(),
          scope: term(),
          family: atom(),
          operation: atom(),
          payload: term(),
          dedupe_key: binary(),
          inserted_at: DateTime.t(),
          source_event_id: binary() | nil,
          metadata: map()
        }
end
