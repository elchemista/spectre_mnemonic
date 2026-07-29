defmodule SpectreMnemonic.RunConformanceTest.Stack do
  @moduledoc false

  use Spectre.Stack, id: :mnemonic_run_conformance

  install Spectre.Mnemonic, namespace: :mnemonic_run_conformance do
    isolate_by([:agent, :conversation])
  end
end

defmodule SpectreMnemonic.RunConformanceTest.Handler do
  @moduledoc false
  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply

  @impl true
  def handle_turn(request, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:mnemonic_recalled, request.memory})
    {:reply, Reply.new("memory re-resolved")}
  end
end

defmodule SpectreMnemonic.RunConformanceTest.Agent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreMnemonic.RunConformanceTest.Stack
  turn_handler(SpectreMnemonic.RunConformanceTest.Handler)
end

defmodule SpectreMnemonic.RunConformanceTest do
  use ExUnit.Case, async: false

  alias Spectre.Run
  alias Spectre.Runtime
  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.State
  alias Spectre.Mnemonic.Memory
  alias SpectreMnemonic.RunConformanceTest.Agent

  test "restored Runs re-resolve memory and never checkpoint the recalled value or runtime handles" do
    namespace = "spectre_mnemonic_test"
    marker = "memory-after-checkpoint-#{System.unique_integer([:positive])}"

    assert {:continue, run} =
             Runtime.start(Agent, marker,
               namespace: namespace,
               conversation_id: "conversation-1"
             )

    assert {:ok, checkpoint} = Run.checkpoint(run)
    assert {:ok, restored} = Run.restore(checkpoint)
    assert restored.id == run.id
    refute Map.has_key?(restored.metadata, :memory)

    assert {:ok, _packet} =
             SpectreMnemonic.remember(marker,
               namespace: namespace,
               stream: :run_conformance,
               scope:
                 {:spectre,
                  [
                    agent: Agent,
                    conversation: "conversation-1"
                  ]},
               persist?: false
             )

    assert {:boundary, %{kind: :reply}, advanced} =
             Runtime.advance(restored,
               namespace: namespace,
               conversation_id: "conversation-1",
               test_pid: self()
             )

    assert advanced.id == restored.id

    assert_receive {:mnemonic_recalled, %SpectreMnemonic.Recall.Packet{} = recalled}, 2_000
    assert recalled.query_context.text == marker
    assert Enum.any?(recalled.moments, &String.contains?(&1.text, marker))
  end

  test "the committed-turn callback records a durable logical projection" do
    input = Input.new("remember the committed turn")
    result = %Result{input: input, state: %State{}, reply_text: "turn committed"}

    assert {:ok, packet} =
             Memory.remember(input, result, Agent,
               namespace: "spectre_mnemonic_test",
               conversation_id: "conversation-durable"
             )

    assert packet.persistence == %{mode: :immediate, durable?: true}
    assert String.contains?(packet.root.text, "remember the committed turn")
    assert packet.root.metadata.source == :spectre
  end
end
