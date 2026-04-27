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
  def capabilities(_opts),
    do: [:append, :lookup, :search, :vector_search, :fulltext_search, :event_log]

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
