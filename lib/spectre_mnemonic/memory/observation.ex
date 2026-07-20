defmodule SpectreMnemonic.Memory.Observation do
  @moduledoc """
  Evidence-grounded belief consolidated from raw memory moments.
  """

  @type evidence_relation :: :supports | :weakens | :contradicts
  @type trend :: :strengthening | :stable | :weakening | :stale | :contradicted

  @type t :: %__MODULE__{
          id: binary(),
          namespace: binary(),
          statement: binary(),
          scope: term(),
          tags: [term()],
          source_ids: [binary()],
          evidence: [map()],
          proof_count: non_neg_integer(),
          contradiction_count: non_neg_integer(),
          confidence: float(),
          trend: trend(),
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
    :namespace,
    :statement,
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
    tags: [],
    source_ids: [],
    evidence: [],
    proof_count: 0,
    contradiction_count: 0,
    confidence: 0.0,
    trend: :stable,
    state: :candidate,
    keywords: [],
    entities: [],
    metadata: %{}
  ]
end
