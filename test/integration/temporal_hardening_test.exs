defmodule SpectreMnemonic.Integration.TemporalHardeningTest do
  use ExUnit.Case, async: true

  alias SpectreMnemonic.Memory.Temporal

  @now ~U[2026-07-20 10:00:00Z]

  test "normalizes every supported temporal representation" do
    assert Temporal.normalize(@now) == @now
    assert Temporal.normalize(~N[2026-07-20 10:00:00]) == @now
    assert Temporal.normalize(~D[2026-07-20]) == ~U[2026-07-20 00:00:00Z]
    assert Temporal.normalize("2026-07-20T12:00:00+02:00") == @now
    assert Temporal.normalize("not-a-date") == nil
    assert Temporal.normalize(:invalid) == nil
  end

  test "from_opts defaults observation time and metadata keeps caller authority" do
    temporal =
      Temporal.from_opts(
        [occurred_at: ~D[2026-07-19], valid_until: "2026-07-21T00:00:00Z"],
        @now
      )

    assert temporal.observed_at == @now
    assert temporal.occurred_at == ~U[2026-07-19 00:00:00Z]
    assert temporal.valid_until == ~U[2026-07-21 00:00:00Z]
    assert temporal.valid_from == nil

    metadata = Temporal.put_metadata(%{observed_at: :caller_value}, temporal)
    assert metadata.observed_at == :caller_value
    assert metadata.occurred_at == temporal.occurred_at
    refute Map.has_key?(metadata, :valid_from)
  end

  test "string-keyed metadata and provenance remain temporally isolated" do
    memory = %{
      "metadata" => %{
        "occurred_at" => "2026-07-20T10:00:00Z",
        "provenance" => %{
          "valid_from" => "2026-07-20T09:00:00Z",
          "valid_until" => "2026-07-20T11:00:00Z"
        }
      }
    }

    temporal = Temporal.temporal_map(memory)
    assert temporal.occurred_at == @now
    assert temporal.valid_from == ~U[2026-07-20 09:00:00Z]
    assert temporal.valid_until == ~U[2026-07-20 11:00:00Z]

    assert Temporal.match?(memory,
             occurred_after: @now,
             occurred_before: @now,
             valid_at: @now
           )

    refute Temporal.match?(memory, occurred_after: ~U[2026-07-20 10:00:01Z])
    refute Temporal.match?(memory, occurred_before: ~U[2026-07-20 09:59:59Z])
    refute Temporal.match?(memory, valid_at: ~U[2026-07-20 11:00:01Z])
  end

  test "temporal filters fail closed for missing values and ignore invalid cutoffs" do
    refute Temporal.match?(%{}, occurred_after: @now)
    refute Temporal.match?(%{}, occurred_before: @now)
    assert Temporal.match?(%{}, valid_at: @now)
    assert Temporal.match?(%{}, occurred_after: :invalid, occurred_before: :invalid)
    assert Temporal.match?(%{}, valid_at: :invalid)
    assert Temporal.temporal_map(:not_a_map) == %{}
  end
end
