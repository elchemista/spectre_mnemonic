defmodule SpectreMnemonic.Persistence.Store.Record do
  @moduledoc """
  Backend-neutral persistent memory envelope.

  Adapters receive this shape instead of family-specific structs so SQL,
  document, append-only, and object stores can choose their own physical model
  without changing the focus write path.
  """

  @schema_version 2

  defstruct [
    :id,
    :storage_id,
    :namespace,
    :scope,
    :family,
    :operation,
    :operation_id,
    :commit_id,
    :batch_id,
    :revision,
    :digest,
    :payload,
    :dedupe_key,
    :inserted_at,
    :source_event_id,
    schema_version: @schema_version,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          schema_version: 1 | 2,
          id: binary(),
          storage_id: binary() | nil,
          namespace: binary(),
          scope: term(),
          family: atom(),
          operation: atom(),
          operation_id: binary() | nil,
          commit_id: binary() | nil,
          batch_id: binary() | nil,
          revision: non_neg_integer() | nil,
          digest: binary() | nil,
          payload: term(),
          dedupe_key: binary() | nil,
          inserted_at: DateTime.t(),
          source_event_id: binary() | nil,
          metadata: map()
        }

  @doc false
  @spec upgrade(map()) :: t()
  def upgrade(%{__struct__: __MODULE__} = record) do
    schema_version = if Map.has_key?(record, :schema_version), do: record.schema_version, else: 1
    known_fields = Map.keys(%__MODULE__{})
    values = record |> Map.from_struct() |> Map.take(known_fields)

    __MODULE__
    |> struct(values)
    |> Map.put(:schema_version, schema_version)
  end
end
