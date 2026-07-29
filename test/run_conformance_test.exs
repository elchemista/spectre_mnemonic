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

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Input.Source
  alias Spectre.Mnemonic.Memory
  alias Spectre.Result
  alias Spectre.Route
  alias Spectre.Run
  alias Spectre.Runtime
  alias Spectre.State
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

  test "committed turns retain logical lifecycle context and discard runtime identities" do
    input = %Input{
      text: "logical input",
      source: %Source{
        kind: :test,
        conversation_id: "source-conversation",
        actor_id: "actor-1"
      }
    }

    route = %Route{
      label: :remember,
      flow: :memory,
      scope: {:unsafe, self()},
      strategy: :regex,
      confidence: 1.0,
      accepted?: true
    }

    effect = %Effect{
      id: {:effect, 1},
      kind: :action,
      name: :store,
      status: :completed,
      mode: :sync
    }

    awaitable = %Awaitable{
      id: {:awaitable, 1},
      kind: :policy,
      status: :accepted,
      subject_id: {:effect, 1}
    }

    result = %Result{
      input: input,
      state: %State{conversation_id: {:conversation, 42}},
      reply_text: "logical reply",
      route: route,
      effects: [effect, :invalid],
      awaitables: [awaitable, :invalid],
      events: [%{type: :routed}, "committed", %{unexpected: true}],
      metadata: %{
        run: %{
          id: "run-1",
          revision: 2,
          status: :complete,
          cursor: :complete,
          step_id: "step-2",
          runtime_client: self()
        }
      }
    }

    assert {:ok, packet} =
             Memory.remember(input, result, Agent,
               namespace: "spectre_mnemonic_test",
               stream: unique_stream("logical-turn")
             )

    metadata = packet.root.metadata
    assert packet.root.text =~ "logical input"
    assert metadata.conversation_id == {:conversation, 42}
    assert metadata.route.scope == nil

    assert metadata.effects == [
             %{id: {:effect, 1}, kind: :action, mode: :sync, name: :store, status: :completed},
             %{}
           ]

    assert metadata.awaitables == [
             %{
               id: {:awaitable, 1},
               kind: :policy,
               status: :accepted,
               subject_id: {:effect, 1}
             },
             %{}
           ]

    assert metadata.events == [:routed, "committed", :event]

    assert metadata.run == %{
             id: "run-1",
             revision: 2,
             status: :complete,
             cursor: :complete,
             step_id: "step-2"
           }
  end

  test "legacy payload projection is durable and missing Agent context fails closed" do
    input = Input.new("legacy input")

    payload = %{
      input: input,
      reply_text: "legacy reply",
      route: :invalid,
      state: nil,
      effects: [],
      awaitables: [],
      events: []
    }

    assert {:ok, packet} =
             Memory.remember(payload,
               agent: Agent,
               namespace: "spectre_mnemonic_test",
               stream: unique_stream("legacy-turn")
             )

    assert packet.persistence.durable?
    assert packet.root.text =~ "legacy input"
    assert packet.root.metadata.route == nil
    assert packet.root.metadata.conversation_id == nil
    assert packet.root.metadata.run == nil

    assert {:ok, plain_packet} =
             Memory.remember("plain legacy payload",
               agent: Agent,
               namespace: "spectre_mnemonic_test",
               stream: unique_stream("plain-turn")
             )

    assert plain_packet.persistence.durable?

    assert {:error, :mnemonic_agent_required} = Memory.remember("missing agent", [])
    assert {:error, :mnemonic_agent_required} = Memory.recall("missing agent", [])
  end

  defp unique_stream(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
