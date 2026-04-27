defmodule SpectreMnemonic.Store.S3Storage do
  @moduledoc """
  S3/object storage adapter placeholder for persistent memory envelopes.

  Object stores are treated as archive/blob targets unless a concrete adapter
  advertises search capabilities of its own.
  """

  @behaviour SpectreMnemonic.Store.Adapter

  @impl true
  def capabilities(_opts), do: [:append, :artifact_blob, :event_log]

  @impl true
  def put(_record, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  def delete_or_tombstone(_family, _id, _opts),
    do: {:error, {:missing_adapter_implementation, __MODULE__}}
end
