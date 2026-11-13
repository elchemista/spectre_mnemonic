defmodule Spectre.Mnemonic.ServerToolTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias Spectre.Mnemonic.ServerTool
  alias SpectreMnemonic.Memory.{Moment, Secret}

  defmodule Stack do
    use Spectre.Stack

    install(Spectre.Mnemonic,
      namespace: :server_tool_test,
      automatic: false,
      bind: [remember: :save_report]
    )
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack
  end

  test "remember requires an explicit governed host binding" do
    assert %{recall: %{path: :cognitive}} = Spectre.Mnemonic.tools(%{}).mnemonic.operations
    refute Map.has_key?(Spectre.Mnemonic.tools(%{}).mnemonic.operations, :remember)
    config = Spectre.Stack.definition(Stack).installations |> hd() |> Map.fetch!(:config)
    tools = Spectre.Mnemonic.tools(config)
    assert %{path: :governed, operation: :save_report} = tools.mnemonic.operations.remember
    assert Spectre.Stack.Tools.validate!(tools) == tools
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
    assert {:ok, _} = Spectre.GAM.Canonical.Value.encode(data)

    assert {:error, :nonportable_mnemonic_result} =
             ServerTool.project(:recall, {:ok, %{runtime: self()}})
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
      identity: %{},
      current_flow: :support,
      options: [stack_runtime: runtime_name],
      input: nil
    }

    assert {:ok, written} =
             ServerTool.execute(:remember, %{observation: "Luca uses Shopify"}, context)

    assert written.root.text == "Luca uses Shopify"
    assert {:ok, request} = ServerTool.prepare(:recall, ["Shopify"], %{})
    raw = ServerTool.invoke(:recall, request, %{service_context: context})
    assert {:ok, {:ok, recalled}} = ServerTool.project(:recall, raw)
    assert Enum.any?(recalled.moments, &(&1.text == "Luca uses Shopify"))
    assert {:ok, _} = Spectre.GAM.Canonical.Value.encode(recalled)

    assert {:ok, automatic} =
             Spectre.Mnemonic.Memory.recall("Shopify",
               agent: Agent,
               stack_runtime: runtime_name,
               spectre_server: true
             )

    refute is_struct(automatic)
    assert {:ok, _} = Spectre.GAM.Canonical.Value.encode(automatic)

    assert {:ok, memory_opts} = Spectre.Mnemonic.Memory.options(Agent, context.options)

    assert {:ok, records} =
             SpectreMnemonic.Engine.Context.with(
               memory_opts,
               &SpectreMnemonic.Persistence.Manager.replay/1
             )

    assert Enum.any?(records, &(&1.operation_id == "admitted:save-report"))

    explicit = %{
      context
      | options: Keyword.put(context.options, :operation_id, "host:save-other")
    }

    assert {:ok, _} =
             ServerTool.execute(:remember, %{observation: "Giulia uses Phoenix"}, explicit)

    assert {:ok, records} =
             SpectreMnemonic.Engine.Context.with(
               memory_opts,
               &SpectreMnemonic.Persistence.Manager.replay/1
             )

    expected_batch =
      "batch_" <> Base.url_encode64(:crypto.hash(:sha256, "host:save-other"), padding: false)

    assert expected_batch in Enum.map(records, & &1.batch_id)
  end
end
