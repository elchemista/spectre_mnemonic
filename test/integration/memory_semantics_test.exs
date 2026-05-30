defmodule SpectreMnemonic.Integration.MemorySemanticsTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Memory.Observation
  alias SpectreMnemonic.Reflection.Packet

  test "observation consolidation tracks supporting and weakening evidence by scope" do
    {:ok, %{moment: first}} =
      SpectreMnemonic.signal("Alice email is alice@example.com",
        persist?: true,
        scope: {:user, "alice"}
      )

    {:ok, %{moment: second}} =
      SpectreMnemonic.signal("Alice email is alice@example.com",
        persist?: true,
        scope: {:user, "alice"}
      )

    {:ok, %{moment: conflict}} =
      SpectreMnemonic.signal("Alice email is old@example.com",
        persist?: true,
        scope: {:user, "alice"}
      )

    assert {:ok, observations} = SpectreMnemonic.consolidate_observations(scope: {:user, "alice"})

    assert %Observation{} =
             current =
             Enum.find(observations, &(&1.statement == "alice email is alice@example.com"))

    assert current.scope == {:user, "alice"}
    assert current.proof_count == 2
    assert current.contradiction_count == 1
    assert current.state == :promoted
    assert current.trend == :weakening
    assert Enum.sort(current.source_ids) == Enum.sort([first.id, second.id])
    assert Enum.any?(current.evidence, &(&1.source_id == conflict.id and &1.relation == :weakens))

    assert {:ok, [found | _]} =
             SpectreMnemonic.search_observations("Alice email", scope: {:user, "alice"})

    assert found.id == current.id
  end

  test "verify_observation records fresh evidence and confidence" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("Marta status is active", persist?: true)

    assert {:ok, [observation]} = SpectreMnemonic.consolidate_observations()

    assert {:ok, verified} =
             SpectreMnemonic.verify_observation(observation,
               source_id: moment.id,
               relation: :supports,
               confidence_delta: 0.02
             )

    assert verified.proof_count == observation.proof_count + 1
    assert verified.confidence > observation.confidence
    assert verified.last_verified_at
  end

  test "observation consolidation keeps identical facts isolated by scope" do
    {:ok, %{moment: alpha_first}} =
      SpectreMnemonic.signal("Dana owner is Alice",
        persist?: true,
        scope: {:project, "alpha"}
      )

    {:ok, %{moment: alpha_second}} =
      SpectreMnemonic.signal("Dana owner is Alice",
        persist?: true,
        scope: {:project, "alpha"}
      )

    {:ok, %{moment: beta}} =
      SpectreMnemonic.signal("Dana owner is Bob",
        persist?: true,
        scope: {:project, "beta"}
      )

    assert {:ok, alpha_observations} =
             SpectreMnemonic.consolidate_observations(scope: {:project, "alpha"})

    assert [%Observation{} = alpha_observation] = alpha_observations
    assert alpha_observation.statement == "dana owner is alice"
    assert alpha_observation.scope == {:project, "alpha"}
    assert alpha_observation.proof_count == 2
    assert alpha_observation.contradiction_count == 0
    assert Enum.sort(alpha_observation.source_ids) == Enum.sort([alpha_first.id, alpha_second.id])

    assert {:ok, beta_observations} =
             SpectreMnemonic.consolidate_observations(scope: {:project, "beta"})

    assert [%Observation{} = beta_observation] = beta_observations
    assert beta_observation.statement == "dana owner is bob"
    assert beta_observation.scope == {:project, "beta"}
    assert beta_observation.source_ids == [beta.id]

    assert {:ok, alpha_search} =
             SpectreMnemonic.search_observations("Dana owner", scope: {:project, "alpha"})

    assert Enum.map(alpha_search, & &1.id) == [alpha_observation.id]

    assert {:ok, beta_search} =
             SpectreMnemonic.search_observations("Dana owner", scope: {:project, "beta"})

    assert Enum.map(beta_search, & &1.id) == [beta_observation.id]
  end

  test "durable observation search preserves scope and valid_at filters after active reset" do
    {:ok, _} =
      SpectreMnemonic.signal("Invoice status is open",
        persist?: true,
        scope: {:tenant, "one"},
        valid_from: ~U[2026-01-01 00:00:00Z],
        valid_until: ~U[2026-06-01 00:00:00Z]
      )

    {:ok, _} =
      SpectreMnemonic.signal("Invoice status is closed",
        persist?: true,
        scope: {:tenant, "two"},
        valid_from: ~U[2026-01-01 00:00:00Z]
      )

    assert {:ok, [tenant_one]} =
             SpectreMnemonic.consolidate_observations(scope: {:tenant, "one"})

    assert {:ok, [_tenant_two]} =
             SpectreMnemonic.consolidate_observations(scope: {:tenant, "two"})

    clear_memory()
    DurableIndex.rebuild()

    assert {:ok, results} =
             SpectreMnemonic.search_observations("Invoice status",
               scope: {:tenant, "one"},
               valid_at: ~U[2026-03-01 00:00:00Z]
             )

    assert Enum.map(results, & &1.id) == [tenant_one.id]

    assert {:ok, expired} =
             SpectreMnemonic.search_observations("Invoice status",
               scope: {:tenant, "one"},
               valid_at: ~U[2026-07-01 00:00:00Z]
             )

    assert expired == []
  end

  test "mental models are preferred by reflect and adapter output is normalized" do
    assert {:ok, model} =
             SpectreMnemonic.put_mental_model(%{
               title: "Billing Retry Policy",
               query: "billing retry",
               answer: "Use bounded retries with idempotency keys."
             })

    {:ok, %{moment: raw}} = SpectreMnemonic.signal("billing retry raw note uses backoff")

    assert {:ok, %Packet{} = packet} = SpectreMnemonic.reflect("billing retry")
    assert [^model] = packet.mental_models
    assert Enum.any?(packet.raw_memories, &(&1.id == raw.id))
    assert hd(packet.citations).source == :mental_model

    assert {:ok, %Packet{} = adapted} =
             SpectreMnemonic.reflect("billing retry", adapter: __MODULE__.ReflectionAdapter)

    assert adapted.response == {:reflected, "billing retry", [model.id]}
  end

  test "mental model search is scoped and durable after active reset" do
    assert {:ok, alpha} =
             SpectreMnemonic.put_mental_model(%{
               title: "Alpha Deploy Policy",
               query: "deploy policy",
               answer: "Alpha deploys require a canary window.",
               scope: {:project, "alpha"}
             })

    assert {:ok, beta} =
             SpectreMnemonic.put_mental_model(%{
               title: "Beta Deploy Policy",
               query: "deploy policy",
               answer: "Beta deploys require manual approval.",
               scope: {:project, "beta"}
             })

    clear_memory()
    DurableIndex.rebuild()

    assert {:ok, alpha_results} =
             SpectreMnemonic.search_mental_models("deploy policy", scope: {:project, "alpha"})

    assert Enum.map(alpha_results, & &1.id) == [alpha.id]

    assert {:ok, beta_results} =
             SpectreMnemonic.search_mental_models("deploy policy", scope: {:project, "beta"})

    assert Enum.map(beta_results, & &1.id) == [beta.id]

    assert {:ok, packet} = SpectreMnemonic.reflect("deploy policy", scope: {:project, "alpha"})
    assert Enum.map(packet.mental_models, & &1.id) == [alpha.id]
  end

  test "mental model validity windows affect search and reflect" do
    assert {:ok, current} =
             SpectreMnemonic.put_mental_model(%{
               title: "Current Support Model",
               query: "support escalation",
               answer: "Route escalations to the current support owner.",
               valid_from: ~U[2026-01-01 00:00:00Z]
             })

    assert {:ok, expired} =
             SpectreMnemonic.put_mental_model(%{
               title: "Expired Support Model",
               query: "support escalation",
               answer: "Route escalations to the retired support owner.",
               valid_until: ~U[2025-01-01 00:00:00Z]
             })

    assert {:ok, results} =
             SpectreMnemonic.search_mental_models("support escalation",
               valid_at: ~U[2026-05-01 00:00:00Z]
             )

    ids = Enum.map(results, & &1.id)
    assert current.id in ids
    refute expired.id in ids

    assert {:ok, packet} =
             SpectreMnemonic.reflect("support escalation", valid_at: ~U[2026-05-01 00:00:00Z])

    assert Enum.any?(packet.mental_models, &(&1.id == current.id))
    refute Enum.any?(packet.mental_models, &(&1.id == expired.id))
  end

  test "scope filters recall while scopes allows explicit cross-scope recall" do
    {:ok, %{moment: alpha}} =
      SpectreMnemonic.signal("shared invoice retry strategy",
        scope: {:project, "alpha"},
        attention: 2.0
      )

    {:ok, %{moment: beta}} =
      SpectreMnemonic.signal("shared invoice retry strategy",
        scope: {:project, "beta"},
        attention: 2.0
      )

    assert {:ok, scoped} = SpectreMnemonic.recall("invoice retry", scope: {:project, "alpha"})
    scoped_ids = MapSet.new(Enum.map(scoped.moments, & &1.id))
    assert MapSet.member?(scoped_ids, alpha.id)
    refute MapSet.member?(scoped_ids, beta.id)

    assert {:ok, crossed} =
             SpectreMnemonic.recall("invoice retry",
               scopes: [{:project, "alpha"}, {:project, "beta"}],
               limit: 5
             )

    crossed_ids = MapSet.new(Enum.map(crossed.moments, & &1.id))
    assert MapSet.member?(crossed_ids, alpha.id)
    assert MapSet.member?(crossed_ids, beta.id)
  end

  test "unscoped recall stays broad for backward compatibility" do
    {:ok, %{moment: alpha}} =
      SpectreMnemonic.signal("compatibility scope broad query",
        scope: {:workspace, "alpha"},
        attention: 2.0
      )

    {:ok, %{moment: beta}} =
      SpectreMnemonic.signal("compatibility scope broad query",
        scope: {:workspace, "beta"},
        attention: 2.0
      )

    assert {:ok, packet} = SpectreMnemonic.recall("compatibility scope broad", limit: 10)
    ids = MapSet.new(Enum.map(packet.moments, & &1.id))
    assert MapSet.member?(ids, alpha.id)
    assert MapSet.member?(ids, beta.id)
  end

  test "temporal filters distinguish occurred observed and valid windows" do
    {:ok, %{moment: historical}} =
      SpectreMnemonic.signal("Stripe retry decision happened",
        occurred_at: ~U[2024-06-15 10:00:00Z],
        observed_at: ~U[2026-01-10 09:00:00Z],
        valid_from: ~U[2024-06-15 00:00:00Z],
        valid_until: ~U[2025-01-01 00:00:00Z]
      )

    assert {:ok, occurred} =
             SpectreMnemonic.recall("Stripe retry",
               occurred_before: ~U[2025-01-01 00:00:00Z],
               valid_at: ~U[2024-07-01 00:00:00Z]
             )

    assert Enum.any?(occurred.moments, &(&1.id == historical.id))

    assert {:ok, invalid} =
             SpectreMnemonic.recall("Stripe retry", valid_at: ~U[2025-06-01 00:00:00Z])

    refute Enum.any?(invalid.moments, &(&1.id == historical.id))

    assert {:ok, observed} =
             SpectreMnemonic.recall("Stripe retry", observed_after: ~U[2026-01-01 00:00:00Z])

    assert Enum.any?(observed.moments, &(&1.id == historical.id))
  end

  test "token budget recall truncates deterministically while limit remains compatible" do
    {:ok, %{moment: short}} =
      SpectreMnemonic.signal("budget target short note",
        attention: 3.0
      )

    {:ok, %{moment: long}} =
      SpectreMnemonic.signal(
        "budget target " <> Enum.map_join(1..80, " ", &"long#{&1}"),
        attention: 2.0
      )

    assert {:ok, limited} = SpectreMnemonic.recall("budget target", limit: 2)
    assert length(limited.moments) == 2

    assert {:ok, budgeted} = SpectreMnemonic.recall("budget target", limit: 2, max_tokens: 8)
    assert Enum.map(budgeted.moments, & &1.id) == [short.id]
    assert budgeted.usage.max_tokens == 8
    refute Enum.any?(budgeted.moments, &(&1.id == long.id))
  end

  test "retain mission is carried through intake without dropping memory" do
    assert {:ok, packet} =
             SpectreMnemonic.remember("hello, but also remember API retry constraints",
               mission: :code_agent,
               extraction_mode: :concise,
               scope: {:agent, "planner"}
             )

    assert packet.root.scope == {:agent, "planner"}
    assert packet.root.metadata.mission == :code_agent
    assert packet.root.metadata.extraction_mode == :concise
    assert packet.root.metadata.scope == {:agent, "planner"}
    assert packet.root.text =~ "API retry constraints"
  end

  defmodule ReflectionAdapter do
    @behaviour SpectreMnemonic.Reflection.Adapter

    @impl true
    def reflect(packet, _opts) do
      ids = Enum.map(packet.mental_models, & &1.id)
      {:ok, {:reflected, packet.query, ids}}
    end
  end
end
