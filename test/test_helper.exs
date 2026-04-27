ExUnit.start()

defmodule SpectreMnemonic.MemoryCase do
  @moduledoc """
  Shared test setup for memory scenarios.

  The library keeps live state in named ETS tables and writes to disk by
  default, so tests use this helper to start each scenario from a clean memory.
  """

  use ExUnit.CaseTemplate

  alias SpectreMnemonic.Recall.Index

  @tables [
    :mnemonic_signals,
    :mnemonic_streams,
    :mnemonic_moments,
    :mnemonic_status,
    :mnemonic_associations,
    :mnemonic_attention,
    :mnemonic_artifacts,
    :mnemonic_action_recipes,
    :mnemonic_embedding_index,
    :mnemonic_embedding_labels
  ]

  using do
    quote do
      import SpectreMnemonic.MemoryCase
    end
  end

  setup do
    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
    Application.delete_env(:spectre_mnemonic, :embedding)
    Application.delete_env(:spectre_mnemonic, :persistent_memory)
    Application.delete_env(:spectre_mnemonic, :action_runtime_adapter)
    Application.delete_env(:spectre_mnemonic, :summarizer_adapter)
    Application.delete_env(:spectre_mnemonic, :consolidation_adapter)
    Application.delete_env(:spectre_mnemonic, :compact_adapter)
    Application.delete_env(:spectre_mnemonic, :knowledge)
    reset_disk_root()
    clear_memory()

    on_exit(fn ->
      Application.delete_env(:spectre_mnemonic, :embedding_adapter)
      Application.delete_env(:spectre_mnemonic, :embedding)
      Application.delete_env(:spectre_mnemonic, :persistent_memory)
      Application.delete_env(:spectre_mnemonic, :action_runtime_adapter)
      Application.delete_env(:spectre_mnemonic, :summarizer_adapter)
      Application.delete_env(:spectre_mnemonic, :consolidation_adapter)
      Application.delete_env(:spectre_mnemonic, :compact_adapter)
      Application.delete_env(:spectre_mnemonic, :knowledge)
      clear_memory()
      File.rm_rf!("mnemonic_data")
      File.rm_rf!("mnemonic_data_secondary")
    end)

    :ok
  end

  @doc "Deletes all rows from known mnemonic ETS tables."
  @spec clear_memory :: :ok
  def clear_memory do
    Enum.each(@tables, fn table ->
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end)

    if Process.whereis(Index) do
      Index.reset()
    end
  end

  @doc "Recreates the default disk folders used by the already-started disk process."
  @spec reset_disk_root :: :ok
  def reset_disk_root do
    File.rm_rf!("mnemonic_data")
    File.mkdir_p!(Path.join(["mnemonic_data", "segments"]))
    File.mkdir_p!(Path.join(["mnemonic_data", "snapshots"]))
    File.mkdir_p!(Path.join(["mnemonic_data", "artifacts"]))
    File.mkdir_p!(Path.join(["mnemonic_data", "knowledge"]))
  end
end
