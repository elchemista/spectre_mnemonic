defmodule SpectreMnemonic.Store.MongoStorage do
  @moduledoc """
  MongoDB adapter placeholder for persistent memory envelopes.

  A real app adapter should store each envelope as a document and index
  `family`, `payload.id`, `dedupe_key`, and `inserted_at`.
  """

  @behaviour SpectreMnemonic.Store.Adapter

  @impl true
  def capabilities(_opts), do: [:append, :lookup, :search, :event_log]

  @impl true
  def put(_record, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  def get(_family, _id, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  def search(_cue, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  def delete_or_tombstone(_family, _id, _opts),
    do: {:error, {:missing_adapter_implementation, __MODULE__}}
end
