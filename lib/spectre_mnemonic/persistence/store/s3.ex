defmodule SpectreMnemonic.Persistence.Store.S3 do
  @moduledoc """
  S3/object storage adapter placeholder for persistent memory envelopes.

  Object stores are treated as archive/blob targets unless a concrete adapter
  advertises search capabilities of its own.
  """

  @behaviour SpectreMnemonic.Persistence.Store.Adapter

  @impl true
  @spec capabilities(keyword()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  def capabilities(_opts), do: [:append, :artifact_blob, :event_log]

  @impl true
  @spec put(SpectreMnemonic.Persistence.Store.Record.t(), keyword()) :: {:error, term()}
  def put(_record, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  @spec delete_or_tombstone(atom(), binary(), keyword()) :: {:error, term()}
  def delete_or_tombstone(_family, _id, _opts),
    do: {:error, {:missing_adapter_implementation, __MODULE__}}
end
