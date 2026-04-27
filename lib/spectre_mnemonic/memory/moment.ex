defmodule SpectreMnemonic.Memory.Moment do
  @moduledoc """
  Active memory item derived from a signal and kept in focus.
  """

  @type t :: %__MODULE__{
          id: binary(),
          signal_id: binary(),
          stream: term(),
          task_id: term(),
          kind: atom(),
          text: binary(),
          input: term(),
          vector: binary() | nil,
          binary_signature: binary() | nil,
          embedding: map() | nil,
          fingerprint: non_neg_integer(),
          inserted_at: DateTime.t(),
          keywords: [binary()],
          entities: [binary()],
          attention: number(),
          metadata: map()
        }

  defstruct [
    :id,
    :signal_id,
    :stream,
    :task_id,
    :kind,
    :text,
    :input,
    :vector,
    :binary_signature,
    :embedding,
    :fingerprint,
    :inserted_at,
    keywords: [],
    entities: [],
    attention: 1.0,
    metadata: %{}
  ]
end
