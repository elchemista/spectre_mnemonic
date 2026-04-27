defmodule SpectreMnemonic.Persistence.Store.Mongo do
  @moduledoc """
  MongoDB adapter placeholder for persistent memory envelopes.

  A real app adapter should store each envelope as a document and index
  `family`, `payload.id`, `dedupe_key`, and `inserted_at`.
  """

  @behaviour SpectreMnemonic.Persistence.Store.Adapter

  @impl true
  @spec capabilities(keyword()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  def capabilities(_opts), do: [:append, :lookup, :search, :event_log]

  @impl true
  @spec put(SpectreMnemonic.Persistence.Store.Record.t(), keyword()) :: {:error, term()}
  def put(_record, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  @spec get(atom(), binary(), keyword()) :: {:error, term()}
  def get(_family, _id, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  @spec search(term(), keyword()) :: {:error, term()}
  def search(_cue, _opts), do: {:error, {:missing_adapter_implementation, __MODULE__}}

  @impl true
  @spec delete_or_tombstone(atom(), binary(), keyword()) :: {:error, term()}
  def delete_or_tombstone(_family, _id, _opts),
    do: {:error, {:missing_adapter_implementation, __MODULE__}}
end
