defmodule SpectreMnemonic.Memory.Moment do
  @moduledoc """
  Active memory item derived from a signal and kept in focus.
  """

  @type t :: %__MODULE__{
          id: binary(),
          namespace: binary(),
          signal_id: binary(),
          stream: term(),
          task_id: term(),
          scope: term(),
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
          occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t() | nil,
          last_verified_at: DateTime.t() | nil,
          valid_from: DateTime.t() | nil,
          valid_until: DateTime.t() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :namespace,
    :signal_id,
    :stream,
    :task_id,
    :scope,
    :kind,
    :text,
    :input,
    :vector,
    :binary_signature,
    :embedding,
    :fingerprint,
    :inserted_at,
    :occurred_at,
    :observed_at,
    :last_verified_at,
    :valid_from,
    :valid_until,
    keywords: [],
    entities: [],
    attention: 1.0,
    metadata: %{}
  ]
end
