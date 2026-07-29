defmodule SpectreMnemonic.StackInstallableTest.Store do
  @moduledoc false
end

defmodule SpectreMnemonic.StackInstallableTest.Stack do
  @moduledoc false

  use Spectre.Stack, id: :mnemonic_contract_stack

  install Spectre.Mnemonic, namespace: :support do
    store(SpectreMnemonic.StackInstallableTest.Store)
    isolate_by([:agent, :subject, :conversation, :flow, :task])
  end
end

defmodule SpectreMnemonic.StackInstallableTest.Agent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreMnemonic.StackInstallableTest.Stack
end

defmodule SpectreMnemonic.StackInstallableTest do
  use ExUnit.Case, async: true

  alias Spectre.Input
  alias Spectre.Mnemonic.Extension
  alias Spectre.Mnemonic.Memory
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installable
  alias Spectre.State
  alias SpectreMnemonic.StackInstallableTest.Agent
  alias SpectreMnemonic.StackInstallableTest.Stack, as: TestStack
  alias SpectreMnemonic.StackInstallableTest.Store

  test "publishes the versioned Mnemonic Stack contract" do
    assert {:ok, package} = V1.verify_installable(Spectre.Mnemonic)
    assert package.id == :mnemonic
    assert package.version == "0.1.3"
    assert package.contract == 1
    assert package.spectre == "~> 0.1.3"
    assert package.provides == [{:service, :memory}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []
    assert package.agent_extensions == [Extension]
    assert package.dsl == Spectre.Mnemonic
    assert is_binary(package.digest)
  end

  test "selecting the Stack installs the Mnemonic memory adapter and isolation" do
    assert {:ok, config} = Spectre.Mnemonic.config(Agent)
    assert config.store == Store
    assert Agent.__spectre_definition__().config[:mnemonic] == config
    assert Agent.__spectre_definition__().config[:memory] == Memory

    input =
      Input.new(%{
        text: "private cue",
        meta: %{task_id: "task-1"},
        source: %{
          kind: :beam,
          actor_id: "subject-1",
          conversation_id: "conversation-1"
        }
      })

    assert {:ok, opts} =
             Memory.options(Agent,
               input: input,
               state: %State{conversation_id: "conversation-1"},
               agent: Agent,
               flow: :support
             )

    assert opts[:namespace] == "support"

    assert opts[:scope] ==
             {:spectre,
              [
                agent: Agent,
                subject: "subject-1",
                conversation: "conversation-1",
                flow: :support,
                task: "task-1"
              ]}

    assert get_in(opts, [:persistent_memory, :stores]) == [
             [id: :spectre_stack, adapter: Store, role: :primary]
           ]
  end

  test "compiles store and isolation declarations into immutable installation data" do
    definition = Spectre.Stack.definition(TestStack)

    assert {:ok, installation} = Definition.installation(definition, :mnemonic)

    assert installation.config == %{
             options: [namespace: :support],
             store: Store,
             isolate_by: [:agent, :subject, :conversation, :flow, :task]
           }

    assert installation.resources == []
    assert installation.operations == []
    assert installation.actions == []
    assert {:ok, []} = Installable.child_specs(installation, [])
    assert is_binary(installation.digest)
  end

  test "resolves the declared memory service without exposing runtime resources" do
    assert {:ok, memory_ref} = Spectre.Stack.resolve(TestStack, :service, :memory)
    assert memory_ref.package == :mnemonic

    assert {:error, {:unknown_stack_capability, :resource, :memory}} =
             Spectre.Stack.resolve(TestStack, :resource, :memory)
  end

  test "extension defaults and malformed Stack configuration have closed outcomes" do
    assert Extension.id() == :mnemonic
    assert Extension.api_version() == 1

    assert {:ok, defaults} = Extension.compile(__MODULE__, namespace: :default)
    assert defaults == %{options: [namespace: :default], store: nil, isolate_by: []}

    assert {:ok, %{store: Store} = compiled} =
             Extension.compile(__MODULE__, stack_config: %{store: Store})

    assert Extension.agent_config(compiled) == [
             mnemonic: compiled,
             memory: Memory
           ]

    assert {:error, {:invalid_mnemonic_stack_config, :invalid}} =
             Extension.compile(__MODULE__, stack_config: :invalid)
  end
end
