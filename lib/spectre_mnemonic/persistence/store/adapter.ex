defmodule SpectreMnemonic.Persistence.Store.Adapter do
  @moduledoc """
  Behaviour for persistent memory storage backends.

  Implementations may be SQL, document, object, or append-only stores. The
  `capabilities/1` callback lets the manager pick smart read and write paths
  without assuming every backend can search or replay.
  """

  alias SpectreMnemonic.Persistence.Store.Contract
  alias SpectreMnemonic.Persistence.Store.Record

  @type capability ::
          :append
          | :replay
          | :replay_fold
          | :lookup
          | :search
          | :vector_search
          | :fulltext_search
          | :artifact_blob
          | :event_log
          | :erase_partition
          | :verify_erasure
          | :semantic_compact

  @callback put(Record.t(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback replay(keyword()) :: {:ok, list()} | {:error, term()}
  @callback replay_fold(keyword(), acc, (term(), acc -> {:cont, acc} | {:halt, acc})) ::
              {:ok, acc} | {:error, term()}
            when acc: term()
  @callback get(atom(), binary(), keyword()) :: {:ok, term()} | {:error, :not_found | term()}
  @callback search(term(), keyword()) :: {:ok, list()} | {:error, term()}
  @callback delete_or_tombstone(atom(), binary(), keyword()) ::
              :ok | {:ok, term()} | {:error, term()}
  @callback semantic_compact(input :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback erase_partition(binary(), term(), MapSet.t({atom(), binary()}), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback verify_erased(binary(), term(), MapSet.t({atom(), binary()}), keyword()) ::
              :ok | {:error, term()}
  @callback capabilities(keyword()) :: [capability()]
  @callback contract(keyword()) :: Contract.t()
  @callback put_batch([Record.t()], keyword()) ::
              :ok | {:ok, term()} | {:error, term()}
  @callback replay_page(term() | nil, keyword()) ::
              {:ok, %{records: [term()], cursor: term() | nil}} | {:error, term()}
  @callback health(keyword()) :: {:ok, map()} | {:error, term()}
  @callback classify_retry(term()) :: :retryable | :permanent | :unknown

  @optional_callbacks replay: 1,
                      replay_fold: 3,
                      get: 3,
                      search: 2,
                      delete_or_tombstone: 3,
                      semantic_compact: 2,
                      erase_partition: 4,
                      verify_erased: 4,
                      contract: 1,
                      put_batch: 2,
                      replay_page: 2,
                      health: 1,
                      classify_retry: 1

  @doc "Returns and validates the semantic contract advertised by an adapter."
  @spec describe(module(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  def describe(adapter, opts \\ [])

  def describe(adapter, opts) when is_atom(adapter) and is_list(opts) do
    case Code.ensure_loaded(adapter) do
      {:module, ^adapter} -> describe_loaded(adapter, opts)
      {:error, reason} -> {:error, {:store_adapter_unavailable, adapter, reason}}
    end
  end

  def describe(adapter, _opts), do: {:error, {:invalid_store_adapter, adapter}}

  @spec describe_loaded(module(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  defp describe_loaded(adapter, opts) do
    contract =
      if function_exported?(adapter, :contract, 1) do
        adapter.contract(opts)
      else
        legacy_contract(adapter, opts)
      end

    case Contract.validate(contract) do
      :ok -> {:ok, contract}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:store_contract_failed, adapter, exception.__struct__}}
  catch
    kind, reason -> {:error, {:store_contract_failed, adapter, {kind, reason}}}
  end

  @spec legacy_contract(module(), keyword()) :: Contract.t()
  defp legacy_contract(adapter, opts) do
    capabilities =
      if function_exported?(adapter, :capabilities, 1), do: adapter.capabilities(opts), else: []

    %Contract{
      adapter: adapter,
      replay_fold: :replay_fold in capabilities,
      erase_semantics: if(:erase_partition in capabilities, do: :tombstone, else: :none),
      conformant?: false
    }
  end
end
