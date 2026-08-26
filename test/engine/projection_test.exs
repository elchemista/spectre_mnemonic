defmodule SpectreMnemonic.Engine.ProjectionTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Context
  alias SpectreMnemonic.Engine.Projection
  alias SpectreMnemonic.QueryContext

  test "large partitions use bounded candidates from protected unnamed shard tables" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "projection-candidates",
         namespace: "projection-test",
         projection_shards: 2,
         brute_force_threshold: 3,
         limits: [max_candidates: 5]}
      )

    for index <- 1..20 do
      text = if index == 7, do: "needle exact memory seven", else: "ordinary memory #{index}"
      assert {:ok, _result} = SpectreMnemonic.signal(text, engine: engine, scope: :bounded)
    end

    assert {:ok, moments, meta} =
             Context.with([engine: engine, scope: :bounded], fn opts ->
               {:ok, cue} = QueryContext.new("needle seven", opts)
               Projection.candidates(cue, [], opts)
             end)

    assert meta.mode == :candidate_first
    assert meta.total == 20
    assert meta.candidates <= 5

    assert Map.keys(meta.sources) --
             [
               :lexical,
               :entity,
               :stream,
               :task,
               :kind,
               :temporal,
               :vector_or_seed,
               :recent,
               :other
             ] == []

    refute inspect(meta.sources) =~ "needle"
    assert Enum.any?(moments, &String.contains?(&1.text, "needle"))

    {:ok, runtime} = Engine.resolve(engine)
    index = shard_index(runtime.config, :bounded)

    [{_pid, tables}] =
      Registry.lookup(
        SpectreMnemonic.Engine.Registry,
        {:projection_shard, runtime.config.ref, index}
      )

    Enum.each(Map.values(tables), fn table ->
      assert :ets.info(table, :protection) == :protected
      assert :ets.info(table, :named_table) == false
    end)

    assert_raise ArgumentError, fn -> :ets.insert(tables.documents, {"foreign", %{}}) end
  end

  test "a crashed projection shard is rebuilt from committed hot memory" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "projection-rebuild",
         namespace: "projection-rebuild",
         projection_shards: 2,
         brute_force_threshold: 0,
         limits: [max_candidates: 8]}
      )

    assert {:ok, result} =
             SpectreMnemonic.signal("rebuild keeps the indexed fact",
               engine: engine,
               scope: {:project, "alpha"}
             )

    {:ok, runtime} = Engine.resolve(engine)
    index = shard_index(runtime.config, {:project, "alpha"})
    key = {:projection_shard, runtime.config.ref, index}
    [{old_pid, _tables}] = Registry.lookup(SpectreMnemonic.Engine.Registry, key)

    Process.exit(old_pid, :kill)
    new_pid = await_restarted_shard(key, old_pid, 100)
    assert is_pid(new_pid)

    assert {:ok, moments, %{mode: :candidate_first}} =
             Context.with([engine: engine, scope: {:project, "alpha"}], fn opts ->
               {:ok, cue} = QueryContext.new("indexed fact", opts)
               Projection.candidates(cue, [], opts)
             end)

    assert Enum.any?(moments, &(&1.id == result.moment.id))
  end

  test "a shard crash midway through apply is rebuilt from the committed hot batch" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "projection-mid-apply",
         namespace: "projection-mid-apply",
         projection_shards: 1,
         brute_force_threshold: 0,
         limits: [max_candidates: 8]}
      )

    parent = self()

    injector = fn
      :projection_apply_after_document, context ->
        send(parent, {:projection_mid_apply, self(), context.moment_id})
        exit(:projection_crashed_during_apply)

      _point, _context ->
        :ok
    end

    assert {:ok, result} =
             SpectreMnemonic.signal("mid-apply recovery keeps this fact",
               engine: engine,
               scope: {:project, "mid-apply"},
               failure_injector: injector
             )

    assert_receive {:projection_mid_apply, old_pid, moment_id}
    assert moment_id == result.moment.id

    {:ok, runtime} = Engine.resolve(engine)
    key = {:projection_shard, runtime.config.ref, 0}
    new_pid = await_restarted_shard(key, old_pid, 100)
    assert is_pid(new_pid)

    assert {:ok, moments, %{mode: :candidate_first}} =
             Context.with([engine: engine, scope: {:project, "mid-apply"}], fn opts ->
               {:ok, cue} = QueryContext.new("recovery fact", opts)
               Projection.candidates(cue, [], opts)
             end)

    assert Enum.any?(moments, &(&1.id == result.moment.id))
  end

  defp shard_index(config, scope) do
    :erlang.phash2(
      {config.ref, config.internal_namespace, scope},
      config.projection_shards
    )
  end

  defp await_restarted_shard(_key, _old_pid, 0), do: nil

  defp await_restarted_shard(key, old_pid, attempts) do
    case Registry.lookup(SpectreMnemonic.Engine.Registry, key) do
      [{pid, _tables}] when pid != old_pid ->
        pid

      _missing_or_old ->
        Process.sleep(10)
        await_restarted_shard(key, old_pid, attempts - 1)
    end
  end
end
