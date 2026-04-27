defmodule SpectreMnemonic.Knowledge do
  @moduledoc """
  Durable memory distilled from active focus.
  """

  @type t :: %__MODULE__{
          id: binary(),
          source_id: binary(),
          text: binary(),
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
    :vector,
    :binary_signature,
    :embedding,
    metadata: %{},
    inserted_at: nil
  ]
end
