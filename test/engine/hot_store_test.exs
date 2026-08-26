defmodule SpectreMnemonic.Engine.HotStoreTest do
  use SpectreMnemonic.MemoryCase, async: false

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Active.Focus

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
