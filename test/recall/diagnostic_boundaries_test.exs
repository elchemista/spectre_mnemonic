defmodule SpectreMnemonic.Recall.DiagnosticBoundariesTest do
  use ExUnit.Case, async: true

  alias SpectreMnemonic.Durable.Stats
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Recall.Diagnostics

  test "recall diagnostics redact private failures before strict-consistency errors" do
    context = %QueryContext{vector: [1.0], embedding: %{error: "private embedding response"}}

    diagnostics =
      Diagnostics.build(
        context,
        %{
          mode: :projection,
          candidates: 4,
          total: 9,
          sources: %{
            {:term, "retry"} => 2,
            {:entity, "customer"} => 2,
            lexical: 1,
            entity: 1,
            recent: 3,
            ignored: 100
          }
        },
        :ok,
        %{
          durable_index: {:error, {:unavailable, "private database address"}},
          primary_store: {:degraded, RuntimeError.exception("private connection string")},
          stores: %{database: {:error, "private database credentials"}}
        },
        [:vector_hit],
        [:durable_hit],
        [],
        [:chosen]
      )

    assert diagnostics.completeness == :partial
    assert diagnostics.sources.hot_vector == {:degraded, :redacted}
    assert diagnostics.sources.durable_index == {:error, :unavailable}
    assert diagnostics.sources.primary_store == {:degraded, RuntimeError}
    assert diagnostics.stores.database == {:error, :redacted}
    assert diagnostics.candidates.lexical == 3
    assert diagnostics.candidates.entity == 3
    assert diagnostics.candidates.recent == 3
    assert diagnostics.candidates.selected == 4
    refute inspect(diagnostics) =~ "private"

    assert :ok = Diagnostics.enforce_consistency(diagnostics, consistency: :available)

    assert :ok =
             Diagnostics.enforce_consistency(diagnostics,
               consistency: :strict,
               required_sources: [:hot_lexical]
             )

    assert {:error, {:mnemonic_recall_incomplete, %{hot_vector: {:degraded, :redacted}}}} =
             Diagnostics.enforce_consistency(diagnostics,
               consistency: :strict,
               required_sources: [:hot_vector]
             )
  end

  test "lifecycle visibility agrees between replayed maps and live ETS indices" do
    previous = ~U[2026-11-16 12:00:00Z]
    current = ~U[2026-11-17 12:00:00Z]
    table = :ets.new(__MODULE__, [:bag])

    histories = %{
      forgotten: [
        %{state: :active, inserted_at: previous},
        %{"state" => :forgotten, "inserted_at" => current}
      ],
      restored: [
        %{state: :contradicted, inserted_at: previous},
        %{state: :active, inserted_at: current}
      ],
      malformed: [%{"state" => "forgotten", "inserted_at" => current}],
      missing: []
    }

    for {key, values} <- histories, value <- values, do: :ets.insert(table, {key, value})

    for source <- [histories, table] do
      assert Stats.latest_state(:forgotten, source) == :forgotten
      assert Stats.hidden?(:forgotten, source)
      assert Stats.latest_state(:restored, source) == :active
      refute Stats.hidden?(:restored, source)
      assert Stats.latest_state(:malformed, source) == nil
      refute Stats.hidden?(:malformed, source)
      assert Stats.latest_state(:missing, source) == nil
    end

    :ets.delete(table)
    assert Stats.latest_state(:forgotten, table) == nil
  end
end
