defmodule SpectreMnemonic.Knowledge.SMEMTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Knowledge.SMEM

  test "knowledge smem appends and replays compact events" do
    assert {:ok, first_seq} =
             SMEM.append(%{
               type: :fact,
               text: "Spectre keeps progressive knowledge in a compact event log"
             })

    assert {:ok, second_seq} =
             SMEM.append(%{
               type: :skill,
               name: "recall-triage",
               steps: ["load compact knowledge", "recall active focus"]
             })

    assert first_seq > 0
    assert second_seq > first_seq

    assert {:ok, events} = SMEM.replay()

    assert Enum.map(events, & &1.type) == [:fact, :skill]
    assert Enum.at(events, 0).text =~ "compact event log"
    assert Enum.at(events, 1).name == "recall-triage"
    assert File.exists?(Path.join(["mnemonic_data", "knowledge", "knowledge.smem"]))
  end

  test "knowledge smem reduces framed events without full replay" do
    {:ok, _} = SMEM.append(%{type: :fact, text: "folded fact"})
    {:ok, _} = SMEM.append(%{type: :skill, name: "folded-skill", steps: ["reduce"]})

    assert {:ok, frames} =
             SMEM.reduce([], [], fn {seq, _timestamp, event}, acc ->
               {:cont, [{seq, event.type} | acc]}
             end)

    [{first_seq, :fact}, {second_seq, :skill}] = Enum.reverse(frames)
    assert second_seq > first_seq
  end

  test "load knowledge respects item and byte budgets" do
    Application.put_env(:spectre_mnemonic, :knowledge,
      max_loaded_bytes: 1_200,
      max_latest_ingestions: 1,
      max_skills: 1,
      max_facts: 1,
      max_procedures: 1
    )

    {:ok, _} = SMEM.append(%{type: :summary, summary: "Compact project memory"})
    {:ok, _} = SMEM.append(%{type: :skill, name: "first", steps: ["a"]})
    {:ok, _} = SMEM.append(%{type: :skill, name: "second", steps: ["b"]})
    {:ok, _} = SMEM.append(%{type: :latest_ingestion, text: "newest note"})
    {:ok, _} = SMEM.append(%{type: :latest_ingestion, text: "older note"})
    {:ok, _} = SMEM.append(%{type: :fact, text: "fact one"})
    {:ok, _} = SMEM.append(%{type: :fact, text: "fact two"})

    assert {:ok, knowledge} = SpectreMnemonic.load_knowledge()

    assert knowledge.summary == "Compact project memory"
    assert length(knowledge.skills) <= 1
    assert length(knowledge.latest_ingestions) <= 1
    assert length(knowledge.facts) <= 1
    assert knowledge.metadata.loaded_bytes <= 1_200
  end

  test "search knowledge returns targeted scored events without loading active moments" do
    {:ok, _} = SMEM.append(%{type: :summary, summary: "Global compact memory"})

    {:ok, _} =
      SMEM.append(%{type: :fact, text: "Postgres adapter stores vector metadata"})

    {:ok, _} =
      SMEM.append(%{type: :skill, name: "sqlite-debug", steps: ["inspect jobs"]})

    before_count = length(SpectreMnemonic.Active.Focus.moments())

    assert {:ok, [result | rest]} = SpectreMnemonic.search_knowledge("postgres vector", limit: 2)

    assert result.type == :fact
    assert result.event.text =~ "Postgres"
    assert result.score > 0
    assert length(rest) <= 1
    assert length(SpectreMnemonic.Active.Focus.moments()) == before_count
  end

  test "default compaction writes compact replacement events without markdown files" do
    {:ok, _} =
      SpectreMnemonic.signal(
        "Reusable skill: check compact knowledge before broad durable search",
        kind: :memory_summary,
        attention: 5.0
      )

    {:ok, _} =
      SpectreMnemonic.signal("Latest ingestion about user wanting knowledge.smem only",
        kind: :text,
        attention: 2.0
      )

    assert {:ok, %{events: events, count: count}} = SpectreMnemonic.compact_knowledge()

    assert count == length(events)
    assert Enum.any?(events, &(&1.type == :summary))
    assert Enum.any?(events, &(&1.type == :latest_ingestion))
    assert Enum.any?(events, &(&1.type == :compaction_marker))
    assert Path.wildcard(Path.join(["mnemonic_data", "knowledge", "**", "*.md"])) == []
  end

  test "custom compact adapter output is normalized into knowledge events" do
    Application.put_env(:spectre_mnemonic, :compact_adapter, __MODULE__.CustomCompactAdapter)

    {:ok, _} = SpectreMnemonic.signal("active memory for adapter", attention: 3.0)

    assert {:ok, %{events: events}} = SpectreMnemonic.compact_knowledge(test_pid: self())
    assert_receive {:compact_called, %{moments: [_ | _], existing_events: []}}

    assert Enum.any?(events, &(&1.type == :summary and &1.summary == "adapter summary"))
    assert Enum.any?(events, &(&1.type == :skill and &1.name == "adapter-skill"))
    assert Enum.any?(events, &(&1.type == :latest_ingestion and &1.text == "adapter latest"))
  end

  test "recall includes compact knowledge without hydrating active moments" do
    {:ok, _} = SMEM.append(%{type: :summary, summary: "Recall should attach this"})
    {:ok, _} = SMEM.append(%{type: :fact, text: "durable compact fact"})
    {:ok, %{moment: moment}} = SpectreMnemonic.signal("active recall anchor")

    before_count = length(SpectreMnemonic.Active.Focus.moments())

    assert {:ok, packet} = SpectreMnemonic.recall("active recall anchor")

    assert Enum.any?(packet.moments, &(&1.id == moment.id))

    assert [%SpectreMnemonic.Knowledge.Record{summary: "Recall should attach this"}] =
             packet.knowledge

    assert length(SpectreMnemonic.Active.Focus.moments()) == before_count
  end

  test "learn stores a text skill with bullet steps in compact knowledge" do
    assert {:ok, %{event: event, seq: seq}} =
             SpectreMnemonic.learn("""
             Debug replay
             - inspect segments
             - check tombstones
             """)

    assert seq > 0
    assert event.type == :skill
    assert event.name == "Debug replay"
    assert event.steps == ["inspect segments", "check tombstones"]
    assert event.text =~ "Debug replay"
    assert event.metadata.source == :learn

    assert {:ok, knowledge} = SpectreMnemonic.load_knowledge()
    assert Enum.any?(knowledge.skills, &(&1.name == "Debug replay"))
  end

  test "learn stores a plain paragraph skill with a single step" do
    text = "Always inspect replay segments before compaction. Check tombstones after replay."

    assert {:ok, %{event: event}} = SpectreMnemonic.learn(text)

    assert event.name == "Always inspect replay segments before compaction."
    assert event.steps == [text]
    assert event.text == text
  end

  test "learn accepts structured skills with rules examples and metadata" do
    assert {:ok, %{event: event}} =
             SpectreMnemonic.learn(%{
               name: "Review payment retries",
               steps: ["inspect retry window", "check provider response"],
               rules: ["never expose secret keys"],
               examples: ["Stripe retry after timeout"],
               metadata: %{domain: :payments}
             })

    assert event.name == "Review payment retries"
    assert event.steps == ["inspect retry window", "check provider response"]
    assert event.metadata.rules == ["never expose secret keys"]
    assert event.metadata.examples == ["Stripe retry after timeout"]
    assert event.metadata.domain == :payments
  end

  test "learned skills are searchable and included in recall knowledge" do
    assert {:ok, _result} =
             SpectreMnemonic.learn("""
             Replay triage
             - inspect segment checksums
             - verify tombstone suppression
             """)

    assert {:ok, [result | _rest]} = SpectreMnemonic.search_knowledge("segment tombstone")
    assert result.type == :skill
    assert result.event.name == "Replay triage"

    assert {:ok, packet} = SpectreMnemonic.recall("how to debug replay tombstones")
    assert [%SpectreMnemonic.Knowledge.Record{} = knowledge] = packet.knowledge
    assert Enum.any?(knowledge.skills, &(&1.name == "Replay triage"))
  end

  test "learn rejects empty and invalid skills" do
    assert {:error, :empty_skill} = SpectreMnemonic.learn(" \n\t ")

    assert {:error, {:invalid_skill, :missing_name}} =
             SpectreMnemonic.learn(%{name: "", steps: ["do one thing"]})

    assert {:error, {:invalid_skill, :missing_content}} =
             SpectreMnemonic.learn(%{name: "Empty procedure", steps: []})

    assert {:error, {:invalid_skill, :unsupported_input}} = SpectreMnemonic.learn([:not_keyword])
  end

  test "learn persists skill events in knowledge smem replay" do
    assert {:ok, %{event: event}} =
             SpectreMnemonic.learn("Cache diagnosis\n1. inspect cache headers\n2. compare etags")

    assert {:ok, events} = SMEM.replay()
    assert Enum.any?(events, &(&1.type == :skill and &1.id == event.id))
    assert Enum.any?(events, &(&1.name == "Cache diagnosis"))
  end

  test "old knowledge structs with text only still work" do
    knowledge = %SpectreMnemonic.Knowledge.Record{
      id: "know_old",
      source_id: "mom_1",
      text: "old durable knowledge"
    }

    assert knowledge.text == "old durable knowledge"
    assert knowledge.skills == []
    assert knowledge.latest_ingestions == []
    assert knowledge.facts == []
    assert knowledge.procedures == []
    assert knowledge.usage == %{}
  end

  defmodule CustomCompactAdapter do
    @behaviour SpectreMnemonic.Knowledge.Compact.Adapter

    @impl true
    def compact(input, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:compact_called, input})

      {:ok,
       %{
         summary: "adapter summary",
         skills: [%{name: "adapter-skill", steps: ["one", "two"]}],
         latest_ingestions: ["adapter latest"],
         facts: ["adapter fact"],
         procedures: [%{text: "adapter procedure"}]
       }}
    end
  end
end
