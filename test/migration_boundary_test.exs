defmodule SpectreMnemonic.MigrationBoundaryTest do
  use SpectreMnemonic.MemoryCase

  import ExUnit.CaptureIO

  alias Mix.Tasks.SpectreMnemonic.Repartition
  alias SpectreMnemonic.Migration
  alias SpectreMnemonic.Persistence.Manager

  defmodule Assignment do
    def source_options, do: [scope: {:legacy, "cli"}]
    def destination_options, do: [scope: {:customer, "cli"}]
    def assign(_record), do: {:ok, {:customer, "cli"}}
  end

  test "offline repartition command copies records and reports an idempotent retry" do
    assert {:ok, _} =
             SpectreMnemonic.signal("CLI migration record",
               scope: {:legacy, "cli"},
               persist?: true
             )

    assert capture_io(fn -> Repartition.run([inspect(Assignment)]) end) =~ "idempotent=0"
    assert capture_io(fn -> Repartition.run([inspect(Assignment)]) end) =~ "source_erased=false"
    assert {:ok, records} = Manager.replay(scope: {:customer, "cli"})
    assert Enum.any?(records, &(&1.family == :moments))
  end

  test "offline command rejects incomplete or unavailable assignment modules" do
    assert_raise Mix.Error, ~r/usage: mix/, fn -> Repartition.run([]) end

    assert_raise Mix.Error, ~r/invalid_repartition_module/, fn ->
      Repartition.run([inspect(__MODULE__)])
    end

    assert_raise Mix.Error, ~r/repartition_module_not_loaded/, fn ->
      Repartition.run(["NoSuchMnemonicReleaseAssignment"])
    end
  end

  test "invalid migration options fail before replaying or writing records" do
    assert {:error, {:invalid_repartition_options, :source, [:invalid]}} =
             Migration.repartition([:invalid], [], Assignment)

    assert {:error, {:invalid_repartition_options, :destination, [:invalid]}} =
             Migration.repartition([], [:invalid], Assignment)

    assert {:error, {:invalid_repartition_options, :bad, []}} =
             Migration.repartition(:bad, [], Assignment)

    assert {:error, {:invalid_repartition_assigner, 42}} = Migration.repartition([], [], 42)

    assert {:error, {:invalid_repartition_assigner, String}} =
             Migration.repartition([], [], String)

    assert {:error, {:repartition_scope_required, :destination}} =
             Migration.migrate_partition([], [])

    assert {:error, {:invalid_instance_ref, %{key: "missing-schema"}}} =
             Migration.migrate_instance_partition(%{key: "missing-schema"}, %{})
  end

  test "host assignment may skip records and copied JSON contexts use the destination scope" do
    source = :json_source
    destination = :json_destination

    payload = %{
      id: "json-context",
      payload: %{"scope" => source, "namespace" => "spectre_mnemonic_test"}
    }

    assert {:ok, _} = Manager.append(:artifacts, payload, scope: source)

    assert {:ok, report} =
             Migration.repartition([scope: source], [scope: destination], fn _ -> :skip end)

    assert report.skipped == report.scanned
    assert report.skipped > 0
    assert report.migrated == 0
    assert {:ok, []} = Manager.replay(scope: destination)

    assert {:ok, _} = Migration.migrate_partition([scope: source], scope: destination)
    assert {:ok, [copied]} = Manager.replay(scope: destination)
    assert copied.payload.payload["scope"] == destination
    assert {:ok, [original]} = Manager.replay(scope: source)
    assert original.payload.payload["scope"] == source
  end

  test "assignment failures stop migration without removing the source or copying a record" do
    source = {:legacy, "assignment-failure"}
    destination = {:customer, "assignment-failure"}
    assert {:ok, _} = SpectreMnemonic.signal("unassigned", scope: source, persist?: true)

    for {assigner, reason} <- [
          {fn _ -> {:error, :ownership_unknown} end, :ownership_unknown},
          {fn _ -> raise "ownership service unavailable" end,
           {RuntimeError, "ownership service unavailable"}},
          {fn _ -> throw(:ownership_unavailable) end, {:throw, :ownership_unavailable}}
        ] do
      assert {:error, {:repartition_assignment_failed, _id, ^reason, report}} =
               Migration.repartition([scope: source], [scope: destination], assigner)

      assert report.migrated == 0
      assert report.scanned == 1
      assert {:ok, []} = Manager.replay(scope: destination)
      assert {:ok, [_ | _]} = Manager.replay(scope: source)
    end
  end

  test "verified instance migration may erase its original partition explicitly" do
    old = %{schema_version: 1, key: "erase-after-copy"}
    new = %{schema_version: 2, key: "erase-after-copy"}
    old_scope = {:spectre, [instance: {old.schema_version, old.key}]}
    new_scope = {:spectre, [instance: {new.schema_version, new.key}]}

    assert {:ok, _} =
             SpectreMnemonic.signal("retained in destination", scope: old_scope, persist?: true)

    assert {:ok, %{migrated: migrated, source_erased?: true}} =
             Migration.migrate_instance_partition(old, new,
               namespace: "spectre_mnemonic_test",
               erase_source?: true
             )

    assert migrated > 0
    assert {:ok, erased_records} = Manager.replay(scope: old_scope)
    assert Enum.all?(erased_records, &(&1.family == :erasure_markers))
    assert {:ok, records} = Manager.replay(scope: new_scope)
    assert Enum.any?(records, &(&1.family == :moments))
  end
end
