defmodule SpectreMnemonic.Engine.ActiveCommandTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.Command

  test "callback failures release the partition for subsequent commands" do
    opts = [namespace: "spectre_mnemonic_test", scope: :command_failures]
    record = %{namespace: "spectre_mnemonic_test", scope: :command_failures}

    assert {:error, {:active_focus_failed, ArgumentError, "invalid mutation"}} =
             Command.run(opts, fn -> raise ArgumentError, "invalid mutation" end)

    assert {:error, {:active_focus_failed, :throw, :cancelled}} =
             Command.run_for_record(record, fn -> throw(:cancelled) end)

    assert :available = Command.run_for_record(record, fn -> :available end)
  end
end
