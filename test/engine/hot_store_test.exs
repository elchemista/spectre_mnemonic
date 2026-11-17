defmodule SpectreMnemonic.Engine.HotStoreTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Engine

  test "nested table contexts restore the previous engine even after a callback fails" do
    first = start_supervised!({Engine, namespace: "ets-first", storage_id: "ets-first"})
    second = start_supervised!({Engine, namespace: "ets-second", storage_id: "ets-second"})
    {:ok, first_runtime} = Engine.resolve(first)

    ETS.with_engine(first_runtime, fn ->
      first_table = ETS.table(first_runtime, :mnemonic_status)
      assert ETS.whereis(:mnemonic_status) == first_table
      assert ETS.insert(:mnemonic_status, {:same_key, :first})

      assert_raise RuntimeError, "nested callback failed", fn ->
        ETS.with_engine(second, fn ->
          refute ETS.whereis(:mnemonic_status) == first_table
          assert ETS.insert(:mnemonic_status, {:same_key, :second})
          raise "nested callback failed"
        end)
      end

      assert ETS.lookup(:mnemonic_status, :same_key) == [{:same_key, :first}]
      assert ETS.info(:mnemonic_status, :size) == 1
      assert ETS.select(:mnemonic_status, [{{:same_key, :"$1"}, [], [:"$1"]}]) == [:first]
      assert ETS.whereis(:unknown_table) == :undefined
    end)

    assert {:error, _reason} = ETS.attach(__MODULE__.Missing)

    assert_raise ArgumentError, ~r/mnemonic ETS table unavailable/, fn ->
      ETS.table(__MODULE__.Missing, :mnemonic_status)
    end
  end

  defmodule BlockingExtraction do
    @moduledoc false

    def extract(_text, opts) do
      test = Keyword.fetch!(opts, :visibility_test)
      send(test, {:intake_projection_started, self()})

      receive do
        :finish_intake ->
          %{
            entities: [],
            events: [],
            times: [],
            values: [],
            relations: [],
            metadata: %{provider: __MODULE__}
          }
      end
    end
  end

  test "hot tables are protected and mutations are routed through their owner" do
    moments = ETS.table(:mnemonic_moments)

    assert :ets.info(moments, :protection) == :protected

    assert_raise ArgumentError, fn ->
      :ets.insert(moments, {"unauthorized", %{text: "must not be inserted"}})
    end

    assert true = ETS.insert(:mnemonic_status, {:owner_routed, :ok})
    assert ETS.lookup(:mnemonic_status, :owner_routed) == [{:owner_routed, :ok}]
  end

  test "rich intake becomes hot-visible only after the batch commit marker" do
    scope = {:customer, "atomic-intake"}
    parent = self()

    intake =
      Task.async(fn ->
        SpectreMnemonic.remember(
          "Alice prefers email and reviews support requests every Monday",
          scope: scope,
          persist?: false,
          summaries?: false,
          categories?: false,
          entity_extraction_adapter: BlockingExtraction,
          visibility_test: parent
        )
      end)

    assert_receive {:intake_projection_started, executor}
    assert Focus.moments(scope: scope) == []

    recall =
      Task.async(fn ->
        SpectreMnemonic.recall("Alice email Monday", scope: scope)
      end)

    assert Task.yield(recall, 50) == nil

    send(executor, :finish_intake)
    assert {:ok, packet} = Task.await(intake, 5_000)
    assert packet.moments != []

    assert {:ok, recall_after_commit} = Task.await(recall, 5_000)
    assert recall_after_commit.moments != []

    visible_ids = MapSet.new(Focus.moments(scope: scope), & &1.id)
    assert Enum.all?(packet.moments, &MapSet.member?(visible_ids, &1.id))
  end
end
