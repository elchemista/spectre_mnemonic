defmodule SpectreMnemonic.Engine.ResourceLimitsTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias SpectreMnemonic.Active.ETS, as: ActiveETS
  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Governance

  test "engine owners may choose maxima above defaults while callers still cannot raise them" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "custom-resource-maxima",
         namespace: "custom-resource-maxima",
         limits: [max_candidates: 2_000]}
      )

    {:ok, runtime} = Engine.resolve(engine)
    assert runtime.config.limits.max_candidates == 2_000

    assert {:ok, packet} =
             SpectreMnemonic.recall("empty",
               engine: engine,
               max_candidates: 4_000
             )

    assert packet.diagnostics.candidates.selected <= 2_000
  end

  test "engine limits reject oversized input, metadata, and vectors and cannot be raised per call" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "strict-resource-limits",
         namespace: "strict-resource-limits",
         limits: [
           max_input_bytes: 16,
           max_metadata_bytes: 32,
           max_metadata_depth: 2,
           max_vector_dimensions: 2
         ]}
      )

    assert {:error, {:mnemonic_limit_exceeded, :max_input_bytes}} =
             SpectreMnemonic.signal(String.duplicate("x", 17),
               engine: engine,
               max_input_bytes: 10_000
             )

    assert {:error, {:mnemonic_limit_exceeded, :max_metadata_bytes}} =
             SpectreMnemonic.signal("small",
               engine: engine,
               metadata: %{value: String.duplicate("m", 64)}
             )

    assert {:error, {:mnemonic_limit_exceeded, :max_metadata_depth}} =
             SpectreMnemonic.signal("small", engine: engine, metadata: %{a: %{b: %{c: 1}}})

    assert {:error, {:mnemonic_limit_exceeded, :max_vector_dimensions}} =
             SpectreMnemonic.signal("small", engine: engine, vector: [1.0, 0.0, 0.0])
  end

  test "rich intake caps chunks and hot projections by bytes" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "bounded-rich-intake",
         namespace: "bounded-rich-intake",
         limits: [
           max_chunks_per_intake: 2,
           max_hot_bytes_per_scope: 4_000,
           max_hot_bytes_per_engine: 8_000
         ]}
      )

    assert {:ok, packet} =
             SpectreMnemonic.remember("one two three four five six seven eight",
               engine: engine,
               scope: :bounded,
               chunk_words: 1,
               overlap_words: 0,
               summaries?: false,
               categories?: false,
               extract_entities?: false,
               cross_memory?: false
             )

    assert length(packet.chunks) == 2

    for index <- 1..20 do
      assert {:ok, _result} =
               SpectreMnemonic.signal("bounded hot record #{index}",
                 engine: engine,
                 scope: :bounded
               )
    end

    {:ok, runtime} = Engine.resolve(engine)
    scope_key = {:scope, {runtime.config.internal_namespace, :bounded}}
    namespace_key = {:namespace, runtime.config.internal_namespace}

    {scope_bytes, engine_bytes} =
      ActiveETS.with_engine(engine, fn ->
        [{^scope_key, scope_bytes}] = ActiveETS.lookup(:mnemonic_hot_bytes, scope_key)
        [{^namespace_key, engine_bytes}] = ActiveETS.lookup(:mnemonic_hot_bytes, namespace_key)
        {scope_bytes, engine_bytes}
      end)

    assert scope_bytes <= 4_000
    assert engine_bytes <= 8_000
  end

  test "pinned bytes are bounded for intake and later governance transitions" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "bounded-pinned-memory",
         namespace: "bounded-pinned-memory",
         limits: [max_pinned_bytes: 1]}
      )

    assert {:error, {:mnemonic_limit_exceeded, :max_pinned_bytes}} =
             SpectreMnemonic.signal("cannot enter pinned memory",
               engine: engine,
               scope: :bounded,
               memory_state: :pinned
             )

    assert {:ok, %{moment: moment}} =
             SpectreMnemonic.signal("ordinary memory remains available",
               engine: engine,
               scope: :bounded
             )

    {:ok, runtime} = Engine.resolve(engine)

    assert {:error, {:mnemonic_limit_exceeded, :max_pinned_bytes}} =
             Governance.append_state(moment.id, :pinned, :manual,
               namespace: runtime.config.internal_namespace,
               engine_ref: runtime.config.ref,
               scope: :bounded,
               max_pinned_bytes: 1
             )
  end
end
