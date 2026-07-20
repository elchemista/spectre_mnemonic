defmodule SpectreMnemonic.Integration.ConsolidatorHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Knowledge.Consolidator

  test "empty consolidation and custom callback result shapes stay explicit" do
    assert {:ok, []} = Consolidator.consolidate()

    assert {:error, {:invalid_consolidation_fun, :invalid}} =
             Consolidator.consolidate(consolidate_with: :invalid)

    assert {:error, :callback_error} =
             Consolidator.consolidate(
               consolidate_with: fn _context -> {:error, :callback_error} end
             )

    assert {:error, {:invalid_consolidation_plan, :invalid_plan}} =
             Consolidator.consolidate(consolidate_with: fn _context -> :invalid_plan end)

    assert {:ok, []} =
             Consolidator.consolidate(consolidate_with: fn _context, _opts -> [] end)
  end

  test "custom consolidation functions cannot crash or throw through the server" do
    assert {:error, {RuntimeError, "consolidation exploded"}} =
             Consolidator.consolidate(
               consolidate_with: fn _context -> raise("consolidation exploded") end
             )

    assert {:error, {:throw, :consolidation_threw}} =
             Consolidator.consolidate(
               consolidate_with: fn _context, _opts -> throw(:consolidation_threw) end
             )

    assert Process.alive?(Process.whereis(Consolidator))
  end

  test "configured consolidation adapters are validated and contained" do
    assert {:error, {:invalid_consolidation_adapter, String}} =
             Consolidator.consolidate(consolidation_adapter: String)

    assert {:error, {RuntimeError, "adapter exploded"}} =
             Consolidator.consolidate(consolidation_adapter: __MODULE__.RaisingAdapter)

    assert {:error, {:exit, :adapter_exited}} =
             Consolidator.consolidate(consolidation_adapter: __MODULE__.ExitingAdapter)

    assert Process.alive?(Process.whereis(Consolidator))
  end

  test "custom plans reject mixed input and output partitions" do
    alpha = {:tenant, "consolidation-alpha"}
    beta = {:tenant, "consolidation-beta"}

    assert {:error, {:mixed_consolidation_partitions, partitions}} =
             Consolidator.consolidate(
               scope: alpha,
               consolidate_with: fn context ->
                 %{
                   context
                   | moments: [
                       %{id: "alpha", namespace: "spectre_mnemonic_test", scope: alpha},
                       %{id: "beta", namespace: "spectre_mnemonic_test", scope: beta}
                     ]
                 }
               end
             )

    assert MapSet.new(partitions) ==
             MapSet.new([
               {"spectre_mnemonic_test", alpha},
               {"spectre_mnemonic_test", beta}
             ])

    assert {:error,
            {:out_of_scope_consolidation_output, {nil, ^beta}, {"spectre_mnemonic_test", ^alpha}}} =
             Consolidator.consolidate(
               scope: alpha,
               consolidate_with: fn context ->
                 %{context | records: [{:knowledge, %{id: "wrong", scope: beta}}]}
               end
             )

    assert {:error, :out_of_scope_consolidation_association} =
             Consolidator.consolidate(
               scope: alpha,
               consolidate_with: fn context ->
                 %{
                   context
                   | associations: [
                       %{
                         id: "association",
                         namespace: "spectre_mnemonic_test",
                         scope: beta
                       }
                     ]
                 }
               end
             )
  end

  test "invalid custom records, tombstones, and compaction errors stop cleanly" do
    assert {:error, {:invalid_consolidation_record, :invalid_record}} =
             Consolidator.consolidate(
               consolidate_with: fn context -> %{context | records: [:invalid_record]} end
             )

    assert {:error, {:invalid_consolidation_tombstone, :invalid_tombstone}} =
             Consolidator.consolidate(
               consolidate_with: fn context ->
                 %{context | tombstones: [:invalid_tombstone]}
               end
             )

    assert {:error, {:invalid_consolidation_tombstone_family, "unknown_family"}} =
             Consolidator.consolidate(
               consolidate_with: fn context ->
                 %{
                   context
                   | tombstones: [
                       %{"family" => "unknown_family", "id" => "forgotten"}
                     ]
                 }
               end
             )

    assert {:error, {:invalid_compact_mode, :invalid_mode}} =
             Consolidator.consolidate(compact?: true, mode: :invalid_mode)
  end

  defmodule RaisingAdapter do
    @behaviour SpectreMnemonic.Knowledge.Consolidator.Adapter

    @impl SpectreMnemonic.Knowledge.Consolidator.Adapter
    def consolidate(_context, _opts), do: raise("adapter exploded")
  end

  defmodule ExitingAdapter do
    @behaviour SpectreMnemonic.Knowledge.Consolidator.Adapter

    @impl SpectreMnemonic.Knowledge.Consolidator.Adapter
    def consolidate(_context, _opts), do: exit(:adapter_exited)
  end
end
