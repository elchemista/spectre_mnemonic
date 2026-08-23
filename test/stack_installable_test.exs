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

  alias Spectre.AgentRef
  alias Spectre.Input
  alias Spectre.Mnemonic.Extension
  alias Spectre.Mnemonic.Memory
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installable
  alias Spectre.State
  alias Spectre.Subject
  alias SpectreMnemonic.StackInstallableTest.Agent
  alias SpectreMnemonic.StackInstallableTest.Stack, as: TestStack
  alias SpectreMnemonic.StackInstallableTest.Store

  test "publishes the versioned Mnemonic Stack contract" do
    assert {:ok, package} = V1.verify_installable(Spectre.Mnemonic)
    assert package.id == :mnemonic
    assert package.version == "0.1.0"
    assert package.contract == 1
    assert package.spectre == "~> 0.3.3"
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

    subject = Subject.new("subject-1")

    input =
      Input.new(%{
        text: "private cue",
        meta: %{task_id: "task-1"},
        source: %{
          kind: :beam,
          actor_id: "external-channel-user",
          conversation_id: "conversation-1"
        }
      })

    assert {:ok, opts} =
             Memory.options(Agent,
               input: input,
               state: %State{conversation_id: "conversation-1"},
               agent: Agent,
               subject: subject,
               flow: :support
             )

    assert opts[:namespace] == "support"
    assert opts[:subject] == subject
    assert opts[:subject_id] == subject.id

    assert opts[:scope] ==
             {:spectre,
              [
                agent: Agent,
                subject: Subject.key(subject),
                conversation: "conversation-1",
                flow: :support,
                task: "task-1"
              ]}

    assert get_in(opts, [:persistent_memory, :stores]) == [
             [id: :spectre_stack, adapter: Store, role: :primary]
           ]
  end

  test "subject isolation fails closed instead of inferring Input.Source.actor_id" do
    input =
      Input.new(%{
        text: "private cue",
        source: %{
          kind: :beam,
          actor_id: "external-channel-user",
          conversation_id: "shared-conversation"
        }
      })

    assert {:error, :mnemonic_canonical_subject_required} =
             Memory.options(Agent,
               input: input,
               state: %State{conversation_id: "shared-conversation"},
               agent: Agent
             )
  end

  test "nil Subject fails closed without escaping the adapter contract" do
    assert {:error, :mnemonic_canonical_subject_required} =
             Memory.options(Agent,
               agent: Agent,
               subject: nil
             )
  end

  test "linked channels share only the explicitly supplied canonical Subject scope" do
    subject = Subject.new("account-42")

    telegram =
      Input.new(%{
        text: "telegram",
        source: %{kind: :beam, actor_id: "telegram-user", conversation_id: "telegram-chat"}
      })

    whatsapp =
      Input.new(%{
        text: "whatsapp",
        source: %{kind: :beam, actor_id: "whatsapp-user", conversation_id: "whatsapp-chat"}
      })

    assert {:ok, telegram_opts} =
             Memory.options(Agent,
               input: telegram,
               state: %State{conversation_id: "conversation"},
               agent: Agent,
               subject: subject,
               conversation: "linked-logical-thread"
             )

    assert {:ok, whatsapp_opts} =
             Memory.options(Agent,
               input: whatsapp,
               state: %State{conversation_id: "conversation"},
               agent: Agent,
               subject: subject,
               conversation: "linked-logical-thread"
             )

    assert telegram_opts[:subject] == subject
    assert whatsapp_opts[:subject] == subject
    assert telegram_opts[:scope] == whatsapp_opts[:scope]

    assert {:ok, other_subject_opts} =
             Memory.options(Agent,
               input: telegram,
               state: %State{conversation_id: "conversation"},
               agent: Agent,
               subject: Subject.new("account-99"),
               conversation: "linked-logical-thread"
             )

    refute other_subject_opts[:scope] == telegram_opts[:scope]
  end

  test "AgentRef and the current input conversation isolate Instance memory" do
    subject = Subject.new("account-42")
    first_ref = AgentRef.new(Agent, id: "logical-agent-one")
    second_ref = AgentRef.new(Agent, id: "logical-agent-two")

    first_input =
      Input.new(%{
        text: "first",
        source: %{kind: :beam, actor_id: "user", conversation_id: "current-first"}
      })

    second_input =
      Input.new(%{
        text: "second",
        source: %{kind: :beam, actor_id: "user", conversation_id: "current-second"}
      })

    assert {:ok, first_opts} =
             Memory.options(Agent,
               input: first_input,
               state: %State{conversation_id: "stale-instance-base"},
               agent: Agent,
               subject: subject,
               run_metadata: %{agent_ref: first_ref}
             )

    assert {:ok, second_conversation_opts} =
             Memory.options(Agent,
               input: second_input,
               state: %State{conversation_id: "stale-instance-base"},
               agent: Agent,
               subject: subject,
               run_metadata: %{agent_ref: first_ref}
             )

    assert {:ok, second_agent_opts} =
             Memory.options(Agent,
               input: first_input,
               state: %State{conversation_id: "stale-instance-base"},
               agent: Agent,
               subject: subject,
               run_metadata: %{agent_ref: second_ref}
             )

    {:spectre, first_partition} = first_opts[:scope]

    assert first_opts[:agent_ref] == first_ref
    assert Keyword.fetch!(first_partition, :agent) == AgentRef.key(first_ref)
    assert Keyword.fetch!(first_partition, :conversation) == "current-first"
    refute first_opts[:scope] == second_conversation_opts[:scope]
    refute first_opts[:scope] == second_agent_opts[:scope]
  end

  test "authoritative Instance AgentRef rejects caller partition overrides" do
    authoritative = AgentRef.new(Agent, id: "authoritative-agent")
    supplied = AgentRef.new(Agent, id: "caller-override")

    assert {:error, :mnemonic_agent_ref_mismatch} =
             Memory.options(Agent,
               agent: Agent,
               subject: Subject.new("account"),
               agent_ref: supplied,
               run_metadata: %{agent_ref: authoritative}
             )

    foreign = AgentRef.from_id("foreign", definition: String, version: 1)

    assert {:error, {:mnemonic_agent_ref_definition_mismatch, String, Agent}} =
             Memory.options(Agent,
               agent: Agent,
               subject: Subject.new("account"),
               run_metadata: %{agent_ref: foreign}
             )
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
