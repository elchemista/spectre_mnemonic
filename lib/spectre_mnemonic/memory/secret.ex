defmodule SpectreMnemonic.Memory.Secret do
  @moduledoc """
  Encrypted memory item that behaves like a normal moment until revealed.

  Secret moments keep the same core fields as `SpectreMnemonic.Memory.Moment`
  so agents can use the regular remember and recall APIs. The plaintext is not
  stored in active memory or persistence; `text` and `input` stay redacted until
  recall receives an authorization grant and decrypts a returned copy.
  """

  @type t :: %__MODULE__{
          id: binary(),
          signal_id: binary(),
          secret_id: binary(),
          label: binary(),
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
          locked?: boolean(),
          revealed?: boolean(),
          algorithm: atom(),
          ciphertext: binary(),
          iv: binary(),
          tag: binary(),
          aad: binary(),
          authorization: map() | nil,
          reveal: map() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :signal_id,
    :secret_id,
    :label,
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
    :algorithm,
    :ciphertext,
    :iv,
    :tag,
    :aad,
    :authorization,
    :reveal,
    keywords: [],
    entities: [],
    attention: 1.0,
    locked?: true,
    revealed?: false,
    metadata: %{}
  ]
end
