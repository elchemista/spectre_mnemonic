defmodule SpectreMnemonic.Engine.RecordReinforcementTest do
  use ExUnit.Case, async: false
  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.PartitionExecutor
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Memory.Association

  test "record reinforcement stays in its named engine and existing partition executor" do
    root =
      Path.join(System.tmp_dir!(), "record-reinforcement-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    engine =
      start_supervised!(
        {Engine, storage_id: "record-reinforcement", namespace: "reinforcement", data_root: root}
      )

    {:ok, runtime} = Engine.resolve(engine)
    namespace = runtime.config.internal_namespace
    scope = {:subject, "demo"}
    opts = [engine_ref: runtime.config.ref, namespace: namespace, scope: scope, persist?: false]

    association = %Association{
      id: "reinforced-association",
      namespace: namespace,
      scope: scope,
      source_id: "first",
      target_id: "second",
      relation: :related_to,
      weight: 0.2,
      metadata: %{durable?: false},
      inserted_at: DateTime.utc_now()
    }

    ETS.with_engine(engine, fn ->
      ETS.insert(:mnemonic_associations, {association.id, association})
    end)

    key = PartitionExecutor.key(opts)
    assert PartitionExecutor.key(association) == key

    assert {:ok, 1} =
             PartitionExecutor.trans(key, fn ->
               Plasticity.reinforce([%{hops: [%{association_id: association.id}]}], opts)
             end)

    [{_, reinforced}] =
      ETS.with_engine(engine, fn -> ETS.lookup(:mnemonic_associations, association.id) end)

    assert reinforced.weight > association.weight
    assert Engine.health(engine) |> elem(0) == :ok
  end
end
