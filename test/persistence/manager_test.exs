defmodule SpectreMnemonic.Persistence.ManagerTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Codec
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile
  alias SpectreMnemonic.Persistence.Store.Mongo
  alias SpectreMnemonic.Persistence.Store.Postgres
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.Store.S3

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

  test "append rejects conflicting atom and string scope declarations" do
    configure_stores([store(:primary, role: :primary)])
    alpha = {:tenant, "alpha"}
    beta = {:tenant, "beta"}

    assert {:error, :inconsistent_memory_context} =
             Manager.append(
               :moments,
               %{"scope" => beta, id: "mixed-scope", scope: alpha},
               scope: alpha
             )

    refute_receive {:fake_put, :primary, _record}
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

  test "string-keyed tombstones survive replay and physical compaction" do
    configure_file_store()
    scope = {:tenant, "string-tombstone"}

    assert {:ok, _} =
             Manager.append(
               :moments,
               %{"id" => "mom_string", "text" => "string tombstone target"},
               scope: scope
             )

    assert {:ok, before_tombstone} =
             DurableIndex.search("string tombstone target", scope: scope)

    assert Enum.any?(before_tombstone, &(&1.id == "mom_string"))

    assert {:ok, _} =
             Manager.append(
               :tombstones,
               %{"family" => "moments", "id" => "mom_string"},
               scope: scope
             )

    assert {:ok, records} = Manager.replay(scope: scope)
    refute Enum.any?(records, &(&1.family == :moments))

    assert {:ok, after_tombstone} =
             DurableIndex.search("string tombstone target", scope: scope)

    refute Enum.any?(after_tombstone, &(&1.id == "mom_string"))

    assert {:ok, [{:local_file, {:ok, _snapshot}}]} = Manager.compact(mode: :physical)
    assert {:ok, compacted} = Manager.replay(scope: scope)
    refute Enum.any?(compacted, &(&1.family == :moments))
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

    assert {:ok, indexed} = DurableIndex.search("compact mom_source")
    assert Enum.any?(indexed, &(&1.id == "know_compact"))
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

  test "semantic compaction rejects adapter output from another scope" do
    alpha = {:tenant, "semantic-alpha"}
    beta = {:tenant, "semantic-beta"}
    source = record(:moments, %{id: "mom_source", scope: alpha, attention: 4.0})

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

    assert {:ok,
            %{
              results: [
                {:semantic_replay, {:error, {:scope_mismatch, ^alpha, ^beta}}}
              ],
              written: 0,
              tombstones: 0
            }} =
             Manager.compact(
               mode: :semantic,
               scope: alpha,
               semantic_compact_adapter: __MODULE__.ConflictingScopeAdapter,
               conflicting_scope: beta
             )

    refute_receive {:fake_put, :semantic_replay, _record}
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
          lookup: %{
            {:moments, "mom_1"} => %{
              id: "mom_1",
              namespace: "spectre_mnemonic_test",
              scope: nil
            }
          }
        ]
      ]
    ])

    assert {:ok, %{id: "mom_1"}} = Manager.get(:moments, "mom_1")
    assert {:error, :not_found} = Manager.get(:moments, "missing")
  end

  test "manager lookup skips crashing adapters and continues to the next store" do
    configure_stores([
      [
        id: :crashing_lookup,
        adapter: __MODULE__.CrashingLookupAdapter,
        role: :primary,
        duplicate: true,
        opts: []
      ],
      [
        id: :fallback_lookup,
        adapter: __MODULE__.FakeAdapter,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :fallback_lookup,
          capabilities: [:lookup],
          lookup: %{
            {:moments, "mom_safe"} => %{
              id: "mom_safe",
              namespace: "spectre_mnemonic_test",
              scope: nil
            }
          }
        ]
      ]
    ])

    assert {:ok, %{id: "mom_safe"}} = Manager.get(:moments, "mom_safe")
    assert Process.alive?(Process.whereis(Manager))
  end

  test "invalid and throwing capability callbacks are treated as unsupported" do
    configure_stores([
      [
        id: :invalid_capabilities,
        adapter: __MODULE__.InvalidCapabilitiesAdapter,
        role: :primary,
        duplicate: true,
        opts: []
      ],
      [
        id: :throwing_capabilities,
        adapter: __MODULE__.ThrowingCapabilitiesAdapter,
        duplicate: true,
        opts: []
      ]
    ])

    assert {:ok, []} = Manager.replay()
    assert {:ok, []} = Manager.search("unsupported adapters")
    assert Process.alive?(Process.whereis(Manager))
  end

  test "write adapter exceptions become store failures without crashing the manager" do
    configure_stores([
      [
        id: :crashing_write,
        adapter: __MODULE__.CrashingWriteAdapter,
        role: :primary,
        duplicate: true,
        opts: []
      ]
    ])

    assert {:error, {:primary_persistent_memory_failed, [failure]}} =
             Manager.append(:moments, %{id: "crash-safe"})

    assert failure.store == :crashing_write
    assert match?({:error, {RuntimeError, _message}}, failure.result)
    assert Process.alive?(Process.whereis(Manager))
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
          search_results: [
            %{
              id: "mom_1",
              score: 0.9,
              namespace: "spectre_mnemonic_test",
              scope: nil
            }
          ]
        ]
      ]
    ])

    assert {:ok, [%{id: "mom_1", score: 0.9, store: :searchable}]} =
             Manager.search("memory")
  end

  test "configuration fallback, automatic primary role, scalar payloads, and idempotency agree" do
    assert {:error, {:already_started, pid}} = Manager.start_link()
    assert is_pid(pid)

    Application.put_env(:spectre_mnemonic, :persistent_memory, stores: [])
    assert [default_store] = Keyword.fetch!(Manager.config(), :stores)
    assert Keyword.fetch!(default_store, :id) == :local_file

    configure_stores(
      [
        store(:automatic_primary),
        store(:secondary)
      ],
      write_mode: :primary_only
    )

    assert {:ok, %{record: first, stores: [%{store: :automatic_primary}]}} =
             Manager.append(:knowledge, :scalar_payload,
               dedupe_key: "scalar-dedupe",
               source_event_id: "scalar-source"
             )

    assert first.payload == :scalar_payload
    assert first.source_event_id == "scalar-source"
    assert_receive {:fake_put, :automatic_primary, ^first}
    refute_receive {:fake_put, :secondary, _record}

    assert {:ok, %{record: ^first, stores: [], idempotent?: true}} =
             Manager.append(:knowledge, :scalar_payload,
               dedupe_key: "scalar-dedupe",
               source_event_id: "scalar-source"
             )

    refute_receive {:fake_put, _store, _record}

    assert {:ok, %{stores: [%{store: :automatic_primary}, %{store: :secondary}]}} =
             Manager.append(:knowledge, %{id: :atom_id},
               persistent_memory: [write_mode: :unknown_mode],
               dedupe_key: "unknown-routing"
             )

    assert {:ok, %{stores: [%{store: :local_file}]}} =
             Manager.append(:knowledge, %{id: "fallback-store"},
               persistent_memory: [stores: []],
               dedupe_key: "fallback-store"
             )
  end

  test "put rejects namespace and scope conflicts while normalizing assignable records" do
    configure_stores([store(:primary, role: :primary)])

    foreign = %{record(:moments, %{id: "foreign"}) | namespace: "another_namespace"}

    assert {:error, {:namespace_mismatch, "spectre_mnemonic_test", "another_namespace"}} =
             Manager.put(foreign)

    scoped = %{record(:moments, %{id: "scoped", scope: :beta}) | scope: :beta}
    assert {:error, {:scope_mismatch, :alpha, :beta}} = Manager.put(scoped, scope: :alpha)

    assignable = %Record{
      id: "record-assignable",
      family: :knowledge,
      operation: :put,
      payload: %Date{year: 2026, month: 7, day: 20},
      metadata: %{},
      inserted_at: DateTime.utc_now()
    }

    assert {:ok, %{record: normalized}} = Manager.put(assignable)
    assert normalized.namespace == "spectre_mnemonic_test"
    assert normalized.payload == assignable.payload
    assert is_binary(normalized.dedupe_key)
  end

  test "checked list and fold replay report every adapter failure mode" do
    for replay_result <- [
          {:error, :replay_down},
          :unexpected_replay,
          {:raise, "replay raised"},
          {:throw, :replay_threw},
          {:exit, :replay_exited}
        ] do
      configure_chaos_store([:replay], replay_result: replay_result)

      assert {:error, {:persistent_memory_replay_failed, [%{store: :chaos, reason: _reason}]}} =
               Manager.replay()
    end

    for fold_result <- [
          {:error, :fold_down},
          :unexpected_fold,
          {:raise, "fold raised"},
          {:throw, :fold_threw},
          {:exit, :fold_exited}
        ] do
      configure_chaos_store([:replay_fold], fold_result: fold_result)

      assert {:error, {:persistent_memory_replay_failed, [%{store: :chaos, reason: _reason}]}} =
               Manager.replay_all()
    end

    assert Process.alive?(Process.whereis(Manager))
  end

  test "lookup and search skip malformed, out-of-scope, and crashing adapters" do
    alpha = {:tenant, "lookup-alpha"}
    beta = {:tenant, "lookup-beta"}

    configure_stores([
      chaos_store([:lookup], get_result: {:ok, %{id: "target", scope: beta}}),
      [
        id: :fallback,
        adapter: __MODULE__.FakeAdapter,
        duplicate: true,
        opts: [
          send_to: self(),
          id: :fallback,
          capabilities: [:lookup],
          lookup: %{
            {:moments, "target"} => %{
              id: "target",
              namespace: "spectre_mnemonic_test",
              scope: alpha
            }
          }
        ]
      ]
    ])

    assert {:ok, %{scope: ^alpha}} = Manager.get(:moments, "target", scope: alpha)

    for get_result <- [:unexpected, {:throw, :lookup_threw}, {:exit, :lookup_exited}] do
      configure_chaos_store([:lookup], get_result: get_result)
      assert {:error, :not_found} = Manager.get(:moments, "missing")
    end

    for search_result <- [
          {:error, :search_down},
          :unexpected,
          {:raise, "search raised"},
          {:throw, :search_threw},
          {:exit, :search_exited}
        ] do
      configure_chaos_store([:fulltext_search], search_result: search_result)
      assert {:ok, []} = Manager.search("chaos search")
    end

    configure_chaos_store([:search], search_result: {:ok, [:raw_adapter_result]})

    assert {:ok, []} = Manager.search("raw result")

    assert Process.alive?(Process.whereis(Manager))
  end

  test "write normalization handles ok values, unexpected values, throws, and exits" do
    configure_chaos_store([:append], put_result: {:ok, :stored})
    assert {:ok, _result} = Manager.append(:moments, %{id: "ok-value"})

    for put_result <- [:unexpected, {:throw, :write_threw}, {:exit, :write_exited}] do
      configure_chaos_store([:append], put_result: put_result)
      Manager.reset_dedupe()

      assert {:error, {:primary_persistent_memory_failed, [failure]}} =
               Manager.append(:moments, %{id: inspect(put_result)})

      assert match?({:error, _reason}, failure.result)
    end

    assert Process.alive?(Process.whereis(Manager))
  end

  test "semantic adapters and native compaction contain malformed and exceptional results" do
    source = record(:moments, %{id: "semantic-chaos", attention: 1.0})

    for adapter <- [
          __MODULE__.ErrorSemanticAdapter,
          __MODULE__.UnexpectedSemanticAdapter,
          __MODULE__.InvalidOutputSemanticAdapter,
          __MODULE__.RaisingSemanticAdapter,
          __MODULE__.ThrowingSemanticAdapter
        ] do
      configure_stores([
        chaos_store([:replay], replay_result: {:ok, [source]})
      ])

      assert {:ok, %{results: [{:chaos, {:error, _reason}}]}} =
               Manager.compact(mode: :semantic, semantic_compact_adapter: adapter)
    end

    for native_result <- [
          {:ok, :native_value},
          {:error, :native_down},
          {:raise, "native raised"},
          {:throw, :native_threw},
          {:exit, :native_exited}
        ] do
      configure_chaos_store([:semantic_compact], semantic_result: native_result)
      assert {:ok, %{results: [{:chaos, _result}]}} = Manager.compact(mode: :semantic)
    end

    assert Process.alive?(Process.whereis(Manager))
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

  defp configure_chaos_store(capabilities, opts) do
    configure_stores([chaos_store(capabilities, opts)])
  end

  defp chaos_store(capabilities, opts) do
    [
      id: :chaos,
      adapter: __MODULE__.ChaosAdapter,
      role: :primary,
      duplicate: true,
      opts: Keyword.put(opts, :capabilities, capabilities)
    ]
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
      namespace: "spectre_mnemonic_test",
      scope: Map.get(payload, :scope),
      family: family,
      operation: :put,
      payload: payload,
      dedupe_key: Keyword.get(opts, :dedupe_key, "#{family}:put:#{payload_id}"),
      inserted_at: DateTime.utc_now(),
      source_event_id: payload_id,
      metadata: %{namespace: "spectre_mnemonic_test", scope: Map.get(payload, :scope)}
    }
  end

  defmodule FakeAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(opts), do: Keyword.get(opts, :capabilities, [:append, :replay, :event_log])

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(record, opts) do
      send(Keyword.fetch!(opts, :send_to), {:fake_put, Keyword.fetch!(opts, :id), record})

      case Keyword.get(opts, :fail) do
        nil -> :ok
        reason -> {:error, reason}
      end
    end

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def replay(opts), do: {:ok, Keyword.get(opts, :frames, [])}

    @impl SpectreMnemonic.Persistence.Store.Adapter
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

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def get(family, id, opts) do
      case Map.fetch(Keyword.get(opts, :lookup, %{}), {family, id}) do
        {:ok, result} -> {:ok, result}
        :error -> {:error, :not_found}
      end
    end

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def search(_cue, opts), do: {:ok, Keyword.get(opts, :search_results, [])}
  end

  defmodule SemanticCompactAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter

    @impl SpectreMnemonic.Persistence.Compact.Adapter
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

    @impl SpectreMnemonic.Persistence.Compact.Adapter
    def compact(_input, _opts) do
      {:ok, %{records: [%{"family" => "not_a_known_family", "payload" => %{id: "unsafe"}}]}}
    end
  end

  defmodule ConflictingScopeAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter

    @impl SpectreMnemonic.Persistence.Compact.Adapter
    def compact(_input, opts) do
      {:ok,
       %{
         records: [
           {:knowledge,
            %{
              id: "cross-scope-output",
              scope: Keyword.fetch!(opts, :conflicting_scope),
              text: "must not be written"
            }}
         ]
       }}
    end
  end

  defmodule NativeSemanticAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:append, :semantic_compact]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def semantic_compact(input, opts) do
      send(Keyword.fetch!(opts, :send_to), {:native_semantic_compact, input})
      {:ok, %{strategy: :native_test, written: 3, tombstones: 1}}
    end
  end

  defmodule CrashingLookupAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:lookup]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def get(_family, _id, _opts), do: raise("lookup unavailable")
  end

  defmodule InvalidCapabilitiesAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: :invalid

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok
  end

  defmodule ThrowingCapabilitiesAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: throw(:capability_failure)

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok
  end

  defmodule CrashingWriteAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:append]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: raise("write unavailable")
  end

  defmodule ChaosAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(opts), do: Keyword.get(opts, :capabilities, [])

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, opts), do: resolve(Keyword.get(opts, :put_result, :ok))

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def replay(opts), do: resolve(Keyword.get(opts, :replay_result, {:ok, []}))

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def replay_fold(opts, _acc, _fun),
      do: resolve(Keyword.get(opts, :fold_result, {:error, :missing_fold_result}))

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def get(_family, _id, opts),
      do: resolve(Keyword.get(opts, :get_result, {:error, :not_found}))

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def search(_cue, opts),
      do: resolve(Keyword.get(opts, :search_result, {:ok, []}))

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def semantic_compact(_input, opts),
      do: resolve(Keyword.get(opts, :semantic_result, {:ok, %{}}))

    defp resolve({:raise, message}), do: raise(message)
    defp resolve({:throw, reason}), do: throw(reason)
    defp resolve({:exit, reason}), do: exit(reason)
    defp resolve(result), do: result
  end

  defmodule ErrorSemanticAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter
    @impl true
    def compact(_input, _opts), do: {:error, :semantic_rejected}
  end

  defmodule UnexpectedSemanticAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter
    @impl true
    def compact(_input, _opts), do: :unexpected
  end

  defmodule InvalidOutputSemanticAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter
    @impl true
    def compact(_input, _opts), do: {:ok, :invalid_output}
  end

  defmodule RaisingSemanticAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter
    @impl true
    def compact(_input, _opts), do: raise("semantic raised")
  end

  defmodule ThrowingSemanticAdapter do
    @behaviour SpectreMnemonic.Persistence.Compact.Adapter
    @impl true
    def compact(_input, _opts), do: throw(:semantic_threw)
  end
end
