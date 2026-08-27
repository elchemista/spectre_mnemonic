defmodule SpectreMnemonic.ErasureFenceTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Record

  @namespace "spectre_mnemonic_test"

  test "a mutation queued behind erasure cannot resurrect the sealed partition" do
    parent = self()
    scope = {:account, "erasure-race"}
    base_opts = [namespace: @namespace, scope: scope]

    assert {:ok, _receipt} =
             Manager.append(:moments, %{id: "before", text: "erase me"}, base_opts)

    injector = fn
      :erasure_begin, _context ->
        send(parent, {:erasure_entered, self()})

        receive do
          :continue_erasure -> :ok
        end

      _point, _context ->
        :ok
    end

    erasure =
      Task.async(fn ->
        SpectreMnemonic.erase_partition(Keyword.put(base_opts, :failure_injector, injector))
      end)

    assert_receive {:erasure_entered, executor}

    stale_write =
      Task.async(fn ->
        SpectreMnemonic.signal("must not return",
          namespace: @namespace,
          scope: scope,
          persist?: true
        )
      end)

    refute Task.yield(stale_write, 50)
    send(executor, :continue_erasure)

    assert {:ok, report} = Task.await(erasure, 10_000)
    assert report.compaction == :erased
    assert {:error, :partition_erased} = Task.await(stale_write, 5_000)

    assert {:ok, [%Record{family: :erasure_markers, payload: %{sealed?: true}}]} =
             Manager.replay(base_opts)
  end

  test "consolidation queued behind erasure is rejected by the sealed partition" do
    parent = self()
    scope = {:account, "erasure-consolidation-race"}
    base_opts = [namespace: @namespace, scope: scope]

    assert {:ok, _moment} =
             SpectreMnemonic.signal("promote this before erasure",
               namespace: @namespace,
               scope: scope,
               attention: 2.0
             )

    injector = fn
      :erasure_begin, _context ->
        send(parent, {:consolidation_erasure_entered, self()})

        receive do
          :continue_consolidation_erasure -> :ok
        end

      _point, _context ->
        :ok
    end

    erasure =
      Task.async(fn ->
        SpectreMnemonic.erase_partition(Keyword.put(base_opts, :failure_injector, injector))
      end)

    assert_receive {:consolidation_erasure_entered, executor}

    consolidation =
      Task.async(fn ->
        SpectreMnemonic.consolidate(
          namespace: @namespace,
          scope: scope,
          min_attention: 1.0
        )
      end)

    refute Task.yield(consolidation, 50)
    send(executor, :continue_consolidation_erasure)

    assert {:ok, _report} = Task.await(erasure, 10_000)
    assert {:error, :partition_erased} = Task.await(consolidation, 5_000)

    assert {:ok, records} = Manager.replay(base_opts)
    refute Enum.any?(records, &(&1.family == :knowledge))
  end
end
