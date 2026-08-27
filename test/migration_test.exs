defmodule SpectreMnemonic.MigrationTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Migration
  alias SpectreMnemonic.Persistence.Manager

  test "repartition copies visible durable records idempotently and keeps the source" do
    source = {:legacy, "shared"}
    destination = {:customer, "alice"}

    assert {:ok, %{moment: source_moment}} =
             SpectreMnemonic.signal("Alice migration marker",
               scope: source,
               persist?: true
             )

    assign = fn record ->
      if record.family in [:signals, :moments, :memory_states],
        do: destination,
        else: :skip
    end

    assert {:ok, first} =
             Migration.repartition([scope: source], [scope: destination], assign)

    assert first.migrated >= 3
    assert first.idempotent == 0
    refute first.source_erased?

    assert {:ok, destination_records} = Manager.replay(scope: destination)

    assert Enum.any?(destination_records, fn record ->
             record.family == :moments and record.payload.id == source_moment.id and
               record.scope == destination and record.payload.scope == destination
           end)

    assert {:ok, source_records} = Manager.replay(scope: source)

    assert Enum.any?(
             source_records,
             &(&1.family == :moments and &1.payload.id == source_moment.id)
           )

    assert {:ok, retry} =
             Migration.repartition([scope: source], [scope: destination], assign)

    assert retry.migrated == first.migrated
    assert retry.idempotent == retry.migrated
  end

  test "instance schema migration derives opaque scopes without depending on Spectre modules" do
    old_ref = %{schema_version: 1, key: {:agent, "a", :subject, "s"}}
    new_ref = %{schema_version: 2, key: {:agent, "a", :subject, "s"}}
    old_scope = {:spectre, [instance: {old_ref.schema_version, old_ref.key}]}
    new_scope = {:spectre, [instance: {new_ref.schema_version, new_ref.key}]}

    assert {:ok, _result} =
             SpectreMnemonic.signal("schema migration fact", scope: old_scope, persist?: true)

    assert {:ok, report} = Migration.migrate_instance_partition(old_ref, new_ref)
    assert report.migrated > 0
    refute report.source_erased?

    assert {:ok, records} = Manager.replay(scope: new_scope)
    assert Enum.any?(records, &(&1.family == :moments))
  end
end
