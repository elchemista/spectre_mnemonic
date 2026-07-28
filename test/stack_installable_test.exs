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

defmodule SpectreMnemonic.StackInstallableTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installable
  alias SpectreMnemonic.StackInstallableTest.Stack, as: TestStack
  alias SpectreMnemonic.StackInstallableTest.Store

  test "publishes the versioned Mnemonic Stack contract" do
    assert {:ok, package} = V1.verify_installable(Spectre.Mnemonic)
    assert package.id == :mnemonic
    assert package.version == "0.1.2"
    assert package.contract == 1
    assert package.spectre == "~> 0.1.2"
    assert package.provides == [{:service, :memory}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []
    assert package.dsl == Spectre.Mnemonic
    assert is_binary(package.digest)
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
end
