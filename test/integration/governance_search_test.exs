defmodule SpectreMnemonic.Integration.GovernanceSearchTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.ConsolidationScheduler
  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Persistence.Manager

  test "search finds persisted memory after active focus is cleared" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("durable quartz memory survives active reset",
        stream: :research,
        persist?: true
      )

    clear_memory()
    DurableIndex.rebuild()

    assert {:ok, results} = SpectreMnemonic.search("quartz memory", limit: 5)
    assert Enum.any?(results, &(&1.source == :persistent and &1.id == moment.id))
  end

  test "durable hybrid ranking applies pinned boost stale demotion and hidden states" do
    {:ok, %{moment: pinned}} =
      SpectreMnemonic.signal("atlas durable ranking target",
        persist?: true,
        memory_state: :pinned
      )

    {:ok, %{moment: stale}} =
      SpectreMnemonic.signal("atlas durable ranking target stale", persist?: true)

    {:ok, %{moment: hidden}} =
      SpectreMnemonic.signal("atlas durable ranking target hidden", persist?: true)

    Governance.append_state(stale.id, :stale, :test)
    Governance.append_state(hidden.id, :contradicted, :test)
    DurableIndex.rebuild()

    assert {:ok, results} = Manager.search("atlas durable ranking target")
    ids = Enum.map(results, & &1.id)

    assert hd(ids) == pinned.id
    assert stale.id in ids
    refute hidden.id in ids
  end

  test "new entity fact contradicts older fact and search hides the old claim" do
    {:ok, %{moment: old}} =
      SpectreMnemonic.signal("Alice email is old@example.com", persist?: true)

    {:ok, %{moment: new}} =
      SpectreMnemonic.signal("Alice email is new@example.com", persist?: true)

    DurableIndex.rebuild()

    assert Governance.state_for(old.id) == :contradicted
    assert Governance.state_for(new.id) == :promoted

    assert {:ok, results} = SpectreMnemonic.search("Alice email old@example.com", limit: 10)
    ids = Enum.map(results, & &1.id)
    refute old.id in ids
    assert new.id in ids
  end

  test "forget writes governance state and removes hidden memory from search" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("forgettable durable memory", persist?: true)

    assert {:ok, 1} = SpectreMnemonic.forget(moment.id)
    DurableIndex.rebuild()

    assert Governance.state_for(moment.id) == :forgotten
    assert {:ok, results} = SpectreMnemonic.search("forgettable durable memory")
    refute Enum.any?(results, &(&1.id == moment.id))
  end

  test "remembered summaries and extracted facts carry provenance metadata" do
    {:ok, packet} =
      SpectreMnemonic.remember("Bob called Alice on 2026-05-10",
        persist?: true,
        title: "provenance check"
      )

    assert Enum.any?(packet.summaries, &match?(%{source_ids: [_ | _]}, &1.metadata.provenance))
    assert Enum.any?(packet.moments, &match?(%{source_ids: [_ | _]}, &1.metadata.provenance))
  end

  test "opt-in scheduler runs consolidation and freshness decay" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("SchedulerSubject email is schedule@example.com", persist?: true)

    Application.put_env(:spectre_mnemonic, :consolidation_scheduler,
      enabled: true,
      interval_ms: 20,
      mode: :none,
      stale_after_ms: 0,
      min_attention: 1.0
    )

    restart_scheduler()

    assert eventually(fn ->
             Governance.state_for(moment.id) == :stale and
               ConsolidationScheduler.status().runs > 0
           end)
  after
    Application.delete_env(:spectre_mnemonic, :consolidation_scheduler)
    restart_scheduler()
  end

  test "evaluation harness returns recall and latency metrics" do
    result = SpectreMnemonic.Evaluation.run(size: 6)

    assert result.size == 6
    assert result.recall_accuracy > 0.0
    assert result.exact_fact_recall >= 0.0
    assert is_integer(result.latency_ms)
  end

  defp restart_scheduler do
    if pid = Process.whereis(ConsolidationScheduler) do
      Process.exit(pid, :kill)
      eventually(fn -> Process.whereis(ConsolidationScheduler) != pid end)
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
