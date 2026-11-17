defmodule SpectreMnemonic.Persistence.SnapshotIntegrityTest do
  use ExUnit.Case, async: true

  alias SpectreMnemonic.Persistence.FramedStore.Snapshot
  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.Store.Record

  setup do
    root =
      Path.join(System.tmp_dir!(), "snapshot-integrity-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "snapshot.smem")}
  end

  test "snapshot reader validates complete input before yielding even its first record", %{
    path: path
  } do
    records = [%Record{id: "first"}, %Record{id: "second"}]
    assert :ok = Snapshot.write(path, records, %{rotated_through: "segment-1"}, sync: :none)

    assert {:halted, ["first"], %{record_count: 2, rotated_through: "segment-1"}} =
             Snapshot.fold(path, [], fn record, acc -> {:halt, [record.id | acc]} end)

    bytes = File.read!(path)
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1))

    assert {:error, {:invalid_snapshot_tail, :incomplete_payload}} =
             Snapshot.fold(path, [], fn _, _ -> flunk("corrupt snapshot was consumed") end)
  end

  test "framing alone cannot make an incomplete, reordered or altered snapshot valid", %{
    path: path
  } do
    manifest = %{schema_version: 2, record_count: 0}
    trailer = %{schema_version: 2, record_count: 0, digest_algorithm: :sha256, digest: <<>>}

    for {frames, reason} <- [
          {[{:snapshot_manifest, manifest}], :snapshot_incomplete},
          {[{:snapshot_manifest, manifest}, {:snapshot_trailer, trailer}],
           :snapshot_digest_mismatch},
          {[{:snapshot_manifest, %{manifest | record_count: 1}}, {:snapshot_trailer, trailer}],
           :snapshot_record_count_mismatch},
          {[{:snapshot_manifest, manifest}, :unexpected, :unexpected], :invalid_frame_order},
          {[
             {:snapshot_manifest, manifest},
             {:snapshot_trailer,
              %{trailer | digest: :crypto.hash(:sha256, ""), digest_algorithm: :unsupported}}
           ], :snapshot_digest_invalid}
        ] do
      bytes =
        frames
        |> Enum.with_index(1)
        |> Enum.map(fn {frame, sequence} -> FileFrame.encode(sequence, frame, 0) end)

      File.write!(path, bytes)
      assert {:error, ^reason} = Snapshot.validate(path)
    end

    File.write!(path, "")
    assert {:error, :invalid_snapshot} = Snapshot.validate(path)
  end

  test "failed streaming snapshot writes stay invalid and reject malformed source tables", %{
    path: path
  } do
    table = :ets.new(:snapshot_source, [:ordered_set])
    on_exit(fn -> if :ets.info(table) != :undefined, do: :ets.delete(table) end)
    :ets.insert(table, {1, %Record{id: "retained"}})

    assert {:error, :disk_full} =
             Snapshot.write_table(path, table, %{},
               sync: :none,
               failure_injector: fn :snapshot_record -> {:error, :disk_full} end
             )

    assert {:error, :snapshot_incomplete} = Snapshot.validate(path)
    :ets.insert(table, {1, :invalid})
    assert {:error, :invalid_snapshot_table_record} = Snapshot.write_table(path, table, %{}, [])
    :ets.delete(table)
    assert {:error, :invalid_snapshot_table} = Snapshot.write_table(path, table, %{}, [])
  end
end
