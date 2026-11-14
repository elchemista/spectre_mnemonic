defmodule Spectre.Mnemonic.ServerToolOperationsTest do
  use SpectreMnemonic.MemoryCase, async: false
  alias Spectre.GAM.Canonical.Value
  alias Spectre.Mnemonic.Memory, as: MnemonicMemory
  alias Spectre.Mnemonic.ServerTool
  alias Spectre.Mnemonic.ServerTool.Operations
  alias Spectre.Mnemonic.ServerToolTest.{Agent, Stack}
  alias Spectre.Stack.Tools
  alias SpectreMnemonic.Engine.Context, as: EngineContext
  alias SpectreMnemonic.Persistence.Manager

  test "managed catalog exposes only bound writes and freezes identity requirements" do
    config = %{options: [bind: [remember: :save_notes]], isolate_by: [:agent, :subject]}
    assert %{save_notes: descriptor} = Spectre.Mnemonic.effects(config)
    assert descriptor.adapter == ServerTool
    assert descriptor.operation == :remember
    assert descriptor.partition == [:subject]
    assert %{} = Spectre.Mnemonic.effects(%{})
    assert Spectre.Stack.Effects.validate!(%{save_notes: descriptor})

    assert_raise ArgumentError, fn ->
      Spectre.Mnemonic.effects(%{options: [bind: [remember: :shared, forget: :shared]]})
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "mnemonic-operations-#{System.unique_integer([:positive])}")

    runtime = __MODULE__.Runtime

    start_supervised!(
      {Spectre.Stack.Runtime,
       stack: Stack,
       name: runtime,
       packages: [mnemonic: [data_root: root, namespace: "server_tool_test"]]}
    )

    on_exit(fn -> File.rm_rf(root) end)

    context = %{
      agent: Agent,
      command_id: "admitted:memory-test",
      identity: %{subject: "alice"},
      options: [stack_runtime: runtime]
    }

    %{context: context}
  end

  test "closed catalogue distinguishes reads, explicitly bound writes, and host administration" do
    config = %{options: [bind: Enum.map(Operations.writes(), &{&1, &1})]}
    descriptor = Spectre.Mnemonic.tools(config)
    assert Tools.validate!(descriptor) == descriptor

    for operation <- Operations.reads(),
        do: assert(descriptor.mnemonic.operations[operation].path == :cognitive)

    for operation <- Operations.writes(),
        do: assert(descriptor.mnemonic.operations[operation].path == :governed)

    for operation <- [:export, :erase_partition, :reveal, :artifact, :health, :load_knowledge] do
      assert {:error, :invalid_mnemonic_request} = ServerTool.prepare(operation, [], %{})
    end
  end

  test "request options cannot override partition, runtime, adapters or mutate a read", %{
    context: context
  } do
    for {key, value} <- [
          scope: :other,
          scopes: [:other],
          namespace: "other",
          subject: "bob",
          engine: :other,
          stack_runtime: :other,
          operation_id: "forged",
          persist?: true,
          reinforce?: true,
          plasticity?: true,
          recluster: true,
          reveal_secrets?: true,
          authorization_adapter: __MODULE__,
          embedding_adapter: __MODULE__
        ] do
      assert {:error, :invalid_mnemonic_options} =
               ServerTool.prepare(:search, ["note", [{key, value}]], %{})
    end

    for options <- [
          [limit: -1],
          [limit: 2000],
          [limit: 2, limit: 3],
          [budget: :infinite],
          [max_tokens: 0]
        ] do
      assert {:error, :invalid_mnemonic_options} =
               ServerTool.prepare(:search, ["note", options], %{})
    end

    assert {:error, :invalid_mnemonic_request} =
             ServerTool.prepare(:forget, [fn _ -> true end], %{})

    assert {:error, :mnemonic_write_requires_executor} =
             ServerTool.invoke(:forget, %{selector: "x"}, %{service_context: context})

    assert {:error, :invalid_mnemonic_options} =
             ServerTool.invoke(:search, %{cue: "x", options: [scope: :other]}, %{
               service_context: context
             })
  end

  test "search, reflection and atlas return portable evidence without changing persistence", %{
    context: context
  } do
    {:ok, saved} =
      ServerTool.execute(:remember, %{observation: "Luca uses Elixir on his shop"}, context)

    before = records(context)

    for operation <- [
          :recall,
          :search,
          :reflect,
          :search_observations,
          :search_mental_models,
          :search_knowledge
        ] do
      result = read(operation, ["Elixir", [limit: 3]], context)
      assert {:ok, data} = result
      assert :ok = Value.validate(data)
      refute inspect(data) =~ "__struct__"
    end

    assert {:ok, results} = read(:search, ["Elixir", [limit: 1]], context)
    assert length(results) == 1
    assert String.downcase(hd(results).record.text) =~ "elixir"
    assert {:ok, all} = read(:search, ["Luca uses Elixir on his shop"], context)
    assert Enum.any?(all, &(&1.id == saved.root.id))
    assert {:ok, atlas} = read(:atlas, [[max_nodes: 5]], context)
    assert Enum.any?(atlas.nodes, &(&1.id == saved.root.id))
    assert {:ok, _} = read(:knowledge, [], context)
    assert {:error, :not_found} = read(:status, ["unknown-task"], context)
    assert records(context) == before
    bob = %{context | identity: %{subject: "bob"}}
    assert {:ok, []} = read(:search, ["Elixir"], bob)
    assert {:ok, %{raw_memories: []}} = read(:reflect, ["Elixir"], bob)
    assert {:ok, %{nodes: []}} = read(:atlas, [], bob)

    assert {:error, :mnemonic_canonical_subject_required} =
             read(:search, ["Elixir"], %{context | identity: %{}})
  end

  test "governed learning, models, observations, links and maintenance use the same partition", %{
    context: context
  } do
    assert {:ok, a} = write(:remember, ["Alice prefers concise Elixir summaries"], context)

    assert {:ok, b} =
             write(:signal, ["Elixir deployment completed", [task_id: "deploy"]], context)

    assert {:ok, _} = write(:link, [a.root.id, :supports, b.moment.id], context)

    assert {:ok, _} =
             write(
               :put_mental_model,
               [
                 %{
                   title: "Elixir checklist",
                   query: "Elixir",
                   answer: "Review the supervision tree"
                 }
               ],
               context
             )

    assert {:ok, models} = read(:search_mental_models, ["Elixir"], context)
    assert Enum.any?(models, &(&1.answer =~ "supervision"))
    assert {:ok, _} = write(:learn, ["Elixir release\n- Run tests\n- Check supervision"], context)
    assert {:ok, knowledge} = read(:knowledge, [], context)
    assert inspect(knowledge) =~ "Run tests"
    assert {:ok, _} = write(:consolidate_observations, [], context)
    assert {:ok, _} = write(:consolidate, [[min_attention: 0.0]], context)
    assert {:ok, _} = write(:compact_knowledge, [], context)
    assert {:ok, _} = write(:sweep_expired, [], context)
    assert {:ok, n} = write(:forget, [a.root.id], context)
    assert n > 0
    assert {:ok, found} = read(:search, ["Alice prefers concise Elixir summaries"], context)
    refute Enum.any?(found, &(&1.id == a.root.id))
  end

  test "observation verification and entity merge/reversal preserve portable results", %{
    context: context
  } do
    assert {:ok, signal} = write(:signal, ["Marta status is active"], context)
    assert {:ok, [observation]} = write(:consolidate_observations, [], context)

    assert {:ok, verified} =
             write(
               :verify_observation,
               [
                 observation.id,
                 [source_id: signal.moment.id, relation: :supports, confidence_delta: 0.02]
               ],
               context
             )

    assert verified.proof_count == observation.proof_count + 1
    assert {:ok, packet} = write(:remember, ["Alice called Bob"], context)
    alice = Enum.find(packet.moments, &(&1.kind == :memory_entity and &1.text == "Entity: alice"))
    bob = Enum.find(packet.moments, &(&1.kind == :memory_entity and &1.text == "Entity: bob"))
    assert alice && bob
    assert {:ok, %{relation: :same_as}} = write(:merge_entities, [alice.id, bob.id], context)
    assert :ok = write(:unmerge_entities, [alice.id, bob.id], context)
  end

  defp read(operation, payload, context) do
    with {:ok, request} <- ServerTool.prepare(operation, payload, %{}),
         result <- ServerTool.invoke(operation, request, %{service_context: context}),
         {:ok, projected} <- ServerTool.project(operation, result),
         do: projected
  end

  defp write(operation, payload, context) do
    with {:ok, request} <- ServerTool.prepare(operation, payload, %{}),
         do:
           ServerTool.execute(operation, request, %{
             context
             | command_id: "admitted:#{System.unique_integer([:positive])}"
           })
  end

  defp records(context) do
    {:ok, opts} =
      MnemonicMemory.options(
        Agent,
        context.options ++ [subject: context.identity.subject]
      )

    {:ok, records} =
      EngineContext.with(opts, &Manager.replay/1)

    records
  end
end
