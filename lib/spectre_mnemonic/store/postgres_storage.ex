defmodule SpectreMnemonic.Store.PostgresStorage do
  @moduledoc """
  Postgres adapter placeholder for persistent memory envelopes.

  Applications can replace this module with a project-specific adapter that
  writes `%SpectreMnemonic.Store.Record{}` into an Ecto schema or JSONB table.
  The core library does not depend on Ecto, so this module advertises the
  intended SQL capabilities and returns a clear setup error when used directly.
  """

  @behaviour SpectreMnemonic.Store.Adapter

  @impl true
  @spec capabilities(keyword()) :: [SpectreMnemonic.Store.Adapter.capability()]
  def capabilities(_opts),
    do: [:append, :lookup, :search, :vector_search, :fulltext_search, :event_log]

  @impl true
  @spec put(SpectreMnemonic.Store.Record.t(), keyword()) :: {:error, term()}
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
