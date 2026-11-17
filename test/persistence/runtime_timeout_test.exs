defmodule SpectreMnemonic.Persistence.RuntimeTimeoutTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Context
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Runtime

  defmodule SlowLookup do
    def capabilities(_opts), do: [:lookup]

    def get(_family, "slow", opts) do
      send(Keyword.fetch!(opts, :test_pid), {:lookup_started, self()})
      receive do: (:release_lookup -> {:error, :not_found})
    end

    def get(_family, _id, _opts), do: {:error, :not_found}
  end

  test "lookup timeouts leave diagnostics responsive and the persistence runtime reusable" do
    engine =
      start_supervised!(
        {Engine,
         storage_id: "timeout-lookup",
         namespace: "timeout-lookup",
         persistent_memory: [
           stores: [[id: :primary, adapter: SlowLookup, role: :primary, opts: [test_pid: self()]]]
         ]}
      )

    {:ok, runtime} = Engine.resolve(engine)

    lookup = fn id, timeout ->
      Context.with([engine: engine], fn opts ->
        Manager.get(:moments, id, Keyword.put(opts, :read_timeout, timeout))
      end)
    end

    request = Task.async(fn -> lookup.("slow", 10) end)
    assert_receive {:lookup_started, owner}, 1_000
    assert %{running?: true, operation: :lookup} = Runtime.status(runtime.config.ref)
    assert {:error, {:persistent_memory_timeout, 10}} = Task.await(request)
    assert Process.alive?(owner)
    send(owner, :release_lookup)
    assert {:error, :not_found} = lookup.("next", 1_000)
    assert %{running?: true, operation: :idle} = Runtime.status(runtime.config.ref)
  end
end
