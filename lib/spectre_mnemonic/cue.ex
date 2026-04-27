defmodule SpectreMnemonic.Cue do
  @moduledoc """
  Normalized query used by recall.
  """

  @type t :: %__MODULE__{
          input: term(),
          text: binary(),
          keywords: [binary()],
          entities: [binary()],
          vector: binary() | nil,
          binary_signature: binary() | nil,
          embedding: map() | nil,
          fingerprint: non_neg_integer() | nil,
          opts: keyword()
        }

  defstruct [
    :input,
    :text,
    keywords: [],
    entities: [],
    vector: nil,
    binary_signature: nil,
    embedding: nil,
    fingerprint: nil,
    opts: []
  ]
end
