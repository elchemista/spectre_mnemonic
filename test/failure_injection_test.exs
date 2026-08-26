defmodule SpectreMnemonic.FailureInjectionTest do
  use ExUnit.Case, async: true

  alias SpectreMnemonic.FailureInjection
  alias SpectreMnemonic.FailureInjection.Injector

  test "replays checkpoint actions deterministically and records their context" do
    pid =
      start_supervised!(
        {Injector,
         script: [
           before_primary_commit: [:pass, {:error, :disk_full}],
           after_primary_commit: {:exit, :writer_crashed}
         ]}
      )

    injector = Injector.new(pid)
    opts = [failure_injector: injector]

    assert :ok = FailureInjection.checkpoint(:before_primary_commit, opts, %{attempt: 1})
    assert {:error, :disk_full} = FailureInjection.checkpoint(:before_primary_commit, opts)
    assert :ok = FailureInjection.checkpoint(:before_primary_commit, opts)
    assert catch_exit(FailureInjection.checkpoint(:after_primary_commit, opts)) == :writer_crashed

    assert [
             %{point: :before_primary_commit, context: %{attempt: 1}, action: :pass},
             %{point: :before_primary_commit, action: {:error, :disk_full}},
             %{point: :before_primary_commit, action: :ok},
             %{point: :after_primary_commit, action: {:exit, :writer_crashed}}
           ] = Injector.history(injector.server)
  end

  test "accepts stateless callbacks without starting a global process" do
    injector = fn
      :selected, %{operation_id: "op-1"} -> {:error, :selected_failure}
      _point, _context -> :ok
    end

    assert {:error, :selected_failure} =
             FailureInjection.checkpoint(:selected, [failure_injector: injector], %{
               operation_id: "op-1"
             })

    assert :ok = FailureInjection.checkpoint(:other, failure_injector: injector)
  end
end
