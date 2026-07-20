defmodule SpectreMnemonic.Integration.CoreAPIHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.ETSOwner
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Embedding.BinaryQuantizer
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Intake.Memory
  alias SpectreMnemonic.Intake.MissionPolicy
  alias SpectreMnemonic.Intake.PlugPipeline
  alias SpectreMnemonic.Memory.Observation
  alias SpectreMnemonic.MentalModels
  alias SpectreMnemonic.Observations
  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Recall.Fingerprint
  alias SpectreMnemonic.Recall.Fusion
  alias SpectreMnemonic.Result
  alias SpectreMnemonic.SearchResult

  test "small public helpers cover malformed and alternate result shapes" do
    assert Family.from_string!("moments") == :moments

    assert_raise ArgumentError, ~r/unknown semantic family/, fn ->
      Family.from_string!("definitely_unknown")
    end

    assert {:ok, [2, 4]} = Result.collect_ok([1, 2], &{:ok, &1 * 2})

    assert {:error, :bad_item} =
             Result.collect_ok([1, 2, 3], fn
               2 -> {:error, :bad_item}
               value -> {:ok, value}
             end)

    raw = SearchResult.new(:raw_adapter_value)
    assert raw.record == :raw_adapter_value
    assert SearchResult.key(raw) == {nil, nil, nil}

    existing = %SearchResult{id: "existing", source: :active, text: "kept"}
    assert SearchResult.new(existing, text: "default", family: :moments).text == "kept"
    assert SearchResult.new(existing, family: :moments).family == :moments

    fused =
      Fusion.rrf(
        [
          [%{memory_id: "shared"}, %{source_id: "source"}, :invalid],
          [%{id: "shared"}]
        ],
        k: 10
      )

    assert [{shared_score, %{memory_id: "shared"}}, {_score, %{source_id: "source"}}] = fused
    assert shared_score > 0.1

    assert is_integer(Fingerprint.build(%{arbitrary: :term}))
    assert Fingerprint.hamming_similarity(:invalid, 1) == 0.0
    assert BinaryQuantizer.quantize([]) == nil
    assert BinaryQuantizer.quantize([1.0], bits: 0) == nil
    assert ETSOwner.member?(:mnemonic_moments, "missing") == false
    assert ETSOwner.member?(:missing_mnemonic_table, "missing") == false
  end

  test "mission and plug extensions contain every supported callback result and failure" do
    memory = %Memory{
      input: "plain note",
      namespace: "spectre_mnemonic_test",
      text: "plain note",
      kind: :text,
      stream: :chat,
      metadata: %{},
      tags: []
    }

    assert MissionPolicy.call(memory, []) == memory
    assert MissionPolicy.keep?(memory, :other, [])
    assert MissionPolicy.priority(memory, :other, []) == 1.0
    assert MissionPolicy.extraction_profile(:other) == []

    ordinary = MissionPolicy.call(%{memory | mission: :code_agent}, [])
    assert ordinary.metadata.mission_priority == 1.0

    rewritten =
      MissionPolicy.call(%{memory | mission: :custom},
        mission_policy: __MODULE__.RewriteMissionPolicy
      )

    assert rewritten.text == "rewritten safely"

    rescued =
      MissionPolicy.call(%{memory | mission: :custom},
        mission_policy: __MODULE__.RaisingMissionPolicy
      )

    assert rescued.metadata.mission_priority == 1.0
    assert rescued.metadata.extraction_profile == []

    caught =
      MissionPolicy.call(%{memory | mission: :custom},
        mission_policy: __MODULE__.ThrowingMissionPolicy
      )

    assert caught.metadata.mission_priority == 1.0
    assert caught.metadata.extraction_profile == []

    invalid =
      MissionPolicy.call(%{memory | mission: :custom}, mission_policy: {:invalid, :policy})

    assert invalid.metadata.mission_priority == 1.0

    assert {:ok, ^memory} = PlugPipeline.run(memory, [])

    assert {:ok, %Memory{text: "tuple plug"}} =
             PlugPipeline.run(memory,
               plugs: [{__MODULE__.ShapePlug, text: "tuple plug"}]
             )

    assert {:ok, %Memory{text: "continued"}} =
             PlugPipeline.run(memory, plugs: [__MODULE__.ContinuePlug])

    assert {:ok, %Memory{text: "ok"}} =
             PlugPipeline.run(memory, plugs: [__MODULE__.OkPlug])

    assert {:error, {:plug_not_available, String}} = PlugPipeline.run(memory, plugs: [String])
    assert {:error, {:invalid_plug, 42}} = PlugPipeline.run(memory, plugs: [42])

    assert {:error, {RuntimeError, "plug exploded"}} =
             PlugPipeline.run(memory, plugs: [__MODULE__.RaisingPlug])

    assert {:error, {:throw, :plug_threw}} =
             PlugPipeline.run(memory, plugs: [__MODULE__.ThrowingPlug])

    assert {:halt, %Memory{halted?: true, result: :finished}} =
             PlugPipeline.run(memory, plugs: [__MODULE__.ResultPlug])
  end

  test "focus read APIs stay scoped and tolerate empty or unknown selectors" do
    assert {:error, :not_found} = Focus.status(:missing)
    assert Focus.associations() == []
    assert Focus.fold_moments([], fn moment, acc -> [moment.id | acc] end) == []
    assert Focus.recent_moments(:chat, nil, 5) == []
    assert Focus.moments_by_ids(["missing", "missing"]) == []
    assert Focus.associations_for_ids(["missing"]) == []
    assert Focus.artifacts(["missing"]) == []
    assert Focus.action_recipes(["missing"]) == []
    assert {:ok, 0} = Focus.forget(:unsupported_selector)

    assert {:ok, %{moment: first}} =
             Focus.record_signal("first focus record", task_id: "focus-hardening")

    assert {:ok, %{moment: second}} =
             Focus.record_signal("second focus record", task_id: "focus-hardening")

    assert {:ok, %{status: :active}} = Focus.status("focus-hardening")
    assert Enum.map(Focus.recent_moments(:chat, "focus-hardening", 1), & &1.id) == [second.id]

    assert MapSet.new(Focus.moments_by_ids([first.id, second.id, first.id])) ==
             MapSet.new([first, second])

    assert {:ok, association} = Focus.link(first.id, :supports, second.id)
    assert Focus.associations_for_ids([first.id]) == [association]

    assert {:ok, artifact} = Focus.artifact("/tmp/core-hardening.txt")
    assert Focus.artifacts([artifact.id, artifact.id]) == [artifact]

    assert {:ok, 1} = Focus.forget(fn moment -> moment.id == first.id end)
    assert Focus.moments_by_ids([first.id]) == []
  end

  test "governance lifecycle defaults, invalid transitions, and string scopes are deterministic" do
    assert :forgotten in Governance.states()
    assert Governance.observe_moment(:invalid) == :ok
    assert Governance.fact_claim(:invalid) == nil
    assert Governance.state_for(nil) == nil
    assert Governance.search_visible?("missing")
    assert Governance.consolidatable?(%{id: "missing"})
    assert {:ok, %{stale: 0}} = Governance.decay()

    provenance = Governance.with_provenance(%{}, source_ids: [nil, "source"])
    assert provenance.provenance.source_ids == ["source"]

    event = Governance.state_event("state-event", "not-a-state", :test)
    assert event.state == :short_term
    assert event.namespace == "spectre_mnemonic_test"

    assert :ok = Governance.append_state("lifecycle", :candidate, :observed)
    assert :ok = Governance.append_state("lifecycle", :candidate, :observed)
    assert Governance.state_for("lifecycle") == :candidate

    assert :ok = Governance.append_state("lifecycle", :pinned, :manual)

    assert {:error, {:invalid_memory_transition, :pinned, :promoted}} =
             Governance.append_state("lifecycle", :promoted, :invalid)

    assert :ok = Governance.forget("lifecycle")
    refute Governance.search_visible?("lifecycle")
    refute Governance.consolidatable?(%{id: "lifecycle"})

    scope = {:tenant, "string-context"}

    assert :ok =
             Governance.observe_moment(
               %{"scope" => scope, id: "string-scope", text: "no structured fact"},
               scope: scope
             )

    assert Governance.state_for("string-scope", scope: scope) == :short_term
    assert :ok = Governance.promote_moments([:invalid])
  end

  test "observation and mental-model APIs cover missing, scoped, and verification paths" do
    assert {:ok, []} = Observations.consolidate()
    assert {:ok, []} = Observations.search("missing observation")
    assert {:error, :not_found} = Observations.verify("missing")

    observation = %Observation{
      id: "observation-hardening",
      namespace: "spectre_mnemonic_test",
      statement: "hardening is useful",
      confidence: 0.5
    }

    assert {:error, :not_found} =
             Observations.verify(observation, scope: {:tenant, "wrong"}, persist?: false)

    assert {:ok, supported} =
             Observations.verify(observation,
               relation: :supports,
               source_id: "source-1",
               persist?: false
             )

    assert supported.proof_count == 1
    assert supported.trend == :strengthening

    assert {:ok, weakened} =
             Observations.verify(supported,
               relation: :weakens,
               source_id: "source-2",
               confidence_delta: 2.0,
               persist?: false
             )

    assert weakened.confidence == 0.0
    assert weakened.contradiction_count == 1
    assert weakened.trend == :weakening
    assert {:ok, verified_by_id} = Observations.verify(weakened.id, persist?: false)
    assert verified_by_id.proof_count == 2
    assert verified_by_id.trend == :strengthening

    assert {:ok, model} =
             MentalModels.put("Hardening\nPrefer deterministic failures.", persist?: false)

    assert {:ok, [^model]} = MentalModels.search("deterministic failures", durable_results: [])

    assert {:ok, list_model} =
             MentalModels.put(
               [
                 query: "List input",
                 answer: "Keyword lists are accepted",
                 observed_at: ~D[2026-07-20]
               ],
               persist?: false
             )

    assert list_model.observed_at == ~U[2026-07-20 00:00:00Z]
    assert {:ok, _model} = MentalModels.put(123, persist?: false)

    assert {:ok, []} = SpectreMnemonic.search_observations("facade missing")
    assert {:error, :not_found} = SpectreMnemonic.verify_observation("facade-missing")
    assert {:ok, _knowledge} = SpectreMnemonic.knowledge()
  end

  defmodule RewriteMissionPolicy do
    @behaviour MissionPolicy

    @impl MissionPolicy
    def keep?(memory, _mission, _opts), do: {:rewrite, %{memory | text: "rewritten safely"}}
  end

  defmodule RaisingMissionPolicy do
    @behaviour MissionPolicy

    @impl MissionPolicy
    def keep?(_memory, _mission, _opts), do: raise("keep failed")

    @impl MissionPolicy
    def priority(_memory, _mission, _opts), do: raise("priority failed")

    @impl MissionPolicy
    def extraction_profile(_mission), do: raise("profile failed")
  end

  defmodule ThrowingMissionPolicy do
    @behaviour MissionPolicy

    @impl MissionPolicy
    def keep?(_memory, _mission, _opts), do: throw(:keep_failed)

    @impl MissionPolicy
    def priority(_memory, _mission, _opts), do: throw(:priority_failed)

    @impl MissionPolicy
    def extraction_profile(_mission), do: throw(:profile_failed)
  end

  defmodule ShapePlug do
    def call(memory, opts), do: %{memory | text: Keyword.fetch!(opts, :text)}
  end

  defmodule ContinuePlug do
    def call(memory, _opts), do: {:cont, %{memory | text: "continued"}}
  end

  defmodule OkPlug do
    def call(memory, _opts), do: {:ok, %{memory | text: "ok"}}
  end

  defmodule ResultPlug do
    def call(_memory, _opts), do: {:ok, :finished}
  end

  defmodule RaisingPlug do
    def call(_memory, _opts), do: raise("plug exploded")
  end

  defmodule ThrowingPlug do
    def call(_memory, _opts), do: throw(:plug_threw)
  end
end
