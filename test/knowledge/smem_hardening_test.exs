defmodule SpectreMnemonic.Knowledge.SMEMHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Knowledge.SMEM

  test "batch append, default reduce arity, and replace normalize external event shapes" do
    assert {:ok, [first_seq, second_seq]} =
             SMEM.append_many([
               %{"type" => "skill", "name" => "Batch skill", "steps" => ["one"]},
               %{type: :unsupported, text: %{structured: :value}, custom_key: "preserved"}
             ])

    assert second_seq > first_seq

    assert {:ok, [first_frame]} =
             SMEM.reduce([], fn frame, _acc -> {:halt, [frame]} end)

    assert {^first_seq, _timestamp, %{type: :skill, name: "Batch skill"}} = first_frame

    assert {:ok, events} = SMEM.replay()
    assert Enum.at(events, 1).type == :fact
    assert Enum.at(events, 1).text =~ "structured"

    assert {:ok, 1} = SMEM.replace([%{type: "latest-ingestion", text: "replacement"}])
    assert {:ok, [%{type: :latest_ingestion, text: "replacement"}]} = SMEM.replay()

    assert SMEM.event_types() |> Enum.member?(:compaction_marker)
    assert SMEM.data_root() == Path.join("mnemonic_data", "knowledge")
    assert SMEM.path() == Path.join(["mnemonic_data", "knowledge", "knowledge.smem"])
  end

  test "scoped replace preserves other partitions and rejects invalid batch events" do
    alpha = {:tenant, "knowledge-alpha"}
    beta = {:tenant, "knowledge-beta"}

    assert {:ok, _seq} = SMEM.append(%{type: :fact, text: "alpha old"}, scope: alpha)
    assert {:ok, _seq} = SMEM.append(%{type: :fact, text: "beta kept"}, scope: beta)

    assert {:ok, 1} =
             SMEM.replace([%{type: :summary, summary: "alpha new"}], scope: alpha)

    assert {:ok, [%{summary: "alpha new"}]} = SMEM.replay(scope: alpha)
    assert {:ok, [%{text: "beta kept"}]} = SMEM.replay(scope: beta)

    assert {:error, :invalid_knowledge_event} = SMEM.append_many([%{}, :invalid])

    assert {:error, {:scope_mismatch, ^alpha, ^beta}} =
             SMEM.append_many([%{scope: beta, text: "wrong"}], scope: alpha)
  end

  test "normalization rejects namespace conflicts and supports unknown keys safely" do
    normalized =
      SMEM.normalize_event(%{
        "type" => "PROCEDURE",
        "text" => "  normalized text  ",
        "unknown-key" => "ignored by consumers"
      })

    assert normalized.type == :procedure
    assert normalized.text == "normalized text"
    assert normalized.namespace == "spectre_mnemonic_test"

    assert_raise ArgumentError, ~r/does not match/, fn ->
      SMEM.normalize_event(%{namespace: "other", text: "cross namespace"})
    end
  end

  test "replay stops safely for incomplete, unknown, invalid, and corrupt frames" do
    root = tmp_root("smem-corrupt")
    opts = [data_root: root]
    path = Path.join([root, "knowledge", "knowledge.smem"])

    assert {:ok, _seq} = SMEM.append(%{text: "valid frame"}, opts)
    valid = File.read!(path)

    File.write!(path, binary_part(valid, 0, byte_size(valid) - 1))
    assert {:ok, []} = SMEM.replay(opts)

    File.write!(path, "UNKNOWN")
    assert {:ok, []} = SMEM.replay(opts)

    File.write!(path, invalid_term_frame())
    assert {:ok, []} = SMEM.replay(opts)

    File.write!(path, corrupt_last_byte(valid))
    assert {:ok, []} = SMEM.replay(opts)
  end

  test "public append reports a stopped writer without calling a missing process" do
    supervisor = SpectreMnemonic.Supervisor
    :ok = Supervisor.terminate_child(supervisor, SMEM)

    on_exit(fn ->
      if Process.whereis(SMEM) == nil do
        {:ok, _pid} = Supervisor.restart_child(supervisor, SMEM)
      end
    end)

    assert {:error, :knowledge_writer_not_started} = SMEM.append(%{text: "not written"})
    {:ok, _pid} = Supervisor.restart_child(supervisor, SMEM)
  end

  defp invalid_term_frame do
    payload = <<131, 255>>
    crc = :erlang.crc32(payload)

    <<"SKNW", 1, 1::unsigned-64, 100::signed-64, byte_size(payload)::32, crc::32,
      payload::binary>>
  end

  defp corrupt_last_byte(binary) do
    prefix_size = byte_size(binary) - 1
    <<prefix::binary-size(^prefix_size), last>> = binary
    <<prefix::binary, Bitwise.bxor(last, 0xFF)>>
  end

  defp tmp_root(label) do
    root =
      Path.join(System.tmp_dir!(), "spectre-#{label}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
