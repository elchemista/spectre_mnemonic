real_embedding_tests? = System.get_env("MNEMONIC_REAL_EMBEDDING_TESTS") == "1"
exclude = if real_embedding_tests?, do: [], else: [real_embedding: true]

ExUnit.start(exclude: exclude)

defmodule SpectreMnemonic.MemoryCase do
  @moduledoc """
  Shared test setup for memory scenarios.

  The library keeps live state in Engine-owned ETS tables and writes to disk by
  default, so tests use this helper to start each scenario from a clean memory.
  """

  use ExUnit.CaseTemplate

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Embedding.Model2VecStatic
  alias SpectreMnemonic.Engine.Projection
  alias SpectreMnemonic.Knowledge.Projection, as: KnowledgeProjection
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.RepairQueue
  alias SpectreMnemonic.Recall.Index

  @tables [
    :mnemonic_signals,
    :mnemonic_moments,
    :mnemonic_moments_by_stream,
    :mnemonic_moments_by_task,
    :mnemonic_moments_by_scope,
    :mnemonic_moments_by_signal,
    :mnemonic_moment_counts,
    :mnemonic_moment_sizes,
    :mnemonic_hot_bytes,
    :mnemonic_moment_eviction,
    :mnemonic_moment_eviction_keys,
    :mnemonic_status,
    :mnemonic_associations,
    :mnemonic_associations_by_scope,
    :mnemonic_associations_by_memory,
    :mnemonic_entity_registry,
    :mnemonic_episodes,
    :mnemonic_episodes_by_scope,
    :mnemonic_atlas_dirty,
    :mnemonic_erasure_markers,
    :mnemonic_batch_commits,
    :mnemonic_attention,
    :mnemonic_artifacts,
    :mnemonic_action_recipes,
    :mnemonic_observations,
    :mnemonic_observations_by_scope,
    :mnemonic_mental_models,
    :mnemonic_mental_models_by_scope,
    :mnemonic_governance_states,
    :mnemonic_governance_states_by_scope,
    :mnemonic_governance_facts
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
    RepairQueue.reset()
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
      _removed = File.rm_rf("mnemonic_data")
      _removed = File.rm_rf("mnemonic_data_secondary")
    end)

    :ok
  end

  @doc "Deletes all rows from the default Engine's hot tables."
  @spec clear_memory :: :ok
  def clear_memory do
    Enum.each(@tables, fn table ->
      ETS.delete_all_objects(table)
    end)

    Model2VecStatic.reset_cache()
    Index.reset()

    DurableIndex.reset()

    Projection.reset(SpectreMnemonic.DefaultEngine)
    KnowledgeProjection.reset(SpectreMnemonic.DefaultEngine)
  rescue
    ArgumentError -> :ok
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

  @doc false
  @spec engine_child_pid(module(), term()) :: pid() | nil
  def engine_child_pid(module, engine \\ SpectreMnemonic.DefaultEngine) do
    case SpectreMnemonic.Engine.resolve(engine) do
      {:ok, runtime} -> find_engine_child(runtime, module)
      {:error, _reason} -> nil
    end
  end

  defp find_engine_child(runtime, module) do
    child_id = {module, runtime.config.ref}

    runtime.engine_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end
end
