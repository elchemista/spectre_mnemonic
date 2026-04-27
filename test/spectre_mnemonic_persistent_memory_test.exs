defmodule SpectreMnemonicPersistentMemoryTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.PersistentMemory
  alias SpectreMnemonic.Store.{FileStorage, Record}
  alias SpectreMnemonic.Store.{MongoStorage, PostgresStorage, S3Storage}

  test "writes to primary and duplicate stores but skips duplicate false stores" do
    configure_stores([
      store(:primary, role: :primary),
      store(:secondary),
      store(:archive, duplicate: false)
    ])

    assert {:ok, _result} = PersistentMemory.append(:moments, %{id: "mom_1"})

    assert_receive {:fake_put, :primary, %Record{family: :moments}}
    assert_receive {:fake_put, :secondary, %Record{family: :moments}}
    refute_receive {:fake_put, :archive, _record}
  end

  test "family routing can include a duplicate false store" do
    configure_stores(
      [
        store(:primary, role: :primary),
        store(:secondary),
        store(:archive, duplicate: false)
      ],
      write_mode: {:families, artifacts: [:archive]}
    )

    assert {:ok, _result} = PersistentMemory.append(:artifacts, %{id: "art_1"})

    assert_receive {:fake_put, :primary, %Record{family: :artifacts}}
    assert_receive {:fake_put, :archive, %Record{family: :artifacts}}
    refute_receive {:fake_put, :secondary, _record}
  end

  test "primary store failure returns an error in best effort mode" do
    configure_stores([
      store(:primary, role: :primary, fail: :primary_down),
      store(:secondary)
    ])

    assert {:error, {:primary_persistent_memory_failed, failures}} =
             PersistentMemory.append(:moments, %{id: "mom_1"})

    assert [%{store: :primary, result: {:error, :primary_down}}] = failures
  end

  @tag capture_log: true
  test "secondary failure is tolerated in best effort mode" do
    configure_stores([
      store(:primary, role: :primary),
      store(:secondary, fail: :secondary_down)
    ])

    assert {:ok, %{stores: stores}} = PersistentMemory.append(:moments, %{id: "mom_1"})
    assert Enum.any?(stores, &(&1.store == :secondary and &1.result == {:error, :secondary_down}))
  end

  test "strict mode fails when any selected store fails" do
    configure_stores(
      [
        store(:primary, role: :primary),
        store(:secondary, fail: :secondary_down)
      ],
      failure_mode: :strict
    )

    assert {:error, {:persistent_memory_failed, failures}} =
             PersistentMemory.append(:moments, %{id: "mom_1"})

    assert [%{store: :secondary, result: {:error, :secondary_down}}] = failures
  end

  test "file replay deduplicates records by dedupe key" do
    configure_file_store()

    record = record(:moments, %{id: "mom_1"}, dedupe_key: "moments:put:mom_1")

    assert {:ok, _} = PersistentMemory.put(record)
    assert {:ok, _} = PersistentMemory.put(%{record | id: "pmem_duplicate"})
    assert {:ok, records} = PersistentMemory.replay()

    assert Enum.count(records, &(&1.dedupe_key == "moments:put:mom_1")) == 1
  end

  test "file replay stops at incomplete trailing frames" do
    configure_file_store()

    assert {:ok, _} = PersistentMemory.append(:moments, %{id: "mom_1"})
    File.write!(Path.join(["mnemonic_data", "segments", "active.smem"]), "partial", [:append])

    assert {:ok, records} = PersistentMemory.replay()
    assert Enum.any?(records, &(&1.family == :moments and &1.payload.id == "mom_1"))
  end

  test "replay tombstones suppress forgotten records" do
    configure_file_store()

    assert {:ok, _} = PersistentMemory.put(record(:moments, %{id: "mom_1"}))

    assert {:ok, _} =
             PersistentMemory.put(
               record(:tombstones, %{
                 family: :moments,
                 id: "mom_1",
                 forgotten_at: DateTime.utc_now()
               })
             )

    assert {:ok, records} = PersistentMemory.replay()
    refute Enum.any?(records, &(&1.family == :moments and &1.payload.id == "mom_1"))
    assert Enum.any?(records, &(&1.family == :tombstones))
  end

  test "manager lookup uses stores that advertise lookup capability" do
    configure_stores([
      [
        id: :queryable,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :queryable,
          capabilities: [:lookup],
          lookup: %{{:moments, "mom_1"} => %{id: "mom_1"}}
        ]
      ]
    ])

    assert {:ok, %{id: "mom_1"}} = PersistentMemory.get(:moments, "mom_1")
    assert {:error, :not_found} = PersistentMemory.get(:moments, "missing")
  end

  test "manager search uses stores that advertise query capability" do
    configure_stores([
      [
        id: :searchable,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :searchable,
          capabilities: [:search],
          search_results: [%{id: "mom_1", score: 0.9}]
        ]
      ]
    ])

    assert {:ok, [%{id: "mom_1", score: 0.9, store: :searchable}]} =
             PersistentMemory.search("memory")
  end

  test "built-in adapter capabilities describe sql document and object styles" do
    assert :fulltext_search in PostgresStorage.capabilities([])
    assert :search in MongoStorage.capabilities([])
    assert :artifact_blob in S3Storage.capabilities([])
    refute :search in S3Storage.capabilities([])
  end

  defp configure_file_store do
    configure_stores([
      [
        id: :local_file,
        adapter: FileStorage,
        role: :primary,
        duplicate: true,
        opts: [data_root: "mnemonic_data"]
      ]
    ])
  end

  defp configure_stores(stores, opts \\ []) do
    Application.put_env(
      :spectre_mnemonic,
      :persistent_memory,
      Keyword.merge(
        [
          write_mode: Keyword.get(opts, :write_mode, :all),
          read_mode: :smart,
          failure_mode: Keyword.get(opts, :failure_mode, :best_effort),
          stores: stores
        ],
        opts
      )
    )
  end

  defp store(id, opts \\ []) do
    [
      id: id,
      adapter: __MODULE__.FakeAdapter,
      role: Keyword.get(opts, :role),
      duplicate: Keyword.get(opts, :duplicate, true),
      opts: [send_to: self(), id: id, fail: Keyword.get(opts, :fail)]
    ]
  end

  defp record(family, payload, opts \\ []) do
    payload_id = payload.id

    %Record{
      id: Keyword.get(opts, :id, "pmem_#{payload_id}"),
      family: family,
      operation: :put,
      payload: payload,
      dedupe_key: Keyword.get(opts, :dedupe_key, "#{family}:put:#{payload_id}"),
      inserted_at: DateTime.utc_now(),
      source_event_id: payload_id,
      metadata: %{}
    }
  end

  defmodule FakeAdapter do
    @behaviour SpectreMnemonic.Store.Adapter

    @impl true
    def capabilities(opts), do: Keyword.get(opts, :capabilities, [:append, :replay, :event_log])

    @impl true
    def put(record, opts) do
      send(Keyword.fetch!(opts, :send_to), {:fake_put, Keyword.fetch!(opts, :id), record})

      case Keyword.get(opts, :fail) do
        nil -> :ok
        reason -> {:error, reason}
      end
    end

    @impl true
    def replay(opts), do: {:ok, Keyword.get(opts, :frames, [])}

    @impl true
    def get(family, id, opts) do
      case Map.fetch(Keyword.get(opts, :lookup, %{}), {family, id}) do
        {:ok, result} -> {:ok, result}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def search(_cue, opts), do: {:ok, Keyword.get(opts, :search_results, [])}
  end
end
