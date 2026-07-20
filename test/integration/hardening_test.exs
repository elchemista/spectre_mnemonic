defmodule SpectreMnemonic.Integration.HardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.SearchResult

  @namespace "spectre_mnemonic_test"
  @uuid7 ~r/^[a-z_]+_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "persisted identities are namespaced UUIDv7 values" do
    assert {:ok, %{signal: signal, moment: moment}} =
             SpectreMnemonic.signal("stable identity", persist?: false)

    assert signal.id =~ @uuid7
    assert moment.id =~ @uuid7
    assert signal.namespace == @namespace
    assert moment.namespace == @namespace
    assert signal.metadata.namespace == @namespace
    assert moment.metadata.namespace == @namespace

    assert {:error, {:namespace_mismatch, @namespace, "another_instance"}} =
             SpectreMnemonic.signal("wrong namespace",
               namespace: "another_instance",
               persist?: false
             )
  end

  test "scope is a tenant partition for recall, replay, and associations" do
    alpha_scope = {:tenant, "alpha"}
    beta_scope = {:tenant, "beta"}

    assert {:ok, %{moment: alpha}} =
             SpectreMnemonic.signal("shared invoice status", scope: alpha_scope)

    assert {:ok, %{moment: beta}} =
             SpectreMnemonic.signal("shared invoice status", scope: beta_scope)

    assert {:ok, alpha_packet} =
             SpectreMnemonic.recall("invoice status", scope: alpha_scope)

    assert Enum.map(alpha_packet.moments, & &1.id) == [alpha.id]

    assert {:ok, beta_packet} =
             SpectreMnemonic.recall("invoice status", scope: beta_scope)

    assert Enum.map(beta_packet.moments, & &1.id) == [beta.id]
    assert {:ok, %{moments: []}} = SpectreMnemonic.recall("invoice status")

    assert {:error, :cross_scope_association} =
             SpectreMnemonic.link(alpha.id, :related_memory, beta.id, scope: alpha_scope)

    assert {:ok, alpha_records} = Manager.replay(scope: alpha_scope)
    assert alpha_records != []
    assert Enum.all?(alpha_records, &(&1.scope == alpha_scope))
  end

  test "scope isolates every recall component including knowledge and skills" do
    alpha_scope = {:tenant, "complete-alpha"}
    beta_scope = {:tenant, "complete-beta"}
    shared_text = "isolation sentinel deployment protocol"

    assert {:ok, %{moment: alpha_moment}} =
             SpectreMnemonic.signal(shared_text, scope: alpha_scope, persist?: true)

    assert {:ok, %{moment: beta_moment}} =
             SpectreMnemonic.signal(shared_text, scope: beta_scope, persist?: true)

    assert {:ok, _alpha_fact} =
             SpectreMnemonic.signal("IsolationSentinel status is alpha-private",
               scope: alpha_scope
             )

    assert {:ok, _beta_fact} =
             SpectreMnemonic.signal("IsolationSentinel status is beta-private", scope: beta_scope)

    assert {:ok, alpha_observations} =
             SpectreMnemonic.consolidate_observations(
               scope: alpha_scope,
               include_durable?: false
             )

    assert {:ok, beta_observations} =
             SpectreMnemonic.consolidate_observations(
               scope: beta_scope,
               include_durable?: false
             )

    assert {:ok, %{event: alpha_skill}} =
             SpectreMnemonic.learn("Isolation sentinel skill\n- alpha procedure",
               scope: alpha_scope
             )

    assert {:ok, %{event: beta_skill}} =
             SpectreMnemonic.learn("Isolation sentinel skill\n- beta procedure",
               scope: beta_scope
             )

    assert {:ok, alpha_model} =
             SpectreMnemonic.put_mental_model(
               %{query: "isolation sentinel", answer: "alpha guidance"},
               scope: alpha_scope
             )

    assert {:ok, beta_model} =
             SpectreMnemonic.put_mental_model(
               %{query: "isolation sentinel", answer: "beta guidance"},
               scope: beta_scope
             )

    alpha_observation_ids = MapSet.new(alpha_observations, & &1.id)
    beta_observation_ids = MapSet.new(beta_observations, & &1.id)

    assert {:ok, alpha_packet} =
             SpectreMnemonic.recall(
               "isolation sentinel isolationsentinel",
               scope: alpha_scope,
               limit: 20
             )

    assert Enum.any?(alpha_packet.moments, &(&1.id == alpha_moment.id))
    refute Enum.any?(alpha_packet.moments, &(&1.id == beta_moment.id))
    assert Enum.all?(alpha_packet.moments, &Scope.match?(&1, scope: alpha_scope))
    assert Enum.all?(alpha_packet.associations, &Scope.match?(&1, scope: alpha_scope))
    assert Enum.all?(alpha_packet.search_results, &Scope.match?(&1, scope: alpha_scope))
    assert Enum.any?(alpha_packet.mental_models, &(&1.id == alpha_model.id))
    refute Enum.any?(alpha_packet.mental_models, &(&1.id == beta_model.id))
    assert Enum.any?(alpha_packet.observations, &MapSet.member?(alpha_observation_ids, &1.id))
    refute Enum.any?(alpha_packet.observations, &MapSet.member?(beta_observation_ids, &1.id))
    assert Enum.all?(alpha_packet.observations, &Scope.match?(&1, scope: alpha_scope))

    assert [%{skills: alpha_skills}] = alpha_packet.knowledge
    assert Enum.any?(alpha_skills, &(&1.id == alpha_skill.id))
    refute Enum.any?(alpha_skills, &(&1.id == beta_skill.id))
    assert Enum.all?(alpha_skills, &Scope.match?(&1, scope: alpha_scope))

    assert {:ok, unscoped} =
             SpectreMnemonic.recall("isolation sentinel isolationsentinel", limit: 20)

    assert unscoped.moments == []
    assert unscoped.observations == []
    assert unscoped.mental_models == []
    assert unscoped.knowledge == []
    assert unscoped.search_results == []

    assert {:error, :multiple_scopes_not_allowed} =
             SpectreMnemonic.recall(
               "isolation sentinel isolationsentinel",
               scopes: :all,
               limit: 20
             )
  end

  test "durable and compact knowledge writes reject conflicting scope declarations" do
    alpha_scope = {:tenant, "write-alpha"}
    beta_scope = {:tenant, "write-beta"}

    assert {:error, {:scope_mismatch, ^alpha_scope, ^beta_scope}} =
             Manager.append(
               :knowledge,
               %{id: "wrong-scope", namespace: @namespace, scope: beta_scope, text: "private"},
               scope: alpha_scope
             )

    assert {:error, :inconsistent_memory_context} =
             Manager.append(
               :knowledge,
               %{
                 id: "conflicting-context",
                 namespace: @namespace,
                 scope: alpha_scope,
                 text: "private",
                 metadata: %{namespace: @namespace, scope: beta_scope}
               },
               scope: alpha_scope
             )

    assert {:error, {:scope_mismatch, ^alpha_scope, ^beta_scope}} =
             SpectreMnemonic.Knowledge.Base.append(
               %{type: :skill, name: "wrong", text: "private", scope: beta_scope},
               scope: alpha_scope
             )

    assert {:ok, alpha_records} = Manager.replay(scope: alpha_scope)

    refute Enum.any?(
             alpha_records,
             &(&1.source_event_id in ["wrong-scope", "conflicting-context"])
           )
  end

  test "governance blocks repeated and terminal-state consolidation" do
    scope = {:tenant, "governance"}

    assert {:ok, %{moment: moment}} =
             SpectreMnemonic.signal("governed durable memory", scope: scope, attention: 3.0)

    assert {:ok, [knowledge]} = SpectreMnemonic.consolidate(scope: scope)
    assert knowledge.id =~ ~r/^know_[0-9a-f]{8}-[0-9a-f]{4}-7/
    assert Governance.state_for(moment.id, scope: scope) == :promoted

    assert {:ok, []} = SpectreMnemonic.consolidate(scope: scope)

    assert :ok =
             Governance.append_state(
               moment.id,
               :contradicted,
               :manual_verification,
               scope: scope
             )

    assert {:ok, []} = SpectreMnemonic.consolidate(scope: scope)
    assert {:ok, packet} = SpectreMnemonic.recall("governed durable memory", scope: scope)
    refute Enum.any?(packet.moments, &(&1.id == moment.id))

    assert {:ok, %{moment: pinned}} =
             SpectreMnemonic.signal("pinned memory must not be re-promoted",
               scope: scope,
               memory_state: :pinned,
               attention: 3.0
             )

    assert Governance.state_for(pinned.id, scope: scope) == :pinned
    assert {:ok, []} = SpectreMnemonic.consolidate(scope: scope)

    assert {:ok, records} = Manager.replay(scope: scope)

    assert Enum.count(records, fn record ->
             record.family == :knowledge and Map.get(record.payload, :source_id) == moment.id
           end) == 1
  end

  test "a durable write failure never publishes a hot ETS projection" do
    Application.put_env(:spectre_mnemonic, :persistent_memory,
      failure_mode: :strict,
      stores: [
        [
          id: :failing,
          adapter: __MODULE__.FailingStore,
          role: :primary,
          duplicate: true,
          opts: []
        ]
      ]
    )

    Manager.reset_dedupe()
    scope = {:tenant, "failure"}

    assert {:error, {:persistent_memory_failed, _failures}} =
             SpectreMnemonic.signal("must not become visible", scope: scope)

    assert Focus.moments(scope: scope) == []
  end

  test "forget removes durable derivatives and all hot graph projections" do
    scope = {:tenant, "forget"}

    assert {:ok, %{moment: moment, action_recipe: recipe}} =
             SpectreMnemonic.signal("forget this deployment recipe",
               scope: scope,
               action_recipe: "run deployment cleanup"
             )

    assert {:ok, [_knowledge]} = SpectreMnemonic.consolidate(scope: scope)
    assert Focus.associations(scope: scope) != []

    assert {:ok, 1} = SpectreMnemonic.forget(moment.id, scope: scope)
    assert Focus.moments(scope: scope) == []
    assert Focus.associations(scope: scope) == []
    assert Focus.action_recipes([recipe.id], scope: scope) == []

    assert {:ok, records} = Manager.replay(scope: scope)

    refute Enum.any?(records, fn record ->
             record.family in [:moments, :signals, :knowledge, :associations, :action_recipes] and
               references?(record.payload, moment.id, moment.signal_id)
           end)
  end

  test "forget tombstones string-keyed durable derivatives" do
    scope = {:tenant, "forget-string-keys"}

    assert {:ok, %{moment: moment}} =
             SpectreMnemonic.signal("forget string keyed derivative", scope: scope)

    assert {:ok, _result} =
             Manager.append(
               :knowledge,
               %{
                 "id" => "string-derived",
                 "source_id" => moment.id,
                 "text" => "derived from a private moment"
               },
               scope: scope
             )

    assert {:ok, before_forget} = Manager.replay(scope: scope)

    assert Enum.any?(before_forget, fn record ->
             record.family == :knowledge and Map.get(record.payload, "id") == "string-derived"
           end)

    assert {:ok, 1} = SpectreMnemonic.forget(moment.id, scope: scope)
    assert {:ok, after_forget} = Manager.replay(scope: scope)

    refute Enum.any?(after_forget, fn record ->
             record.family == :knowledge and Map.get(record.payload, "id") == "string-derived"
           end)
  end

  test "forget fails closed when durable replay cannot enumerate derivatives" do
    scope = {:tenant, "forget-replay-error"}

    assert {:ok, %{moment: moment}} =
             SpectreMnemonic.signal("retain this when replay is unavailable", scope: scope)

    Application.put_env(:spectre_mnemonic, :persistent_memory,
      stores: [
        [
          id: :failing_replay,
          adapter: __MODULE__.FailingReplayStore,
          role: :primary,
          duplicate: true,
          opts: []
        ]
      ]
    )

    assert {:error, {:persistent_memory_replay_failed, _failures}} =
             SpectreMnemonic.forget(moment.id, scope: scope)

    assert Enum.map(Focus.moments(scope: scope), & &1.id) == [moment.id]
  end

  test "physical compaction snapshots live records, applies tombstones, and rotates active" do
    assert {:ok, _result} = Manager.append(:moments, %{id: "live", namespace: @namespace})
    assert {:ok, _result} = Manager.append(:moments, %{id: "dead", namespace: @namespace})

    assert {:ok, _result} =
             Manager.append(:tombstones, %{
               family: :moments,
               id: "dead",
               forgotten_at: DateTime.utc_now()
             })

    assert {:ok, [{:local_file, {:ok, snapshot}}]} = Manager.compact(mode: :physical)
    assert File.exists?(snapshot)
    assert File.exists?(Path.join(["mnemonic_data", "segments", "active.smem"]))
    assert Path.wildcard(Path.join(["mnemonic_data", "segments", "compacted-*.smem"])) != []

    assert {:ok, records} = Manager.replay()
    assert Enum.any?(records, &(&1.family == :moments and &1.payload.id == "live"))
    refute Enum.any?(records, &(&1.family == :moments and &1.payload.id == "dead"))
    refute Enum.any?(records, &(&1.family == :tombstones))
  end

  test "hot memory is bounded per scope" do
    Application.put_env(:spectre_mnemonic, :hot_memory,
      max_moments_per_scope: 2,
      max_moments_per_namespace: 10
    )

    scope = {:tenant, "bounded"}

    for index <- 1..3 do
      assert {:ok, _result} =
               SpectreMnemonic.signal("bounded #{index}", scope: scope, persist?: false)
    end

    moments = Focus.moments(scope: scope)
    assert length(moments) == 2
    refute Enum.any?(moments, &(&1.text == "bounded 1"))
  end

  test "search reuses one QueryContext embedding and returns one SearchResult shape" do
    assert {:ok, _result} = SpectreMnemonic.signal("single embedding search")

    Application.put_env(
      :spectre_mnemonic,
      :embedding_adapter,
      __MODULE__.CountingEmbedding
    )

    assert {:ok, results} =
             SpectreMnemonic.search("single embedding search", test_pid: self())

    assert_receive {:embedded, "single embedding search"}
    refute_receive {:embedded, _other}, 50
    assert Enum.all?(results, &match?(%SearchResult{}, &1))

    assert {:ok, packet} =
             SpectreMnemonic.recall("single embedding search", test_pid: self())

    assert %QueryContext{} = packet.query_context
  end

  defp references?(payload, moment_id, signal_id) when is_map(payload) do
    direct = [
      Map.get(payload, :id),
      Map.get(payload, :source_id),
      Map.get(payload, :memory_id),
      Map.get(payload, :signal_id),
      Map.get(payload, :target_id)
    ]

    moment_id in direct or signal_id in direct or
      moment_id in List.wrap(Map.get(payload, :source_ids, []))
  end

  defp references?(_payload, _moment_id, _signal_id), do: false

  defmodule FailingStore do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:append]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(%SpectreMnemonic.Persistence.Store.Record{}, _opts),
      do: {:error, :unavailable}
  end

  defmodule CountingEmbedding do
    @behaviour SpectreMnemonic.Embedding.Adapter

    @impl SpectreMnemonic.Embedding.Adapter
    def embed(input, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:embedded, input})
      {:ok, [1.0, 0.0]}
    end
  end

  defmodule FailingReplayStore do
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def capabilities(_opts), do: [:append, :replay]

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def put(_record, _opts), do: :ok

    @impl SpectreMnemonic.Persistence.Store.Adapter
    def replay(_opts), do: {:error, :unavailable}
  end
end
