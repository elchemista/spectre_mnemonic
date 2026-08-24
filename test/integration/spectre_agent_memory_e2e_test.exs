defmodule SpectreMnemonic.SpectreAgentMemoryE2ETest.Stack do
  @moduledoc false

  use Spectre.Stack, id: :mnemonic_agent_memory_e2e

  install Spectre.Mnemonic, namespace: :spectre_mnemonic_test do
    isolate_by([:agent, :subject])
  end
end

defmodule SpectreMnemonic.SpectreAgentMemoryE2ETest.Handler do
  @moduledoc false
  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply
  alias SpectreMnemonic.Recall.Packet

  @email ~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/iu
  @reference ~r/\b[A-Z]{2,10}-\d+\b/u

  @impl true
  def handle_turn(request, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:agent_recalled, request.input.text, request.memory})

    response = answer(request.input.text, memory_text(request.memory))
    {:reply, Reply.new(response)}
  end

  defp answer(question, memory) do
    normalized = String.downcase(question)

    cond do
      String.contains?(normalized, "what question") and String.contains?(normalized, "email") ->
        remembered_question(memory, "email")

      String.contains?(normalized, "who owns") ->
        remembered_owner(question, memory)

      String.contains?(normalized, "what deployment reference") ->
        remembered_reference(memory)

      asks_for_email?(normalized) and String.ends_with?(question, "?") ->
        remembered_email(memory)

      String.starts_with?(normalized, "remember") ->
        "I will remember it."

      true ->
        "I do not have that information."
    end
  end

  defp asks_for_email?(question) do
    Enum.any?(["email", "contact", "notification", "recovery", "delivered"], fn term ->
      String.contains?(question, term)
    end)
  end

  defp remembered_email(memory) do
    case Regex.run(@email, memory) do
      [email] -> "Your primary email is #{email}."
      nil -> "I do not have that information."
    end
  end

  defp remembered_reference(memory) do
    case Regex.run(@reference, memory) do
      [reference] -> "The deployment reference is #{reference}."
      nil -> "I do not have that information."
    end
  end

  defp remembered_owner(question, memory) do
    with [reference] <- Regex.run(@reference, question),
         [_, owner] <-
           Regex.run(
             ~r/reference\s+#{Regex.escape(reference)}:\s+its owner is\s+([\p{L}'-]+(?:\s+[\p{L}'-]+)*)\./iu,
             memory
           ) do
      "#{owner} owns #{reference}."
    else
      _not_found -> "I do not have that information."
    end
  end

  defp remembered_question(memory, topic) do
    question =
      memory
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&Regex.replace(~r/^[a-z_]+:\s+/u, &1, ""))
      |> Enum.find(fn line ->
        String.ends_with?(line, "?") and String.contains?(String.downcase(line), topic)
      end)

    if question do
      "You asked: #{question}"
    else
      "I do not have that information."
    end
  end

  defp memory_text(%Packet{} = packet) do
    Enum.map_join(packet.moments, "\n", & &1.text)
  end

  defp memory_text(_memory), do: ""
end

defmodule SpectreMnemonic.SpectreAgentMemoryE2ETest.Agent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreMnemonic.SpectreAgentMemoryE2ETest.Stack
  turn_handler(SpectreMnemonic.SpectreAgentMemoryE2ETest.Handler)
end

defmodule SpectreMnemonic.SpectreAgentMemoryE2ETest do
  use SpectreMnemonic.MemoryCase

  alias Spectre.Subject
  alias Spectre.Turn
  alias SpectreMnemonic.Recall.Packet
  alias SpectreMnemonic.SpectreAgentMemoryE2ETest.Agent

  @email "alice.rossi@example.com"
  @reference "DEP-4821"
  @owner "Marta Bianchi"
  @embedding_model "Xenova/bge-small-en-v1.5"

  test "a real Spectre 0.3.3 agent remembers facts, references and prior questions" do
    assert Spectre.version() == "0.3.3"

    subject = Subject.new("alice-account")
    base_opts = [subject: subject, test_pid: self(), memory_persist_failure: :error]

    {acknowledgement, initial_recall} =
      turn(
        "Remember that my primary email address is #{@email}.",
        Keyword.put(base_opts, :conversation_id, "profile-session")
      )

    assert acknowledgement == "I will remember it."
    assert initial_recall.moments == []

    {acknowledgement, _recall} =
      turn(
        "Remember deployment reference #{@reference}: its owner is #{@owner}.",
        Keyword.put(base_opts, :conversation_id, "operations-session")
      )

    assert acknowledgement == "I will remember it."

    {email_answer, email_recall} =
      turn(
        "Which email address did I give you?",
        Keyword.put(base_opts, :conversation_id, "follow-up-session")
      )

    assert email_answer == "Your primary email is #{@email}."
    assert recalled?(email_recall, @email)

    {owner_answer, owner_recall} =
      turn(
        "Who owns deployment reference #{@reference}?",
        Keyword.put(base_opts, :conversation_id, "follow-up-session")
      )

    assert owner_answer == "#{@owner} owns #{@reference}."
    assert recalled?(owner_recall, @reference)
    assert recalled?(owner_recall, @owner)

    {reference_answer, reference_recall} =
      turn(
        "What deployment reference did I give you?",
        Keyword.put(base_opts, :conversation_id, "follow-up-session")
      )

    assert reference_answer == "The deployment reference is #{@reference}."
    assert recalled?(reference_recall, @reference)

    {question_answer, question_recall} =
      turn(
        "What question did I ask about my email address?",
        Keyword.put(base_opts, :conversation_id, "history-session")
      )

    assert question_answer == "You asked: Which email address did I give you?"
    assert recalled?(question_recall, "Which email address did I give you?")
  end

  test "the agent cannot recall another subject's private information" do
    alice = Subject.new("alice-account")
    bob = Subject.new("bob-account")

    assert {"I will remember it.", _recall} =
             turn("Remember that my primary email address is #{@email}.",
               subject: alice,
               conversation_id: "alice-session",
               test_pid: self(),
               memory_persist_failure: :error
             )

    {answer, recall} =
      turn("Which email address did I give you?",
        subject: bob,
        conversation_id: "bob-session",
        test_pid: self(),
        memory_persist_failure: :error
      )

    assert answer == "I do not have that information."
    refute recalled?(recall, @email)
  end

  @tag :real_embedding
  test "the agent retrieves an email through a real local semantic embedding" do
    alias Spectre.Classifier.Embeddings.ExFastembed, as: FastembedAdapter

    assert {:ok, dimensions} = FastembedAdapter.load(@embedding_model)
    assert dimensions > 0
    Application.put_env(:spectre_mnemonic, :embedding_adapter, FastembedAdapter)

    subject = Subject.new("semantic-account")

    assert {"I will remember it.", _recall} =
             turn("Remember that password reset notifications must be sent to #{@email}.",
               subject: subject,
               conversation_id: "profile-session",
               test_pid: self(),
               memory_persist_failure: :error
             )

    {answer, recall} =
      turn("Where should account recovery messages be delivered?",
        subject: subject,
        conversation_id: "recovery-session",
        test_pid: self(),
        memory_persist_failure: :error
      )

    assert answer == "Your primary email is #{@email}."
    assert recalled?(recall, @email)
    assert is_binary(recall.query_context.vector)

    remembered = Enum.find(recall.moments, &String.contains?(&1.text, @email))
    assert is_binary(remembered.vector)

    query_keywords = MapSet.new(recall.query_context.keywords)
    memory_keywords = MapSet.new(remembered.keywords)
    assert MapSet.disjoint?(query_keywords, memory_keywords)
  end

  defp turn(input, opts) do
    assert {:ok, %Turn{observable: {:reply, reply, _ref}}} = Spectre.turn(Agent, input, opts)
    assert_receive {:agent_recalled, ^input, %Packet{} = recalled}, 2_000
    {reply, recalled}
  end

  defp recalled?(%Packet{} = packet, expected) do
    Enum.any?(packet.moments, &String.contains?(&1.text, expected))
  end
end
