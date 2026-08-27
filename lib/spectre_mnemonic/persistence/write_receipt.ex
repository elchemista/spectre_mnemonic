defmodule SpectreMnemonic.Persistence.WriteReceipt do
  @moduledoc """
  Durable outcome of one idempotent memory mutation.

  A committed primary always produces an `:ok` receipt. Replica state is
  reported independently so callers never retry an already-committed mutation
  merely because a secondary store needs repair.
  """

  alias SpectreMnemonic.Persistence.Store.Record

  @enforce_keys [:operation_id, :commit_id, :status, :primary]
  defstruct schema_version: 1,
            operation_id: nil,
            commit_id: nil,
            batch_id: nil,
            status: :committed,
            primary: :committed,
            replicas: %{},
            repair_required?: false,
            idempotent?: false,
            record: nil,
            stores: []

  @type replica_status :: :committed | :pending | :pending_repair | {:error, term()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          operation_id: binary(),
          commit_id: binary(),
          batch_id: binary() | nil,
          status: :committed,
          primary: :committed,
          replicas: %{optional(term()) => replica_status()},
          repair_required?: boolean(),
          idempotent?: boolean(),
          record: Record.t(),
          stores: [map()]
        }
end
