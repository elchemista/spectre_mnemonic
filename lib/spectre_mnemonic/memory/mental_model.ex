defmodule SpectreMnemonic.Memory.MentalModel do
  @moduledoc """
  Curated stable knowledge or saved answer for recurring memory queries.
  """

  @type t :: %__MODULE__{
          id: binary(),
          title: binary() | nil,
          query: binary(),
          answer: binary(),
          scope: term(),
          source_ids: [binary()],
          citations: [map()],
          state: SpectreMnemonic.Governance.state(),
          vector: binary() | nil,
          binary_signature: binary() | nil,
          embedding: map() | nil,
          keywords: [binary()],
          entities: [binary()],
          occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t() | nil,
          last_verified_at: DateTime.t() | nil,
          valid_from: DateTime.t() | nil,
          valid_until: DateTime.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :title,
    :query,
    :answer,
    :scope,
    :vector,
    :binary_signature,
    :embedding,
    :occurred_at,
    :observed_at,
    :last_verified_at,
    :valid_from,
    :valid_until,
    :inserted_at,
    source_ids: [],
    citations: [],
    state: :promoted,
    keywords: [],
    entities: [],
    metadata: %{}
  ]
end
