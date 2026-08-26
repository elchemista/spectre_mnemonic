defmodule SpectreMnemonic.AuditRegressionTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.ETS, as: ActiveETS
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Export
  alias SpectreMnemonic.Knowledge.Base, as: KnowledgeBase
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Recall.Engine
  alias SpectreMnemonic.Recall.Index

  test "remember preserves map text and code verbatim with source-aligned chunks" do
    code =
      1..80
      |> Enum.map_join("\n", fn index ->
        "def fun_#{index}(a, b), do: {:ok, a + b + #{index}} # punctuation!"
      end)

    assert byte_size(code) > 4_096

    assert {:ok, packet} =
             SpectreMnemonic.remember(%{text: code, ignored: String.duplicate("x", 5_000)},
               chunk_words: 80,
               overlap_words: 20,
               extract_entities?: false
             )

    assert packet.root.text == code
    assert packet.root.kind == :structured_event
    assert length(packet.chunks) > 1

    Enum.each(packet.chunks, fn chunk ->
      start_byte = chunk.metadata.source_start_byte
      end_byte = chunk.metadata.source_end_byte
      assert chunk.text == binary_part(code, start_byte, end_byte - start_byte)
      assert chunk.text =~ "{:ok,"
    end)

    exact_320 = Enum.map_join(1..320, " ", &"token#{&1}")

    assert {:ok, exact_packet} =
             SpectreMnemonic.remember(exact_320,
               chunk_words: 180,
               overlap_words: 40,
               summaries?: false,
               categories?: false,
               extract_entities?: false
             )

    assert length(exact_packet.chunks) == 2
  end

  test "default phone classification redacts every stored and indexed projection" do
    scope = {:subject, "phone-redaction"}
    phone = "+39 333 123 4567"

    assert {:ok, packet} =
             SpectreMnemonic.remember("Bob phone is #{phone}.", scope: scope, persist?: true)

    rendered_packet = inspect(packet, limit: :infinity, printable_limit: :infinity)
    refute rendered_packet =~ phone
    assert packet.root.text =~ "[redacted phone]"

    assert {:ok, records} = Manager.replay(scope: scope)
    rendered_records = inspect(records, limit: :infinity, printable_limit: :infinity)
    refute rendered_records =~ phone

    refute Enum.any?(packet.moments, fn moment ->
             Enum.any?(moment.keywords, &(&1 in ["333", "123", "4567"]))
           end)
  end

  test "short intake keeps one verbatim anchor and reuses partition categories" do
    scope = {:subject, "quiet-intake"}

    assert {:ok, first} = SpectreMnemonic.remember("Alice called Bob", scope: scope)
    assert first.root.text == "Alice called Bob"
    assert first.chunks == []
    assert first.summaries == []
    assert length(first.moments) <= 7

    assert {:ok, second} = SpectreMnemonic.remember("Carol called Dave", scope: scope)

    first_categories = MapSet.new(Enum.map(first.categories, & &1.id))
    second_categories = MapSet.new(Enum.map(second.categories, & &1.id))
    assert MapSet.subset?(second_categories, first_categories)
  end

  test "lexical extraction rejects discourse hubs and does not steal a later number as age" do
    assert {:ok, packet} =
             SpectreMnemonic.remember("Marta is 34. The server is 3 nodes.")

    ages =
      Enum.filter(packet.moments, fn moment ->
        moment.kind == :memory_value and moment.metadata.value_kind == "age"
      end)

    assert Enum.map(ages, & &1.metadata.value) == ["34"]

    assert {:ok, discourse} =
             SpectreMnemonic.remember("However, the rollout failed.")

    refute Enum.any?(discourse.moments, fn moment ->
             moment.kind == :memory_entity and moment.metadata.canonical == "however"
           end)
  end

  test "signal kinds stay atoms and prose mentioning prompt or verify remains text" do
    assert {:ok, %{moment: chat}} =
             SpectreMnemonic.signal(%{kind: "user", text: "hello"}, persist?: false)

    assert chat.kind == :chat

    assert {:ok, prompt_prose} =
             SpectreMnemonic.remember("The prompt parser stores metadata.")

    assert prompt_prose.root.kind == :text

    assert {:ok, verify_prose} =
             SpectreMnemonic.remember("We verify metadata during normal processing.")

    assert verify_prose.root.kind == :text
  end

  test "raw phone storage requires the explicit raw mode" do
    phone = "+39 388 222 3333"

    assert {:ok, packet} =
             SpectreMnemonic.remember("Nora phone is #{phone}", sensitive_numbers: :raw)

    assert packet.root.text =~ phone
  end

  test "recall and flat search enforce one global limit without duplicate ids" do
    scope = {:subject, "query-contract"}

    Enum.each(1..6, fn index ->
      assert {:ok, _result} =
               SpectreMnemonic.signal("query contract repeated evidence #{index}",
                 scope: scope,
                 persist?: true
               )
    end)

    assert {:ok, packet} =
             SpectreMnemonic.recall("query contract evidence",
               scope: scope,
               limit: 2,
               max_tokens: 10_000,
               include_observations: false,
               include_mental_models: false,
               include_knowledge: false
             )

    assert length(packet.moments) <= 2

    assert {:ok, results} =
             SpectreMnemonic.search("query contract evidence", scope: scope, limit: 3)

    assert length(results) <= 3
    assert Enum.map(results, & &1.id) == Enum.uniq(Enum.map(results, & &1.id))
    assert Enum.all?(results, &(&1.score > 0.0))
  end

  test "forget removes PII from governance replay, knowledge search, and export" do
    scope = {:subject, "forgotten-pii"}
    email = "private.audit@example.com"
    export_path = Path.expand("mnemonic_data/forgotten-pii.mnemonic")

    assert {:ok, %{moment: moment}} =
             SpectreMnemonic.signal("AuditOwner email is #{email}",
               scope: scope,
               persist?: true
             )

    assert {:ok, _sequence} =
             KnowledgeBase.append(
               %{type: :fact, text: "AuditOwner email is #{email}", source_id: moment.id},
               scope: scope
             )

    assert {:ok, [_result | _]} =
             KnowledgeBase.search("private audit", scope: scope, limit: 10)

    assert {:ok, 1} = SpectreMnemonic.forget(moment.id, scope: scope)
    assert {:ok, []} = KnowledgeBase.search("private audit", scope: scope, limit: 10)

    assert {:ok, records} = Manager.replay(scope: scope)
    refute inspect(records, limit: :infinity, printable_limit: :infinity) =~ email

    forgotten_states =
      records
      |> Enum.filter(&(&1.family == :memory_states))
      |> Enum.map(& &1.payload)

    assert Enum.any?(forgotten_states, &(&1.memory_id == moment.id and &1.state == :forgotten))
    assert Enum.all?(forgotten_states, &(not Map.has_key?(&1.metadata, :fact_value)))

    assert {:ok, _report} =
             SpectreMnemonic.export(export_path,
               scope: scope,
               mode: :full,
               active?: false
             )

    assert {:ok, export} = Export.read(export_path)
    refute inspect(export, limit: :infinity, printable_limit: :infinity) =~ email
  end

  test "observations follow governance when a repeated fact is replaced" do
    scope = {:subject, "observation-governance"}

    Enum.each(1..2, fn _index ->
      assert {:ok, _result} =
               SpectreMnemonic.signal("AuditOwner email is old.audit@example.com",
                 scope: scope,
                 persist?: true
               )
    end)

    assert {:ok, %{moment: current}} =
             SpectreMnemonic.signal("AuditOwner email is new.audit@example.com",
               scope: scope,
               persist?: true
             )

    assert {:ok, [observation]} =
             SpectreMnemonic.consolidate_observations(scope: scope)

    assert observation.statement == "auditowner email is new.audit@example.com"
    assert observation.source_ids == [current.id]
    assert observation.state == :candidate
  end

  test "hot bounds are config-only, attention-aware, and never evict pinned memory" do
    pinned_scope = {:subject, "pinned-bound"}

    Application.put_env(:spectre_mnemonic, :hot_memory,
      max_moments_per_scope: 1,
      max_moments_per_namespace: 100
    )

    assert {:ok, %{moment: pinned}} =
             SpectreMnemonic.signal("pinned audit memory",
               scope: pinned_scope,
               persist?: true,
               memory_state: :pinned
             )

    assert {:ok, %{moment: rejected_by_bound}} =
             SpectreMnemonic.signal("ordinary audit memory",
               scope: pinned_scope,
               persist?: false
             )

    assert Enum.map(Focus.moments(scope: pinned_scope), & &1.id) == [
             pinned.id
           ]

    refute ActiveETS.member(:mnemonic_moments, rejected_by_bound.id)

    Application.put_env(:spectre_mnemonic, :hot_memory,
      max_moments_per_scope: 2,
      max_moments_per_namespace: 100,
      recall_reinforcement: 0.5
    )

    config_scope = {:subject, "config-only-bound"}

    assert {:ok, %{moment: config_only}} =
             SpectreMnemonic.signal("caller cannot erase this partition",
               scope: config_scope,
               persist?: false,
               max_moments_per_scope: 0,
               max_moments_per_namespace: 0
             )

    assert ActiveETS.member(:mnemonic_moments, config_only.id)

    attention_scope = {:subject, "attention-bound"}

    assert {:ok, %{moment: recalled}} =
             SpectreMnemonic.signal("quartz priority anchor",
               scope: attention_scope,
               persist?: false
             )

    assert {:ok, %{moment: unused}} =
             SpectreMnemonic.signal("zephyr unused anchor",
               scope: attention_scope,
               persist?: false
             )

    assert {:ok, packet} =
             SpectreMnemonic.recall("quartz priority",
               scope: attention_scope,
               include_observations: false,
               include_mental_models: false,
               include_knowledge: false,
               plasticity?: false
             )

    assert Enum.any?(packet.moments, &(&1.id == recalled.id))

    assert {:ok, %{moment: newest}} =
             SpectreMnemonic.signal("newest neutral anchor",
               scope: attention_scope,
               persist?: false
             )

    ids =
      MapSet.new(Enum.map(Focus.moments(scope: attention_scope), & &1.id))

    assert MapSet.member?(ids, recalled.id)
    assert MapSet.member?(ids, newest.id)
    refute MapSet.member?(ids, unused.id)
  end

  test "independent partitions write concurrently without stream workers" do
    results =
      1..40
      |> Task.async_stream(
        fn index ->
          scope = {:subject, "concurrent-#{index}"}

          SpectreMnemonic.signal("parallel memory #{index}",
            scope: scope,
            task_id: "task-#{index}",
            persist?: false
          )
        end,
        max_concurrency: 20,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert length(results) == 40
    assert results |> Enum.map(& &1.moment.id) |> Enum.uniq() |> length() == 40

    Enum.each(results, fn result ->
      assert ActiveETS.member(:mnemonic_moments, result.moment.id)
    end)
  end

  test "recall and Vettore queries execute outside their coordinator GenServers" do
    scope = {:subject, "caller-owned-query"}

    assert {:ok, %{moment: moment}} =
             SpectreMnemonic.signal("caller-owned semantic query",
               scope: scope,
               persist?: false,
               embedding: [1.0, 0.0]
             )

    cue = %{
      vector: Vector.normalize_to_f32_binary([1.0, 0.0]),
      binary_signature: moment.binary_signature
    }

    refute Process.whereis(Engine)
    index = Index.server([])
    :sys.suspend(index)

    try do
      assert {:ok, [%{id: id} | _rest]} = Index.query(cue, scope: scope, overfetch: 1)
      assert id == moment.id

      assert {:ok, packet} =
               SpectreMnemonic.recall("caller-owned semantic query",
                 scope: scope,
                 include_observations: false,
                 include_mental_models: false,
                 include_knowledge: false,
                 plasticity?: false
               )

      assert Enum.any?(packet.moments, &(&1.id == moment.id))
    after
      :sys.resume(index)
    end
  end
end
