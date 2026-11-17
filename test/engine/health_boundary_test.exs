defmodule SpectreMnemonic.Engine.HealthBoundaryTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Context
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Persistence.Store.Postgres

  defmodule HealthStore do
    def capabilities(_opts), do: []

    def health(opts) do
      case Keyword.fetch!(opts, :result) do
        {:raise, message} -> raise message
        {:throw, reason} -> throw(reason)
        result -> result
      end
    end
  end

  defmodule LegacyStore do
    def capabilities(_opts), do: []
  end

  test "health exposes unavailable adapters and sanitized reasons without disclosing stored content" do
    stores =
      for {id, adapter, result} <- [
            {:plain, HealthStore, {:error, :offline}},
            {:tuple, HealthStore, {:error, {:disconnected, "private hostname"}}},
            {:exception, HealthStore, {:error, RuntimeError.exception("private payload")}},
            {:private, HealthStore, {:error, "private connection string"}},
            {:invalid, HealthStore, :invalid},
            {:raising, HealthStore, {:raise, "private failure"}},
            {:throwing, HealthStore, {:throw, "private failure"}},
            {:legacy, LegacyStore, nil},
            {:unavailable, String, nil},
            {:placeholder, Postgres, nil}
          ] do
        %{id: id, adapter: adapter, role: :replica, opts: [result: result]}
      end

    engine =
      start_supervised!(
        {Engine,
         storage_id: "health-boundaries",
         namespace: "health-boundaries",
         persistent_memory: %{stores: stores}}
      )

    assert {:ok, health} = Engine.health(engine)
    assert :stores in health.degraded_sources
    assert health.stores.plain.status == {:error, :offline}
    assert health.stores.tuple.status == {:error, :disconnected}
    assert health.stores.exception.status == {:error, RuntimeError}
    assert health.stores.private.status == {:error, :redacted}
    assert health.stores.invalid.status == {:error, :invalid_health_result}
    assert health.stores.raising.status == {:error, :health_check_failed}
    assert health.stores.throwing.status == {:error, :health_check_failed}
    assert health.stores.legacy.status == :ok
    assert health.stores.legacy.contract == :legacy
    assert health.stores.unavailable.status == {:error, :adapter_unavailable}
    assert health.stores.placeholder.contract == :placeholder
    refute inspect(health) =~ "private hostname"
    refute inspect(health) =~ "private payload"
    refute inspect(health) =~ "private connection string"
  end

  test "engine-owned crypto configuration survives nested operations and caller overrides" do
    key = :crypto.strong_rand_bytes(32)

    engine =
      start_supervised!(
        {Engine,
         storage_id: :crypto_owned,
         namespace: :crypto_owned,
         secret_crypto: %{key: key, key_id: :tenant_key, key_version: 7}}
      )

    assert {:ok, runtime} = Engine.runtime(engine)
    assert {:ok, ^runtime} = Engine.resolve(runtime.config.ref)
    assert Ref.new(runtime.config.ref) == runtime.config.ref

    assert {:ok, %{moment: secret}} =
             SpectreMnemonic.signal("engine secret",
               engine: engine,
               secret?: true,
               label: "owned key",
               secret_key: <<0::256>>,
               persist?: false
             )

    assert secret.key_id == "tenant_key"
    assert secret.key_version == 7

    assert :restored =
             Context.with([engine: engine], fn _opts ->
               original = Context.current()
               assert original.config.ref == runtime.config.ref
               Context.with([], fn _nested -> assert Context.current() == original end)
               assert Context.current() == original
               :restored
             end)

    assert Context.current() == nil
  end

  test "invalid and retired engine references cannot silently target the default engine" do
    assert {:error, {:invalid_mnemonic_engine, 42}} = Engine.resolve(42)

    assert {:error, {:mnemonic_engine_not_found, __MODULE__.Missing}} =
             Engine.resolve(__MODULE__.Missing)

    assert {:error, :invalid_engine_ref} =
             Engine.start_link(storage_id: "invalid-ref", namespace: "test", ref: " ")

    assert {:error, :invalid_engine_name} =
             Engine.start_link(storage_id: "invalid-name", namespace: "test", name: "not-a-name")

    assert {:error, {:storage_id, :required}} = Engine.start_link(namespace: "test")
    assert {:error, {:namespace, :required}} = Engine.start_link(storage_id: "missing-namespace")
  end
end
