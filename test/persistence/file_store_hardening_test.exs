defmodule SpectreMnemonic.Persistence.FileStoreHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Persistence.Store.Codec
  alias SpectreMnemonic.Persistence.Store.Disk
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile
  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.Store.Postgres
  alias SpectreMnemonic.Persistence.Store.Record

  test "frame reader stops safely on corrupt, invalid, incomplete, and halted frames" do
    first = FileFrame.encode(1, :first, 100)
    second = FileFrame.encode(2, :second, 200)

    assert read_frames(first <> second) == [{1, 100, :first}, {2, 200, :second}]

    {:ok, io} = StringIO.open(first <> second)

    assert FileFrame.read_frames(io, [], fn frame, acc -> {:halt, [frame | acc]} end) == [
             {1, 100, :first}
           ]

    assert read_frames(binary_part(first, 0, byte_size(first) - 1)) == []
    assert read_frames(corrupt_last_byte(first)) == []
    assert read_frames("UNKNOWN") == []
    assert read_frames(invalid_term_frame()) == []
  end

  test "invalid compaction retention is rejected before snapshot or segment mutation" do
    root = tmp_root("invalid-retention")
    opts = [data_root: root]
    record = record("retained")

    assert {:ok, 1} = StoreFile.put(record, opts)
    active = Path.join([root, "segments", "active.smem"])
    before = File.read!(active)

    assert {:error, :invalid_retention} =
             StoreFile.compact(Keyword.put(opts, :retain_compacted_segments, -1), [record])

    assert File.read!(active) == before
    refute File.exists?(Path.join([root, "snapshots", "current.term"]))
  end

  test "replay fold halt propagates from snapshots without scanning the active segment" do
    root = tmp_root("global-halt")
    opts = [data_root: root]
    first = record("snapshot-first")
    second = record("active-second")

    assert {:ok, 1} = StoreFile.put(first, opts)
    assert {:ok, _snapshot} = StoreFile.compact(opts)
    assert {:ok, 1} = StoreFile.put(second, opts)

    assert {:ok, ["snapshot-first"]} =
             StoreFile.replay_fold(opts, [], fn {_seq, _timestamp, stored}, acc ->
               {:halt, [stored.payload.id | acc]}
             end)
  end

  test "corrupt current snapshots recover from previous snapshot and latest rotated segment" do
    root = tmp_root("snapshot-recovery")
    opts = [data_root: root, retain_compacted_segments: 3]
    first = record("snapshot-one")
    second = %{record("rotated-two") | inserted_at: nil}

    assert {:ok, 1} = StoreFile.put(first, opts)
    assert {:ok, snapshot} = StoreFile.compact(opts)
    assert {:ok, 1} = StoreFile.put(second, opts)
    assert {:ok, ^snapshot} = StoreFile.compact(opts)

    assert {:ok, valid_snapshot_frames} = StoreFile.replay(opts)

    assert Enum.any?(valid_snapshot_frames, fn {_seq, timestamp, stored} ->
             stored.payload.id == "rotated-two" and timestamp == 0
           end)

    File.write!(snapshot, :erlang.term_to_binary(%{version: 99, records: :invalid}))

    assert {:ok, frames} = StoreFile.replay(opts)

    assert frames
           |> Enum.map(fn {_seq, _timestamp, stored} -> stored.payload.id end)
           |> MapSet.new() == MapSet.new(["snapshot-one", "rotated-two"])

    assert {:ok, ^snapshot} =
             StoreFile.compact(Keyword.put(opts, :retain_compacted_segments, 0))

    assert Path.wildcard(Path.join([root, "segments", "compacted-*.smem"])) == []
  end

  test "legacy disk replay returns storage errors instead of crashing" do
    root = tmp_root("disk-error")
    invalid_root = Path.join(root, "regular-file")
    File.mkdir_p!(root)
    File.write!(invalid_root, "not a directory")
    original = Application.get_env(:spectre_mnemonic, :data_root)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:spectre_mnemonic, :data_root),
        else: Application.put_env(:spectre_mnemonic, :data_root, original)
    end)

    Application.put_env(:spectre_mnemonic, :data_root, invalid_root)
    assert {:error, _reason} = Disk.replay()
  end

  test "legacy disk compaction reports unsupported store configurations" do
    Application.put_env(:spectre_mnemonic, :persistent_memory,
      stores: [
        [
          id: :append_only,
          adapter: __MODULE__.AppendOnlyAdapter,
          role: :primary,
          duplicate: true,
          opts: []
        ]
      ]
    )

    assert {:error, {:unexpected_compaction_result, []}} = Disk.compact()
  end

  test "store codec rejects malformed and unsupported terms without raising" do
    encoded_atom_record = %{
      codec: "erlang-term-base64",
      version: 1,
      record: Codec.encode_term(record("codec"))
    }

    assert {:ok, %Record{payload: %{id: "codec"}}} = Codec.decode_record(encoded_atom_record)

    assert {:error, {:invalid_record_term, :not_a_record}} =
             Codec.decode_record(%{
               "codec" => "erlang-term-base64",
               "version" => 1,
               "record" => Codec.encode_term(:not_a_record)
             })

    assert {:error, {:unsupported_record_codec, %{}}} = Codec.decode_record(%{})
    assert {:error, {:invalid_encoded_term, :not_binary}} = Codec.decode_term(:not_binary)
    assert {:error, _reason} = Codec.decode_term("not-base64")
  end

  test "placeholder adapters fail explicitly rather than pretending to persist" do
    record = record("placeholder")
    expected = {:error, {:missing_adapter_implementation, Postgres}}

    assert Postgres.put(record, []) == expected
    assert Postgres.get(:moments, "placeholder", []) == expected
    assert Postgres.search("placeholder", []) == expected
    assert Postgres.delete_or_tombstone(:moments, "placeholder", []) == expected
  end

  defp read_frames(binary) do
    {:ok, io} = StringIO.open(binary)

    FileFrame.read_frames(io, [], fn frame, acc -> {:cont, [frame | acc]} end)
    |> Enum.reverse()
  end

  defp corrupt_last_byte(binary) do
    prefix_size = byte_size(binary) - 1
    <<prefix::binary-size(^prefix_size), last>> = binary
    <<prefix::binary, Bitwise.bxor(last, 0xFF)>>
  end

  defp invalid_term_frame do
    payload = <<131, 255>>
    crc = :erlang.crc32(payload)

    <<"SMEM", 1, 1::unsigned-64, 100::signed-64, byte_size(payload)::32, crc::32,
      payload::binary>>
  end

  defp tmp_root(label) do
    root =
      Path.join(System.tmp_dir!(), "spectre-#{label}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp record(id) do
    %Record{
      id: "pmem-#{id}",
      namespace: "spectre_mnemonic_test",
      scope: nil,
      family: :moments,
      operation: :put,
      payload: %{id: id, namespace: "spectre_mnemonic_test", scope: nil},
      dedupe_key: "moments:#{id}",
      inserted_at: DateTime.utc_now(),
      source_event_id: id,
      metadata: %{namespace: "spectre_mnemonic_test", scope: nil}
    }
  end

  defmodule AppendOnlyAdapter do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:append]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok
  end
end
