defmodule SpectreMnemonic.Store.Adapter do
  @moduledoc """
  Behaviour for persistent memory storage backends.

  Implementations may be SQL, document, object, or append-only stores. The
  `capabilities/1` callback lets the manager pick smart read and write paths
  without assuming every backend can search or replay.
  """

  alias SpectreMnemonic.Store.Record

  @type capability ::
          :append
          | :replay
          | :lookup
          | :search
          | :vector_search
          | :fulltext_search
          | :artifact_blob
          | :event_log

  @callback put(Record.t(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback replay(keyword()) :: {:ok, list()} | {:error, term()}
  @callback get(atom(), binary(), keyword()) :: {:ok, term()} | {:error, :not_found | term()}
  @callback search(term(), keyword()) :: {:ok, list()} | {:error, term()}
  @callback delete_or_tombstone(atom(), binary(), keyword()) ::
              :ok | {:ok, term()} | {:error, term()}
  @callback capabilities(keyword()) :: [capability()]

  @optional_callbacks replay: 1, get: 3, search: 2, delete_or_tombstone: 3
end
