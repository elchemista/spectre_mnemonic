defmodule SpectreMnemonicStressTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Embedding.Vector

  @moduletag timeout: 30_000

  @scenario_kinds [
    :birthday,
    :task_status,
    :task_relation,
    :research,
    :code_learning,
    :task_execution,
    :meeting,
    :deadline,
    :decision,
    :artifact
  ]

  @doc "Builds varied, deterministic scenarios for broad recall coverage."
  def scenario(index) do
    kind = Enum.at(@scenario_kinds, rem(index - 1, length(@scenario_kinds)))
    subject = "Subject#{index}"
    task_id = "task-#{div(index - 1, length(@scenario_kinds)) + 1}"
    date = Date.add(~D[2026-01-01], index)

    case kind do
      :birthday ->
        %{
          kind: :personal_fact,
          stream: :chat,
          task_id: nil,
          text: "#{subject} birthday is #{Date.to_iso8601(date)} and the party city is Rome",
          cue: "when is #{subject} birthday",
          token: Date.to_iso8601(date)
        }

      :task_status ->
        %{
          kind: :task_status,
          stream: :task_execution,
          task_id: task_id,
          text: "#{task_id} status is blocked by missing migration for #{subject}",
          cue: "how is it going #{task_id}",
          token: "blocked"
        }

      :task_relation ->
        %{
          kind: :task_relation,
          stream: :research,
          task_id: task_id,
          text: "#{task_id} depends on #{subject} API contract and schema review",
          cue: "what is related to #{task_id} API contract",
          token: "contract"
        }

      :research ->
        %{
          kind: :research,
          stream: :research,
          task_id: task_id,
          text: "research note #{subject}: ETS ordered_set lookup tradeoff for #{task_id}",
          cue: "recall research #{subject} ETS lookup",
          token: "ordered_set"
        }

      :code_learning ->
        %{
          kind: :code_learning,
          stream: :code_learning,
          task_id: task_id,
          text:
            "code learning #{subject}: StreamServer forwards writes through Focus for #{task_id}",
          cue: "what code insight mentions #{subject} StreamServer",
          token: "Focus"
        }

      :task_execution ->
        %{
          kind: :task_execution,
          stream: :task_execution,
          task_id: task_id,
          text: "execution update #{subject}: implemented disk replay checksum for #{task_id}",
          cue: "progress #{subject} disk replay checksum",
          token: "checksum"
        }

      :meeting ->
        %{
          kind: :meeting,
          stream: :chat,
          task_id: task_id,
          text: "meeting #{subject} scheduled on #{Date.to_iso8601(date)} about release review",
          cue: "meeting #{subject} release review",
          token: "scheduled"
        }

      :deadline ->
        %{
          kind: :deadline,
          stream: :chat,
          task_id: task_id,
          text: "#{subject} deadline is #{Date.to_iso8601(date)} for docs cleanup",
          cue: "#{subject} deadline docs cleanup",
          token: Date.to_iso8601(date)
        }

      :decision ->
        %{
          kind: :decision,
          stream: :chat,
          task_id: task_id,
          text: "decision #{subject}: use hamming fallback before vector adapter exists",
          cue: "decision #{subject} hamming fallback",
          token: "fallback"
        }

      :artifact ->
        %{
          kind: :artifact_note,
          stream: :chat,
          task_id: task_id,
          text: "artifact #{subject} lives at /tmp/#{subject}.pdf for #{task_id}",
          cue: "artifact #{subject} pdf",
          token: ".pdf"
        }
    end
  end

  for index <- 1..100 do
    test "scenario #{index}: adapter-free recall finds varied memory" do
      scenario = scenario(unquote(index))

      {:ok, %{moment: moment}} =
        SpectreMnemonic.signal(scenario.text,
          stream: scenario.stream,
          task_id: scenario.task_id,
          kind: scenario.kind
        )

      assert moment.vector == nil
      assert is_integer(moment.fingerprint)

      assert {:ok, packet} = SpectreMnemonic.recall(scenario.cue, limit: 5)
      assert Enum.any?(packet.moments, &(&1.id == moment.id))
      assert Enum.any?(packet.moments, &String.contains?(&1.text, scenario.token))
    end
  end

  test "parallel task memory ingestion keeps all task statuses addressable" do
    task_count = 50

    1..task_count
    |> Task.async_stream(
      fn index ->
        SpectreMnemonic.signal("parallel task #{index} completed checkpoint #{index}",
          task_id: "parallel-#{index}",
          stream: :task_execution,
          kind: :task_execution
        )
      end,
      max_concurrency: 12,
      timeout: 5_000
    )
    |> Enum.each(fn
      {:ok, {:ok, %{moment: moment}}} -> assert moment.stream == :task_execution
      other -> flunk("unexpected async result: #{inspect(other)}")
    end)

    for index <- 1..task_count do
      assert {:ok, status} = SpectreMnemonic.status("parallel-#{index}")
      assert status.task_id == "parallel-#{index}"
    end
  end

  test "linked task neighborhoods include related research and code moments" do
    {:ok, %{moment: task}} =
      SpectreMnemonic.signal("task alpha executing payment retry fix",
        task_id: "alpha",
        stream: :task_execution
      )

    {:ok, %{moment: research}} =
      SpectreMnemonic.signal("research alpha Stripe retry semantics",
        task_id: "alpha",
        stream: :research
      )

    {:ok, %{moment: code}} =
      SpectreMnemonic.signal("code alpha retry module touches payment worker",
        task_id: "alpha",
        stream: :code_learning
      )

    assert {:ok, _} = SpectreMnemonic.link(task.id, :supported_by, research.id)
    assert {:ok, _} = SpectreMnemonic.link(task.id, :implemented_by, code.id)

    assert {:ok, packet} = SpectreMnemonic.recall("how is it going alpha retry")

    ids = MapSet.new(Enum.map(packet.moments, & &1.id))
    assert MapSet.member?(ids, task.id)
    assert MapSet.member?(ids, research.id)
    assert MapSet.member?(ids, code.id)
  end

  test "date-like birthday facts remain recallable without embeddings" do
    {:ok, %{moment: birthday}} =
      SpectreMnemonic.signal("Marta birthday is 1988-07-14 and favorite cake is lemon",
        stream: :chat
      )

    assert {:ok, packet} = SpectreMnemonic.recall("Marta birthday date")
    assert Enum.any?(packet.moments, &(&1.id == birthday.id))
    assert Enum.any?(packet.moments, &String.contains?(&1.text, "1988-07-14"))
  end

  test "forgetting a task removes every selected active moment" do
    for index <- 1..5 do
      assert {:ok, _} =
               SpectreMnemonic.signal("cleanup task memory #{index}",
                 task_id: "forget-me",
                 stream: :task_execution
               )
    end

    assert {:ok, 5} = SpectreMnemonic.forget({:task, "forget-me"})
    assert {:ok, packet} = SpectreMnemonic.recall("cleanup task memory")
    refute Enum.any?(packet.moments, &(&1.task_id == "forget-me"))
  end

  test "empty and punctuation-only cues do not return attention-only matches" do
    {:ok, _} = SpectreMnemonic.signal("valuable unrelated memory", attention: 10.0)

    assert {:ok, empty_packet} = SpectreMnemonic.recall("")
    assert empty_packet.moments == []

    assert {:ok, punctuation_packet} = SpectreMnemonic.recall("!!! ???")
    assert punctuation_packet.moments == []
  end

  test "vector adapter is preferred over hamming when vectors are available" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.TwoVectorAdapter)

    {:ok, %{moment: vector_match}} = SpectreMnemonic.signal("vector apple memory")
    {:ok, %{moment: vector_miss}} = SpectreMnemonic.signal("vector orange memory")

    assert {:ok, packet} = SpectreMnemonic.recall("vector apple query", limit: 2)
    assert hd(packet.moments).id == vector_match.id
    assert Enum.any?(packet.moments, &(&1.id == vector_miss.id))
  after
    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
  end

  test "rich adapter result stores vector and metadata" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.RichAdapter)

    assert {:ok, %{moment: moment}} = SpectreMnemonic.signal("rich embedding")
    assert is_binary(moment.vector)
    assert Vector.dimensions(moment.vector) == 2
    assert moment.embedding.metadata.provider == :test
    assert moment.embedding.metadata.dimensions == 2
  after
    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
  end

  test "metadata stream routing is used when no explicit stream exists" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("metadata routed memory",
        metadata: %{stream: :metadata_lane},
        task_id: nil
      )

    assert moment.stream == :metadata_lane
    assert {:ok, status} = SpectreMnemonic.status(:metadata_lane)
    assert status.stream == :metadata_lane
  end

  test "invalid links reject missing source and target ids" do
    {:ok, %{moment: moment}} = SpectreMnemonic.signal("valid memory")

    assert {:error, :unknown_memory_id} =
             SpectreMnemonic.link("missing-source", :relates_to, moment.id)

    assert {:error, :unknown_memory_id} =
             SpectreMnemonic.link(moment.id, :relates_to, "missing-target")
  end

  test "disk replay contains appended signal and moment records" do
    {:ok, %{signal: signal, moment: moment}} = SpectreMnemonic.signal("disk replay visible")

    assert {:ok, frames} = SpectreMnemonic.Store.Disk.replay()
    payloads = Enum.map(frames, fn {_seq, _timestamp, payload} -> payload end)

    assert {:signals, signal} in payloads
    assert {:moments, moment} in payloads
  end

  test "disk replay ignores incomplete trailing frames" do
    {:ok, %{signal: signal}} = SpectreMnemonic.signal("disk trailing corruption survives")

    File.write!(Path.join(["mnemonic_data", "segments", "active.smem"]), "partial-frame", [
      :append
    ])

    assert {:ok, frames} = SpectreMnemonic.Store.Disk.replay()
    payloads = Enum.map(frames, fn {_seq, _timestamp, payload} -> payload end)

    assert {:signals, signal} in payloads
  end

  test "artifact records are hydrated through linked recall neighborhoods" do
    {:ok, artifact} = SpectreMnemonic.artifact("/tmp/edge-report.pdf")
    {:ok, %{moment: moment}} = SpectreMnemonic.signal("edge report artifact note")
    {:ok, _} = SpectreMnemonic.link(moment.id, :mentions, artifact.id)

    assert {:ok, packet} = SpectreMnemonic.recall("edge report artifact")
    assert packet.associations != []
    assert Enum.any?(packet.artifacts, &(&1.id == artifact.id))
  end

  test "active status is deduplicated even when stream and task id point to same status" do
    {:ok, _} =
      SpectreMnemonic.signal("deduplicated status task is active",
        task_id: "case-task",
        stream: :task_execution
      )

    assert {:ok, lowercase} = SpectreMnemonic.recall("how is it going case-task")
    statuses = Enum.filter(lowercase.active_status, &(&1.task_id == "case-task"))
    assert length(statuses) == 1
  end

  defmodule TwoVectorAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    def embed(input, _opts) do
      text = if is_binary(input), do: input, else: inspect(input)

      if String.contains?(text, "apple") do
        {:ok, [1.0, 0.0]}
      else
        {:ok, [0.0, 1.0]}
      end
    end
  end

  defmodule RichAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    def embed(_input, _opts) do
      {:ok, %{vector: [0.2, 0.8], provider: :test, dimensions: 2, model: "fake"}}
    end
  end
end
