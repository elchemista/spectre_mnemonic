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

defmodule SpectreMnemonic.StackInstallableTest.InstanceStack do
  @moduledoc false

  use Spectre.Stack, id: :mnemonic_instance_contract_stack

  install Spectre.Mnemonic, namespace: :support do
    isolate_by([:instance])
  end
end

defmodule SpectreMnemonic.StackInstallableTest.InstanceAgent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreMnemonic.StackInstallableTest.InstanceStack
end

if Code.ensure_loaded?(Spectre.Stack.PackageData) do
  defmodule SpectreMnemonic.StackInstallableTest.CheckpointStore do
    @moduledoc false

    @behaviour Spectre.Instance.CheckpointStore

    alias Spectre.Instance.Erasure.Status

    @impl true
    def erase(ref, request, opts) do
      server = Keyword.fetch!(opts, :server)

      Agent.get_and_update(server, fn entries ->
        case Map.get(entries, ref.key) do
          {:erased, _status} ->
            {{:ok, :already_erased}, entries}

          nil ->
            {:ok, status} = Status.from_request(request, request.requested_at)
            {{:ok, :erased}, Map.put(entries, ref.key, {:erased, status})}
        end
      end)
    end

    @impl true
    def erasure_status(ref, opts) do
      case Agent.get(Keyword.fetch!(opts, :server), &Map.get(&1, ref.key)) do
        {:erased, status} -> {:ok, status}
        nil -> :not_erased
      end
    end
  end
end

defmodule SpectreMnemonic.StackInstallableTest do
  use ExUnit.Case, async: true

  alias Spectre.AgentRef
  alias Spectre.Input
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Mnemonic.Extension
  alias Spectre.Mnemonic.Memory
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installable
  alias Spectre.State
  alias Spectre.Subject
  alias SpectreMnemonic.StackInstallableTest.Agent
  alias SpectreMnemonic.StackInstallableTest.InstanceAgent
  alias SpectreMnemonic.StackInstallableTest.Stack, as: TestStack
  alias SpectreMnemonic.StackInstallableTest.Store

  test "publishes the versioned Mnemonic Stack contract" do
    assert {:ok, package} = V1.verify_installable(Spectre.Mnemonic)
    assert package.id == :mnemonic
    assert package.version == "0.2.0"
    assert package.contract == 1
    assert package.spectre == "~> 0.3.3"
    assert package.provides == [{:service, :memory}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == [:engine]
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

  test "every configured isolation dimension must resolve to a concrete value" do
    assert {:error, {:mnemonic_isolation_dimension_required, :flow}} =
             Memory.options(Agent,
               agent: Agent,
               subject: Subject.new("account-42"),
               conversation: "conversation-42",
               task: "task-42"
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
               conversation: "linked-logical-thread",
               flow: :linked,
               task: "linked-task"
             )

    assert {:ok, whatsapp_opts} =
             Memory.options(Agent,
               input: whatsapp,
               state: %State{conversation_id: "conversation"},
               agent: Agent,
               subject: subject,
               conversation: "linked-logical-thread",
               flow: :linked,
               task: "linked-task"
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
               conversation: "linked-logical-thread",
               flow: :linked,
               task: "linked-task"
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
               flow: :agent_ref,
               task: "agent-ref-task",
               run_metadata: %{agent_ref: first_ref}
             )

    assert {:ok, second_conversation_opts} =
             Memory.options(Agent,
               input: second_input,
               state: %State{conversation_id: "stale-instance-base"},
               agent: Agent,
               subject: subject,
               flow: :agent_ref,
               task: "agent-ref-task",
               run_metadata: %{agent_ref: first_ref}
             )

    assert {:ok, second_agent_opts} =
             Memory.options(Agent,
               input: first_input,
               state: %State{conversation_id: "stale-instance-base"},
               agent: Agent,
               subject: subject,
               flow: :agent_ref,
               task: "agent-ref-task",
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

  test "instance isolation is stable across Definition and Stack source hint changes" do
    subject = Subject.new("account-42")

    old_agent_ref =
      AgentRef.from_id("stable-agent",
        definition: InstanceAgent,
        version: 1,
        stack_digest: String.duplicate("a", 64)
      )

    new_agent_ref =
      AgentRef.from_id("stable-agent",
        definition: InstanceAgent,
        version: 2,
        stack_digest: String.duplicate("b", 64)
      )

    old_instance = InstanceRef.new(old_agent_ref, subject)
    new_instance = InstanceRef.new(new_agent_ref, subject)

    assert old_instance.key == new_instance.key

    assert {:ok, old_opts} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: old_instance}
             )

    assert {:ok, new_opts} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: new_instance}
             )

    assert old_opts[:scope] == new_opts[:scope]

    assert old_opts[:scope] ==
             {:spectre, [instance: {old_instance.schema_version, old_instance.key}]}
  end

  test "instance isolation separates Subjects and fails closed without an Instance Ref" do
    first = InstanceRef.new(InstanceAgent, Subject.new("account-42"))
    second = InstanceRef.new(InstanceAgent, Subject.new("account-99"))

    assert {:ok, first_opts} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: first}
             )

    assert {:ok, second_opts} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: second}
             )

    refute first_opts[:scope] == second_opts[:scope]

    assert {:error, {:mnemonic_isolation_dimension_required, :instance}} =
             Memory.options(InstanceAgent, agent: InstanceAgent)

    assert {:error, {:mnemonic_isolation_dimension_required, :instance}} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{agent_ref: AgentRef.new(InstanceAgent)}
             )
  end

  test "compiles store and isolation declarations into immutable installation data" do
    definition = Spectre.Stack.definition(TestStack)

    assert {:ok, installation} = Definition.installation(definition, :mnemonic)

    assert installation.config == %{
             options: [namespace: :support],
             store: Store,
             isolate_by: [:agent, :subject, :conversation, :flow, :task],
             stack_owner: SpectreMnemonic.StackInstallableTest.Stack
           }

    assert installation.resources == [:engine]
    assert installation.operations == []
    assert installation.actions == []

    assert {:ok, [{:engine, child_spec}]} =
             Installable.child_specs(installation, data_root: "stack-memory")

    assert %{start: {SpectreMnemonic.Engine, :start_link, [engine_opts]}} = child_spec

    assert engine_opts[:namespace] == "support"
    assert engine_opts[:data_root] == "stack-memory"
    assert is_binary(engine_opts[:storage_id])
    refute String.contains?(engine_opts[:storage_id], definition.digest)
    assert is_binary(installation.digest)
  end

  test "resolves the declared memory service and Engine resource" do
    assert {:ok, memory_ref} = Spectre.Stack.resolve(TestStack, :service, :memory)
    assert memory_ref.package == :mnemonic

    assert {:ok, engine_ref} = Spectre.Stack.resolve(TestStack, :resource, :engine)
    assert engine_ref.package == :mnemonic
    assert engine_ref.installation == :mnemonic

    assert {:error, {:unknown_stack_capability, :resource, :memory}} =
             Spectre.Stack.resolve(TestStack, :resource, :memory)
  end

  test "Stack Runtime supervises the Engine and the adapter resolves it by name" do
    root =
      Path.join(
        System.tmp_dir!(),
        "mnemonic-stack-runtime-#{System.unique_integer([:positive])}"
      )

    runtime_name = __MODULE__.Runtime

    runtime =
      start_supervised!(%{
        id: {Spectre.Stack.Runtime, runtime_name},
        start:
          {Spectre.Stack.Runtime, :start_link,
           [TestStack, [name: runtime_name, packages: [mnemonic: [data_root: root]]]]},
        type: :supervisor
      })

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, resource_ref} = Spectre.Stack.resolve(TestStack, :resource, :engine)
    assert {:ok, engine} = Spectre.Stack.Runtime.resolve(runtime, resource_ref)
    assert {:ok, _engine_runtime} = SpectreMnemonic.Engine.resolve(engine)

    input =
      Input.new(%{
        text: "runtime memory",
        source: %{kind: :beam, conversation_id: "runtime-conversation"},
        meta: %{task_id: "runtime-task"}
      })

    assert {:ok, opts} =
             Memory.options(Agent,
               agent: Agent,
               stack_runtime: runtime_name,
               input: input,
               subject: Subject.new("runtime-subject"),
               flow: :runtime,
               task: "runtime-task"
             )

    assert opts[:engine] == engine
    refute Keyword.has_key?(opts, :persistent_memory)

    assert {:error, {:invalid_mnemonic_stack_runtime, ^runtime}} =
             Memory.options(Agent,
               agent: Agent,
               stack_runtime: runtime,
               input: input,
               subject: Subject.new("runtime-subject"),
               flow: :runtime,
               task: "runtime-task"
             )
  end

  test "package erasure adapter plans and erases an Instance Engine partition" do
    root =
      Path.join(
        System.tmp_dir!(),
        "mnemonic-instance-erasure-#{System.unique_integer([:positive])}"
      )

    runtime_name = __MODULE__.InstanceRuntime

    _runtime =
      start_supervised!(%{
        id: {Spectre.Stack.Runtime, runtime_name},
        start:
          {Spectre.Stack.Runtime, :start_link,
           [
             SpectreMnemonic.StackInstallableTest.InstanceStack,
             [name: runtime_name, packages: [mnemonic: [data_root: root]]]
           ]},
        type: :supervisor
      })

    on_exit(fn -> File.rm_rf(root) end)

    instance = InstanceRef.new(InstanceAgent, Subject.new("erasure-subject"))

    assert {:ok, memory_opts} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               stack_runtime: runtime_name,
               run_metadata: %{instance_ref: instance}
             )

    assert {:ok, _memory} =
             SpectreMnemonic.remember(
               "instance data to erase",
               Keyword.put(memory_opts, :persist?, true)
             )

    assert {:ok, plan} =
             Spectre.Mnemonic.erasure_plan(instance, stack_runtime: runtime_name)

    assert plan.supported?
    assert plan.scope == {:spectre, [instance: {instance.schema_version, instance.key}]}

    assert {:ok, report} =
             Spectre.Mnemonic.erase_instance(instance, stack_runtime: runtime_name)

    assert report.marker_id

    assert {:error, :partition_erased} =
             SpectreMnemonic.remember(
               "must stay erased",
               Keyword.put(memory_opts, :persist?, true)
             )
  end

  if Code.ensure_loaded?(Spectre.Stack.PackageData) do
    test "Spectre erasure coordinator includes and verifies Mnemonic package data" do
      root =
        Path.join(
          System.tmp_dir!(),
          "mnemonic-spectre-erasure-#{System.unique_integer([:positive])}"
        )

      runtime_name = __MODULE__.CoordinatedErasureRuntime

      _runtime =
        start_supervised!(
          {Spectre.Stack.Runtime,
           stack: SpectreMnemonic.StackInstallableTest.InstanceStack,
           name: runtime_name,
           packages: [mnemonic: [data_root: root]]}
        )

      checkpoint_server =
        start_supervised!(
          Supervisor.child_spec({Elixir.Agent, fn -> %{} end}, id: :mnemonic_checkpoint_store)
        )

      on_exit(fn -> File.rm_rf(root) end)

      instance = InstanceRef.new(InstanceAgent, Subject.new("coordinated-erasure-subject"))

      assert {:ok, memory_opts} =
               Memory.options(InstanceAgent,
                 agent: InstanceAgent,
                 stack_runtime: runtime_name,
                 run_metadata: %{instance_ref: instance}
               )

      assert {:ok, _memory} =
               SpectreMnemonic.remember(
                 "package data erased by the Spectre coordinator",
                 Keyword.put(memory_opts, :persist?, true)
               )

      checkpoint =
        {SpectreMnemonic.StackInstallableTest.CheckpointStore, server: checkpoint_server}

      assert {:ok, plan} =
               Spectre.Privacy.erasure_plan(instance, instance.subject,
                 checkpoint_store: checkpoint,
                 stack_runtime: runtime_name
               )

      assert plan.ready
      assert plan.components.package_data.status == :ready
      assert plan.components.package_data.package_count == 1

      assert {:ok, proof} =
               Spectre.erase_instance(instance, instance.subject,
                 checkpoint_store: checkpoint,
                 stack_runtime: runtime_name,
                 confirm: instance.key
               )

      assert proof.outcome == :erased
      assert proof.components.package_data.outcome == :erased
      assert proof.components.package_data.package_count == 1

      assert {:error, :partition_erased} =
               SpectreMnemonic.remember(
                 "erasure remains sealed",
                 Keyword.put(memory_opts, :persist?, true)
               )
    end
  end

  test "logical Run identity yields stable operation ids and missing Run ids use UUIDv7" do
    instance = InstanceRef.new(InstanceAgent, Subject.new("operation-subject"))

    assert {:ok, first} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: instance, run_id: "run-42", step_id: "step-7"}
             )

    assert {:ok, retry} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: instance, run_id: "run-42", step_id: "step-7"}
             )

    assert first[:operation_id] == retry[:operation_id]
    assert String.starts_with?(first[:operation_id], "spectre-op-")

    assert {:ok, generated_a} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: instance}
             )

    assert {:ok, generated_b} =
             Memory.options(InstanceAgent,
               agent: InstanceAgent,
               run_metadata: %{instance_ref: instance}
             )

    refute generated_a[:operation_id] == generated_b[:operation_id]
    assert generated_a[:operation_id] =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7/
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
