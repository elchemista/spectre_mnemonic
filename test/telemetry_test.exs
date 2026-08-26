defmodule SpectreMnemonic.TelemetryTest do
  use SpectreMnemonic.MemoryCase

  test "public memory spans emit content-free lifecycle telemetry" do
    handler = {__MODULE__, make_ref()}

    events = [
      [:spectre_mnemonic, :remember, :stop],
      [:spectre_mnemonic, :recall, :stop],
      [:spectre_mnemonic, :embedding, :stop],
      [:spectre_mnemonic, :partition, :wait]
    ]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    scope = {:subject, "telemetry-#{System.unique_integer([:positive])}"}

    assert {:ok, _packet} =
             SpectreMnemonic.remember("telemetry payload must not enter metadata", scope: scope)

    assert {:ok, _packet} = SpectreMnemonic.recall("telemetry payload", scope: scope)

    for event <- events do
      assert_receive {:mnemonic_telemetry, ^event, measurements, metadata}, 1_000
      assert is_map(measurements)
      assert is_map(metadata)
      refute Map.has_key?(metadata, :input)
      refute Map.has_key?(metadata, :cue)
      refute Map.has_key?(metadata, :payload)
      refute inspect(measurements) =~ "telemetry payload"
      refute inspect(metadata) =~ "telemetry payload"
    end
  end

  test "exception telemetry redacts arbitrary binary reasons" do
    handler = {__MODULE__, make_ref()}
    event = [:spectre_mnemonic, :telemetry_test, :exception]

    :ok = :telemetry.attach(handler, event, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    assert catch_exit(
             SpectreMnemonic.Telemetry.span([:telemetry_test], %{}, fn ->
               exit("private adapter message")
             end)
           ) == "private adapter message"

    assert_receive {:mnemonic_telemetry, ^event, _measurements, metadata}, 1_000
    assert metadata.reason == :redacted
    refute inspect(metadata) =~ "private adapter message"
  end

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:mnemonic_telemetry, event, measurements, metadata})
  end
end
