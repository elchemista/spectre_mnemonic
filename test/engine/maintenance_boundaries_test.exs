defmodule SpectreMnemonic.Engine.MaintenanceBoundariesTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.ConsolidationScheduler
  alias SpectreMnemonic.Engine

  defmodule OfflineStore do
    def capabilities(_opts), do: [:append, :replay]
    def put(_record, opts), do: availability(opts)
    def replay(opts), do: with(:ok <- availability(opts), do: {:ok, []})
    def health(opts), do: with(:ok <- availability(opts), do: {:ok, %{}})

    defp availability(opts) do
      if :atomics.get(Keyword.fetch!(opts, :availability), 1) == 0,
        do: :ok,
        else: {:error, :offline}
    end
  end

  @tag :tmp_dir
  test "all documented compaction modes preserve readable memory", %{tmp_dir: root} do
    for mode <- [:physical, :semantic, :all] do
      engine =
        start_supervised!(
          {Engine,
           storage_id: "maintenance-#{mode}",
           namespace: "maintenance",
           data_root: Path.join(root, Atom.to_string(mode)),
           scheduler: [enabled: false, mode: mode]}
        )

      assert {:ok, _} = SpectreMnemonic.signal("stable orchard fact", engine: engine)
      report = ConsolidationScheduler.run_now(engine)
      assert is_map(report)
      assert report.durable_index == :ok
      assert %{runs: 1, run_active?: false} = ConsolidationScheduler.status(engine)
      assert {:ok, packet} = SpectreMnemonic.recall("orchard", engine: engine)
      assert Enum.any?(packet.moments, &(&1.text == "stable orchard fact"))
    end
  end

  @tag capture_log: true
  test "offline storage produces maintenance diagnostics while the engine remains responsive" do
    availability = :atomics.new(1, [])

    engine =
      start_supervised!(
        {Engine,
         storage_id: "offline-maintenance",
         namespace: "offline-maintenance",
         persistent_memory: [
           stores: [
             [
               id: :offline,
               role: :primary,
               adapter: OfflineStore,
               opts: [availability: availability]
             ]
           ]
         ],
         scheduler: [enabled: false, mode: :none]}
      )

    :atomics.put(availability, 1, 1)
    report = ConsolidationScheduler.run_now(engine)
    assert report.compact == {:ok, :skipped}

    assert {:error, {:persistent_memory_replay_failed, [%{reason: :offline}]}} =
             report.durable_index

    assert %{runs: 1, run_active?: false} = ConsolidationScheduler.status(engine)
    assert {:ok, health} = Engine.health(engine)
    assert health.stores.offline.status == {:error, :offline}

    :atomics.put(availability, 1, 0)
    assert %{durable_index: :ok} = ConsolidationScheduler.run_now(engine)
    assert %{runs: 2, run_active?: false} = ConsolidationScheduler.status(engine)
  end
end
