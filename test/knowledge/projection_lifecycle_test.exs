defmodule SpectreMnemonic.Knowledge.ProjectionLifecycleTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Knowledge.Base
  alias SpectreMnemonic.Knowledge.Projection
  alias SpectreMnemonic.Knowledge.SMEM

  @namespace "spectre_mnemonic_test"

  test "replacing a knowledge id removes obsolete postings and erasure purges one scope" do
    opts = [namespace: @namespace, scope: :knowledge_lifecycle]

    event = %{
      id: "preference",
      type: :fact,
      text: "apricot",
      namespace: @namespace,
      scope: :knowledge_lifecycle
    }

    assert {:ok, _} = SMEM.append(event, opts)
    assert {:ok, _} = SMEM.append(%{event | text: "blueberry"}, opts)
    assert {:ok, [updated], _meta} = Projection.events(opts)
    assert updated.text == "blueberry"

    assert {:ok, [^updated], %{lexical: 1}} = Projection.candidates(["blueberry"], opts)
    assert {:ok, _recent_fallback, %{lexical: 0}} = Projection.candidates(["apricot"], opts)

    other = %{event | id: "other", scope: :other, text: "retained"}
    assert {:ok, _} = SMEM.append(other, namespace: @namespace, scope: :other)

    marker = %{
      id: "erase-marker",
      type: :compaction_marker,
      namespace: @namespace,
      scope: :knowledge_lifecycle,
      metadata: %{erasure?: true}
    }

    assert :ok = Projection.upsert(marker, opts)
    assert {:ok, [], _} = Projection.events(opts)
    assert {:ok, [%{id: "other"}], _} = Projection.events(namespace: @namespace, scope: :other)
  end

  test "knowledge reads recover from their journal while a projection child is unavailable" do
    opts = [namespace: @namespace, scope: :knowledge_fallback]
    assert {:ok, _} = SMEM.append(%{type: :fact, text: "journal fallback"}, opts)
    {:ok, runtime} = Engine.resolve(SpectreMnemonic.DefaultEngine)
    child = {Projection, runtime.config.ref}
    assert :ok = Supervisor.terminate_child(runtime.engine_pid, child)

    on_exit(fn ->
      if Projection.status(runtime).running? == false do
        Supervisor.restart_child(runtime.engine_pid, child)
      end
    end)

    assert %{running?: false, events: 0} = Projection.status(runtime)
    assert {:ok, [%{text: "journal fallback"}]} = Base.events(opts)
    assert {:ok, [_]} = Base.search("journal", opts)
    assert {:ok, _} = Supervisor.restart_child(runtime.engine_pid, child)
    assert {:ok, [%{text: "journal fallback"}], _} = Projection.events(opts)
  end
end
