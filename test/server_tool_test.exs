defmodule SpectreMnemonic.UnreviewedServerToolRecord do
  defstruct [:private_token]
end

defmodule Spectre.Mnemonic.ServerToolTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias Spectre.GAM.Canonical.Value
  alias Spectre.Mnemonic.Memory, as: MnemonicMemory
  alias Spectre.Mnemonic.ServerTool
  alias Spectre.Mnemonic.ServerToolTest.{Agent, Stack}
  alias Spectre.Stack.Tools
  alias SpectreMnemonic.Engine.Context, as: EngineContext
  alias SpectreMnemonic.Memory.{Moment, Secret}
  alias SpectreMnemonic.Persistence.Manager

  test "generated requests retain documented options without accepting host identity overrides" do
    for {operation, args, options} <- [
          {:learn, ["approved observation"], [name: "preference", metadata: %{source: "chat"}]},
          {:remember, ["approved observation"],
           [kind: :fact, tags: [:reviewed], extract_entities?: false]},
          {:recall, ["preference"], [include_knowledge: true, include_observations: false]},
          {:forget, [{:stream, :chat}], []},
          {:forget, [{:task, "task-1"}], []},
          {:compact_knowledge, [], []},
          {:sweep_expired, [], []}
        ] do
      assert {:ok, request} = ServerTool.prepare(operation, args ++ [options], %{})
      assert :ok = Value.validate(request)

      assert {:error, :invalid_mnemonic_options} =
               ServerTool.prepare(operation, args ++ [[engine: :another_owner]], %{})
    end

    assert {:error, :invalid_mnemonic_request} = ServerTool.prepare(:learn, [], %{})

    for options <- [[tags: [self()]], [metadata: %Moment{}], [metadata: %{pid: self()}]] do
      assert {:error, _reason} = ServerTool.prepare(:remember, ["observation", options], %{})
    end
  end

  test "effect adapter distinguishes invalid requests from an admitted successful write" do
    root = Path.join(System.tmp_dir!(), "mnemonic-effects-#{System.unique_integer([:positive])}")
    runtime_name = __MODULE__.EffectRuntime

    start_supervised!(
      {Spectre.Stack.Runtime,
       stack: Stack,
       name: runtime_name,
       packages: [mnemonic: [data_root: root, namespace: "effect_adapter_test"]]}
    )

    on_exit(fn -> File.rm_rf(root) end)

    context = %{
      agent: Agent,
      identity: %{subject: Spectre.Subject.new("owner")},
      options: [stack_runtime: runtime_name]
    }

    assert {:error, :definitive_no_effect, :invalid_mnemonic_write} =
             ServerTool.execute_effect(:recall, %{cue: "read is not an effect"}, context)

    assert {:error, :definitive_no_effect, :invalid_mnemonic_write} =
             ServerTool.execute_effect(:unknown, %{}, context)

    assert {:error, :definitive_no_effect, :mnemonic_stack_runtime_required} =
             ServerTool.execute_effect(:remember, %{observation: "must not write"}, %{
               context
               | options: []
             })

    assert {:ok, %{root: %{text: "admitted observation"}}} =
             ServerTool.execute_effect(:remember, %{observation: "admitted observation"}, context)

    assert {:error, :invalid_mnemonic_result} = ServerTool.project(:recall, :unexpected)
  end

  test "remember requires an explicit governed host binding" do
    assert %{recall: %{path: :cognitive}} = Spectre.Mnemonic.tools(%{}).mnemonic.operations
    refute Map.has_key?(Spectre.Mnemonic.tools(%{}).mnemonic.operations, :remember)
    config = Spectre.Stack.definition(Stack).installations |> hd() |> Map.fetch!(:config)
    assert config.isolate_by == [:subject]
    tools = Spectre.Mnemonic.tools(config)
    assert %{path: :governed, operation: :save_report} = tools.mnemonic.operations.remember
    assert Tools.validate!(tools) == tools
    refute Keyword.has_key?(Agent.__spectre_config__(), :memory)

    assert_raise ArgumentError, fn ->
      Spectre.Mnemonic.tools(%{options: [bind: [recall: :bad]]})
    end
  end

  test "native packets are portable and query options and encrypted data never escape" do
    packet = %SpectreMnemonic.Recall.Packet{
      query_context: %SpectreMnemonic.QueryContext{
        text: "site",
        opts: [api_key: "SECRET", runtime: self()]
      },
      moments: [
        %Moment{id: "m1", text: "Shopify site", inserted_at: ~U[2026-01-01 00:00:00Z]},
        %Secret{
          id: "s1",
          secret_id: "secret",
          label: "key",
          text: "PLAINTEXT",
          ciphertext: "CIPHER",
          revealed?: true
        }
      ]
    }

    assert {:ok, {:ok, data}} = ServerTool.project(:recall, {:ok, packet})
    assert data.moments |> hd() |> Map.fetch!(:text) == "Shopify site"
    assert data.moments |> hd() |> Map.fetch!(:inserted_at) == "2026-01-01T00:00:00Z"
    assert Enum.at(data.moments, 1).locked?
    refute Map.has_key?(data.query_context, :opts)
    refute inspect(data) =~ "SECRET"
    refute inspect(data) =~ "PLAINTEXT"
    refute inspect(data) =~ "CIPHER"
    assert {:ok, _} = Value.encode(data)

    assert {:error, :nonportable_mnemonic_result} =
             ServerTool.project(:recall, {:ok, %{runtime: self()}})
  end

  test "explicit tools reject a missing Stack runtime instead of using DefaultEngine" do
    context = %{agent: Agent, identity: %{subject: Spectre.Subject.new("alice")}, options: []}

    assert {:error, :mnemonic_stack_runtime_required} =
             ServerTool.invoke(:recall, %{cue: "Shopify"}, %{service_context: context})

    assert {:error, :mnemonic_stack_runtime_required} =
             ServerTool.execute(
               :remember,
               %{observation: "must not enter DefaultEngine"},
               context
             )
  end

  test "new fields and unreviewed Mnemonic record types cannot escape the projection" do
    moment =
      %Moment{id: "m1", text: "public", metadata: %{api_key: "META-SECRET"}}
      |> Map.put(:future_private_field, "FUTURE-SECRET")

    assert {:ok, {:ok, projected}} = ServerTool.project(:recall, {:ok, moment})
    assert projected.text == "public"
    refute Map.has_key?(projected, :future_private_field)
    refute Map.has_key?(projected, :metadata)
    refute inspect(projected) =~ "SECRET"

    assert {:error, :nonportable_mnemonic_result} =
             ServerTool.project(
               :recall,
               {:ok, %SpectreMnemonic.UnreviewedServerToolRecord{private_token: "NEW-SECRET"}}
             )
  end

  test "the executor adapter writes real memory and recall returns a portable packet" do
    root = Path.join(System.tmp_dir!(), "mnemonic-tools-#{System.unique_integer([:positive])}")
    runtime_name = __MODULE__.Runtime

    start_supervised!(
      {Spectre.Stack.Runtime,
       stack: Stack,
       name: runtime_name,
       packages: [mnemonic: [data_root: root, namespace: "server_tool_test"]]}
    )

    on_exit(fn -> File.rm_rf(root) end)

    context = %{
      agent: Agent,
      command_id: "admitted:save-report",
      identity: %{subject: Spectre.Subject.new("alice")},
      current_flow: :support,
      options: [stack_runtime: runtime_name],
      input: nil
    }

    assert {:ok, written} =
             ServerTool.execute(:remember, %{observation: "Luca uses Shopify"}, context)

    assert written.root.text == "Luca uses Shopify"

    # The executor gets its partition from trusted admitted candidate data,
    # never from the model-authored tool arguments.
    missing_partition = %{context | identity: %{}}

    assert {:error, :mnemonic_canonical_subject_required} =
             ServerTool.execute(:remember, %{observation: "must not save"}, missing_partition)

    bob = %{context | identity: %{subject: Spectre.Subject.new("bob")}}
    bob_raw = ServerTool.invoke(:recall, %{cue: "Shopify"}, %{service_context: bob})
    assert {:ok, {:ok, bob_memory}} = ServerTool.project(:recall, bob_raw)
    refute Enum.any?(bob_memory.moments, &(&1.text == "Luca uses Shopify"))

    assert {:ok, request} = ServerTool.prepare(:recall, ["Shopify"], %{})
    raw = ServerTool.invoke(:recall, request, %{service_context: context})
    assert {:ok, {:ok, recalled}} = ServerTool.project(:recall, raw)
    assert Enum.any?(recalled.moments, &(&1.text == "Luca uses Shopify"))
    assert {:ok, _} = Value.encode(recalled)

    assert {:ok, automatic} =
             MnemonicMemory.recall("Shopify",
               agent: Agent,
               stack_runtime: runtime_name,
               subject: Spectre.Subject.new("alice"),
               spectre_server: true
             )

    refute is_struct(automatic)
    assert {:ok, _} = Value.encode(automatic)

    assert {:ok, memory_opts} =
             MnemonicMemory.options(
               Agent,
               Keyword.put(context.options, :subject, context.identity.subject)
             )

    assert {:ok, records} =
             EngineContext.with(
               memory_opts,
               &Manager.replay/1
             )

    # Intake has per-record operation ids; the admitted command identifies the batch.
    batch =
      "batch_" <> Base.url_encode64(:crypto.hash(:sha256, "admitted:save-report"), padding: false)

    assert Enum.any?(records, &(&1.batch_id == batch))

    explicit = %{
      context
      | options: Keyword.put(context.options, :operation_id, "host:save-other")
    }

    assert {:ok, _} =
             ServerTool.execute(:remember, %{observation: "Giulia uses Phoenix"}, explicit)

    assert {:ok, records} =
             EngineContext.with(
               memory_opts,
               &Manager.replay/1
             )

    expected_batch =
      "batch_" <> Base.url_encode64(:crypto.hash(:sha256, "host:save-other"), padding: false)

    assert expected_batch in Enum.map(records, & &1.batch_id)
  end
end
