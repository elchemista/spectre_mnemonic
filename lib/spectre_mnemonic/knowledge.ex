defmodule SpectreMnemonic.Knowledge do
  @moduledoc """
  Durable memory distilled from active focus.
  """

  @type t :: %__MODULE__{
          id: binary(),
          source_id: binary(),
          text: binary(),
          summary: binary() | nil,
          skills: [map()],
          latest_ingestions: [map()],
          facts: [map()],
          procedures: [map()],
          usage: map(),
          vector: binary() | nil,
          binary_signature: binary() | nil,
          embedding: map() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :source_id,
    :text,
    :summary,
    :vector,
    :binary_signature,
    :embedding,
    skills: [],
    latest_ingestions: [],
    facts: [],
    procedures: [],
    usage: %{},
    metadata: %{},
    inserted_at: nil
  ]
end
