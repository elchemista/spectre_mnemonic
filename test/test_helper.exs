real_embedding_tests? = System.get_env("MNEMONIC_REAL_EMBEDDING_TESTS") == "1"
exclude = if real_embedding_tests?, do: [], else: [real_embedding: true]

ExUnit.start(exclude: exclude)

defmodule SpectreMnemonic.MemoryCase do
  @moduledoc """
  Shared test setup for memory scenarios.

  The library keeps live state in named ETS tables and writes to disk by
  default, so tests use this helper to start each scenario from a clean memory.
  """

  use ExUnit.CaseTemplate

  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Recall.Index

  @tables [
    :mnemonic_signals,
    :mnemonic_streams,
    :mnemonic_moments,
    :mnemonic_moments_by_stream,
    :mnemonic_moments_by_task,
    :mnemonic_moments_by_scope,
    :mnemonic_moments_by_namespace,
    :mnemonic_moments_by_signal,
    :mnemonic_moment_counts,
    :mnemonic_status,
    :mnemonic_associations,
    :mnemonic_associations_by_scope,
    :mnemonic_associations_by_memory,
    :mnemonic_entity_registry,
    :mnemonic_episodes,
    :mnemonic_episodes_by_scope,
    :mnemonic_atlas_dirty,
    :mnemonic_erasure_markers,
    :mnemonic_attention,
    :mnemonic_artifacts,
    :mnemonic_action_recipes,
    :mnemonic_observations,
    :mnemonic_observations_by_scope,
    :mnemonic_mental_models,
    :mnemonic_mental_models_by_scope,
    :mnemonic_governance_states,
    :mnemonic_governance_states_by_scope,
    :mnemonic_governance_facts,
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
    Application.delete_env(:spectre_mnemonic, :consolidation_adapter)
    Application.delete_env(:spectre_mnemonic, :atlas_label_adapter)
    Application.delete_env(:spectre_mnemonic, :compact_adapter)
    Application.delete_env(:spectre_mnemonic, :reflection_adapter)
    Application.delete_env(:spectre_mnemonic, :knowledge)
    Application.delete_env(:spectre_mnemonic, :consolidation_scheduler)
    Application.delete_env(:spectre_mnemonic, :secret_key)
    Application.delete_env(:spectre_mnemonic, :secret_key_fun)
    Application.delete_env(:spectre_mnemonic, :secret_authorization_adapter)
    Application.delete_env(:spectre_mnemonic, :secret_crypto_adapter)
    Application.delete_env(:spectre_mnemonic, :plugs)
    Application.delete_env(:spectre_mnemonic, :hot_memory)
    Application.delete_env(:spectre_mnemonic, :max_frame_bytes)
    reset_disk_root()
    Manager.reset_dedupe()
    clear_memory()

    on_exit(fn ->
      Application.delete_env(:spectre_mnemonic, :embedding_adapter)
      Application.delete_env(:spectre_mnemonic, :embedding)
      Application.delete_env(:spectre_mnemonic, :persistent_memory)
      Application.delete_env(:spectre_mnemonic, :action_runtime_adapter)
      Application.delete_env(:spectre_mnemonic, :consolidation_adapter)
      Application.delete_env(:spectre_mnemonic, :atlas_label_adapter)
      Application.delete_env(:spectre_mnemonic, :compact_adapter)
      Application.delete_env(:spectre_mnemonic, :reflection_adapter)
      Application.delete_env(:spectre_mnemonic, :knowledge)
      Application.delete_env(:spectre_mnemonic, :consolidation_scheduler)
      Application.delete_env(:spectre_mnemonic, :secret_key)
      Application.delete_env(:spectre_mnemonic, :secret_key_fun)
      Application.delete_env(:spectre_mnemonic, :secret_authorization_adapter)
      Application.delete_env(:spectre_mnemonic, :secret_crypto_adapter)
      Application.delete_env(:spectre_mnemonic, :plugs)
      Application.delete_env(:spectre_mnemonic, :hot_memory)
      Application.delete_env(:spectre_mnemonic, :max_frame_bytes)
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

    if Process.whereis(DurableIndex) do
      DurableIndex.reset()
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
