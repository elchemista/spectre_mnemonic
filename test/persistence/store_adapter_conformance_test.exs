defmodule SpectreMnemonic.Persistence.StoreAdapterConformanceTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Persistence.Store.Adapter
  alias SpectreMnemonic.Persistence.Store.Conformance
  alias SpectreMnemonic.Persistence.Store.Contract
  alias SpectreMnemonic.Persistence.Store.File, as: FileStore
  alias SpectreMnemonic.Persistence.Store.Mongo
  alias SpectreMnemonic.Persistence.Store.Postgres
  alias SpectreMnemonic.Persistence.Store.S3

  test "file adapter passes the shared structural conformance audit" do
    root = tmp_root("file-contract")

    assert {:ok, %{contract: %Contract{} = contract, checks: checks}} =
             Conformance.audit(FileStore, data_root: root)

    assert contract.schema_versions == [1, 2]
    assert contract.idempotency_key == :operation_id
    assert contract.batch_commit == :framed_markers
    assert contract.commit_revision == :record
    assert contract.conflict_detection == :digest
    assert contract.erase_semantics == :physical
    assert contract.transactional == :append_frame
    assert contract.max_batch_size > 0
    assert checks.replay_fold == :ok
    assert checks.health == :ok
    assert checks.classify_retry == :ok
    assert checks.erase_partition == :ok
    assert checks.verify_erased == :ok
    assert {:ok, %{available?: true}} = FileStore.health(data_root: root)
    assert FileStore.classify_retry(:enospc) == :retryable
    assert FileStore.classify_retry(:eacces) == :permanent
    assert FileStore.classify_retry(:unrecognized) == :unknown
  end

  test "placeholder adapters are explicitly non-conformant" do
    for adapter <- [Postgres, Mongo, S3] do
      assert {:ok, %Contract{placeholder?: true, conformant?: false}} =
               Adapter.describe(adapter)

      assert {:error, {:adapter_placeholder, ^adapter}} = Conformance.audit(adapter)
      assert {:error, {:missing_adapter_implementation, ^adapter}} = adapter.health([])
    end
  end

  test "legacy adapters receive a conservative non-conformant contract" do
    assert {:ok, %Contract{conformant?: false, placeholder?: false}} =
             Adapter.describe(__MODULE__.LegacyAdapter)

    assert {:error, {:adapter_not_conformant, __MODULE__.LegacyAdapter}} =
             Conformance.audit(__MODULE__.LegacyAdapter)
  end

  test "invalid and failed adapter contracts cannot advertise a usable backend" do
    assert {:error, {:invalid_store_adapter, 42}} = Adapter.describe(42)

    assert {:error, {:store_adapter_unavailable, __MODULE__.MissingAdapter, :nofile}} =
             Adapter.describe(__MODULE__.MissingAdapter)

    assert {:error, {:store_contract_failed, __MODULE__.FailingContract, RuntimeError}} =
             Adapter.describe(__MODULE__.FailingContract, failure: :raise)

    assert {:error, {:store_contract_failed, __MODULE__.FailingContract, {:throw, :offline}}} =
             Adapter.describe(__MODULE__.FailingContract, failure: :throw)

    assert {:error, {:invalid_store_contract, :shape}} =
             Adapter.describe(__MODULE__.FailingContract, failure: :invalid)
  end

  test "legacy capability hints remain explicitly non-conformant" do
    assert {:ok, %Contract{replay_fold: true, erase_semantics: :tombstone, conformant?: false}} =
             Adapter.describe(__MODULE__.LegacyAdapter,
               capabilities: [:append, :replay_fold, :erase_partition]
             )

    assert {:ok, %Contract{replay_fold: false, erase_semantics: :none, conformant?: false}} =
             Adapter.describe(String)
  end

  defmodule FailingContract do
    def contract(failure: :raise), do: raise("contract unavailable")
    def contract(failure: :throw), do: throw(:offline)
    def contract(failure: :invalid), do: :invalid
  end

  defp tmp_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-mnemonic-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defmodule LegacyAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(opts), do: Keyword.get(opts, :capabilities, [:append])

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok
  end
end
