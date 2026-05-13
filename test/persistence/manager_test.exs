defmodule SpectreMnemonic.Persistence.ManagerTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.{Codec, Mongo, Postgres, Record, S3}
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile

  test "writes to primary and duplicate stores but skips duplicate false stores" do
    configure_stores([
      store(:primary, role: :primary),
      store(:secondary),
      store(:archive, duplicate: false)
    ])

    assert {:ok, _result} = Manager.append(:moments, %{id: "mom_1"})

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

    assert {:ok, _result} = Manager.append(:artifacts, %{id: "art_1"})

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
             Manager.append(:moments, %{id: "mom_1"})

    assert [%{store: :primary, result: {:error, :primary_down}}] = failures
  end

  @tag capture_log: true
  test "secondary failure is tolerated in best effort mode" do
    configure_stores([
      store(:primary, role: :primary),
      store(:secondary, fail: :secondary_down)
    ])

    assert {:ok, %{stores: stores}} = Manager.append(:moments, %{id: "mom_1"})
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
             Manager.append(:moments, %{id: "mom_1"})

    assert [%{store: :secondary, result: {:error, :secondary_down}}] = failures
  end

  test "file replay deduplicates records by dedupe key" do
    configure_file_store()

    record = record(:moments, %{id: "mom_1"}, dedupe_key: "moments:put:mom_1")

    assert {:ok, _} = Manager.put(record)
    assert {:ok, _} = Manager.put(%{record | id: "pmem_duplicate"})
    assert {:ok, records} = Manager.replay()

    assert Enum.count(records, &(&1.dedupe_key == "moments:put:mom_1")) == 1
  end

  test "manager replay prefers replay_fold when an adapter advertises it" do
    replay_record = record(:moments, %{id: "from_replay"})
    fold_record = record(:moments, %{id: "from_fold"})

    configure_stores([
      [
        id: :folding,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :folding,
          capabilities: [:append, :replay, :replay_fold],
          frames: [replay_record],
          fold_frames: [fold_record]
        ]
      ]
    ])

    assert {:ok, records} = Manager.replay()
    assert Enum.map(records, & &1.payload.id) == ["from_fold"]
    assert_receive {:fake_replay_fold, :folding}
  end

  test "manager replay falls back to replay when replay_fold is unavailable" do
    configure_stores([
      [
        id: :list_replay,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :list_replay,
          capabilities: [:append, :replay],
          frames: [record(:moments, %{id: "from_replay"})]
        ]
      ]
    ])

    assert {:ok, records} = Manager.replay()
    assert Enum.map(records, & &1.payload.id) == ["from_replay"]
  end

  test "file replay stops at incomplete trailing frames" do
    configure_file_store()

    assert {:ok, _} = Manager.append(:moments, %{id: "mom_1"})
    File.write!(Path.join(["mnemonic_data", "segments", "active.smem"]), "partial", [:append])

    assert {:ok, records} = Manager.replay()
    assert Enum.any?(records, &(&1.family == :moments and &1.payload.id == "mom_1"))
  end

  test "file replay fold restores sequence after the sequence cache is cleared" do
    root =
      Path.join(System.tmp_dir!(), "spectre-file-store-#{System.unique_integer([:positive])}")

    opts = [data_root: root]

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, 1} = StoreFile.put(record(:moments, %{id: "mom_1"}), opts)
    assert {:ok, 2} = StoreFile.put(record(:moments, %{id: "mom_2"}), opts)

    path = Path.join([root, "segments", "active.smem"])
    :persistent_term.erase({StoreFile, :seq, path})

    assert {:ok, 3} = StoreFile.put(record(:moments, %{id: "mom_3"}), opts)

    assert {:ok, frames} = StoreFile.replay(opts)
    assert Enum.map(frames, fn {seq, _timestamp, _payload} -> seq end) == [1, 2, 3]
  end

  test "replay tombstones suppress forgotten records" do
    configure_file_store()

    assert {:ok, _} = Manager.put(record(:moments, %{id: "mom_1"}))

    assert {:ok, _} =
             Manager.put(
               record(:tombstones, %{
                 family: :moments,
                 id: "mom_1",
                 forgotten_at: DateTime.utc_now()
               })
             )

    assert {:ok, records} = Manager.replay()
    refute Enum.any?(records, &(&1.family == :moments and &1.payload.id == "mom_1"))
    assert Enum.any?(records, &(&1.family == :tombstones))
  end

  test "compact defaults to physical file snapshot mode" do
    configure_file_store()

    assert {:ok, _} = Manager.append(:moments, %{id: "mom_1"})

    assert {:ok, [{:local_file, {:ok, snapshot}}]} = Manager.compact()
    assert String.ends_with?(snapshot, ".term")
    assert File.exists?(snapshot)

    assert {:ok, [{:local_file, {:ok, explicit_snapshot}}]} =
             Manager.compact(mode: :physical)

    assert File.exists?(explicit_snapshot)
  end

  test "semantic compaction uses replay fallback and writes compact records" do
    configure_file_store()

    assert {:ok, _} = Manager.append(:moments, %{id: "mom_1", attention: 2.0})
    assert {:ok, _} = Manager.append(:moments, %{id: "mom_2", attention: 1.0})

    assert {:ok, %{mode: :semantic, results: [{:local_file, result}], written: 1}} =
             Manager.compact(mode: :semantic)

    assert result.strategy == :default
    assert result.input == 2
    assert result.written == 1

    assert {:ok, records} = Manager.replay()
    assert Enum.any?(records, &(&1.family == :semantic_compaction_jobs))
  end

  test "semantic compaction can use custom adapter output and tombstone replacements" do
    source = record(:moments, %{id: "mom_source", attention: 4.0})

    configure_stores([
      [
        id: :semantic_replay,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :semantic_replay,
          capabilities: [:append, :replay],
          frames: [source]
        ]
      ]
    ])

    assert {:ok, %{results: [{:semantic_replay, result}]}} =
             Manager.compact(
               mode: :semantic,
               semantic_compact_adapter: __MODULE__.SemanticCompactAdapter,
               test_pid: self()
             )

    assert_receive {:semantic_adapter_called, %{records: [%Record{}]}}
    assert result.strategy == :adapter
    assert result.written == 2
    assert result.tombstones == 1
    assert_receive {:fake_put, :semantic_replay, %Record{family: :knowledge}}
    assert_receive {:fake_put, :semantic_replay, %Record{family: :tombstones}}
  end

  test "semantic compaction skips unknown string families without creating atoms" do
    source = record(:moments, %{id: "mom_source", attention: 4.0})

    configure_stores([
      [
        id: :semantic_replay,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :semantic_replay,
          capabilities: [:append, :replay],
          frames: [source]
        ]
      ]
    ])

    assert {:ok, %{results: [{:semantic_replay, result}]}} =
             Manager.compact(
               mode: :semantic,
               semantic_compact_adapter: __MODULE__.UnknownFamilyAdapter
             )

    assert result.strategy == :custom
    assert result.written == 0
  end

  test "semantic compaction builds adapter input from replay_fold when available" do
    source = record(:moments, %{id: "mom_fold_source", attention: 5.0})

    configure_stores([
      [
        id: :semantic_fold,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :semantic_fold,
          capabilities: [:append, :replay, :replay_fold],
          frames: [],
          fold_frames: [source]
        ]
      ]
    ])

    assert {:ok, %{results: [{:semantic_fold, result}]}} =
             Manager.compact(
               mode: :semantic,
               semantic_compact_adapter: __MODULE__.SemanticCompactAdapter,
               test_pid: self()
             )

    assert_receive {:fake_replay_fold, :semantic_fold}

    assert_receive {:semantic_adapter_called,
                    %{records: [%Record{payload: %{id: "mom_fold_source"}}]}}

    assert result.strategy == :adapter
  end

  test "semantic compaction calls native store adapter when advertised" do
    configure_stores([
      [
        id: :native,
        adapter: __MODULE__.NativeSemanticAdapter,
        role: :primary,
        duplicate: true,
        opts: [send_to: self(), id: :native]
      ]
    ])

    assert {:ok, %{results: [{:native, result}], written: 3, tombstones: 1}} =
             Manager.compact(mode: :semantic)

    assert_receive {:native_semantic_compact, %{store: %{id: :native}}}
    assert result.strategy == :native_test
  end

  test "semantic compaction skips stores without replay or native support" do
    configure_stores([
      [
        id: :append_only,
        adapter: __MODULE__.FakeAdapter,
        role: :primary,
        duplicate: true,
        opts: [send_to: self(), id: :append_only, capabilities: [:append]]
      ]
    ])

    assert {:ok,
            %{
              results: [{:append_only, {:skipped, :semantic_compact_not_supported}}],
              written: 0,
              tombstones: 0
            }} = Manager.compact(mode: :semantic)
  end

  test "all compact mode runs semantic then physical" do
    configure_file_store()

    assert {:ok, _} = Manager.append(:moments, %{id: "mom_all", attention: 3.0})

    assert {:ok, %{mode: :all, semantic: semantic, physical: physical}} =
             Manager.compact(mode: :all)

    assert semantic.mode == :semantic
    assert semantic.written == 1
    assert [{:local_file, {:ok, snapshot}}] = physical
    assert File.exists?(snapshot)
  end

  test "invalid compact mode returns a clear error" do
    assert {:error, {:invalid_compact_mode, :banana}} = Manager.compact(mode: :banana)
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

    assert {:ok, %{id: "mom_1"}} = Manager.get(:moments, "mom_1")
    assert {:error, :not_found} = Manager.get(:moments, "missing")
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
             Manager.search("memory")
  end

  test "built-in adapter capabilities describe sql document and object styles" do
    assert :fulltext_search in Postgres.capabilities([])
    assert :search in Mongo.capabilities([])
    assert :artifact_blob in S3.capabilities([])
    refute :search in S3.capabilities([])
  end

  test "store codec round trips encrypted secret records for JSONB adapters" do
    secret = %Secret{
      id: "mom_secret",
      signal_id: "sig_secret",
      secret_id: "sec_secret",
      label: "github token",
      stream: :chat,
      kind: :secret,
      text: "secret: github token",
      input: "secret: github token",
      algorithm: :aes_256_gcm,
      ciphertext: <<1, 2, 3>>,
      iv: <<4, 5, 6>>,
      tag: <<7, 8, 9>>,
      aad: "sec_secret:mom_secret:github token",
      reveal: %{module: SpectreMnemonic, function: :reveal, arity: 2},
      inserted_at: DateTime.utc_now(),
      metadata: %{provider: :github}
    }

    record = record(:moments, secret)
    encoded = Codec.encode_record(record)

    assert Jason.encode!(encoded)
    refute inspect(encoded) =~ "github_pat"
    assert {:ok, decoded} = Codec.decode_record(encoded)
    assert decoded.family == :moments
    assert decoded.payload == secret
    assert decoded.payload.ciphertext == <<1, 2, 3>>
  end

  defp configure_file_store do
    configure_stores([
      [
        id: :local_file,
        adapter: StoreFile,
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
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

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
    def replay_fold(opts, acc, fun) do
      send(Keyword.fetch!(opts, :send_to), {:fake_replay_fold, Keyword.fetch!(opts, :id)})

      opts
      |> Keyword.get(:fold_frames, Keyword.get(opts, :frames, []))
      |> Enum.reduce_while(acc, fn frame, acc ->
        case fun.(frame, acc) do
          {:cont, acc} -> {:cont, acc}
          {:halt, acc} -> {:halt, acc}
        end
      end)
      |> then(&{:ok, &1})
    end

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

  defmodule SemanticCompactAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter

    @impl true
    def compact(input, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:semantic_adapter_called, input})
      [source] = input.records

      {:ok,
       %{
         strategy: :adapter,
         records: [
           %{
             "family" => "knowledge",
             "payload" => %{id: "know_compact", text: "compact #{source.payload.id}"}
           }
         ],
         replace_ids: [source.id]
       }}
    end
  end

  defmodule UnknownFamilyAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter

    @impl true
    def compact(_input, _opts) do
      {:ok, %{records: [%{"family" => "not_a_known_family", "payload" => %{id: "unsafe"}}]}}
    end
  end

  defmodule NativeSemanticAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl true
    def capabilities(_opts), do: [:append, :semantic_compact]

    @impl true
    def put(_record, _opts), do: :ok

    @impl true
    def semantic_compact(input, opts) do
      send(Keyword.fetch!(opts, :send_to), {:native_semantic_compact, input})
      {:ok, %{strategy: :native_test, written: 3, tombstones: 1}}
    end
  end
end
