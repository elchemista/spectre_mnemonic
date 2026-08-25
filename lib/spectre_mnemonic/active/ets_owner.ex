defmodule SpectreMnemonic.Active.ETSOwner do
  @moduledoc """
  Owns the named ETS tables used by the live focus.

  Keeping a tiny owner process alive is the simplest way to keep named ETS
  tables available to the rest of the supervision tree.
  """

  use GenServer

  @tables [
    {:mnemonic_signals, :set},
    {:mnemonic_moments, :set},
    {:mnemonic_moments_by_stream, :bag},
    {:mnemonic_moments_by_task, :bag},
    {:mnemonic_moments_by_scope, :bag},
    {:mnemonic_moments_by_signal, :set},
    {:mnemonic_moment_counts, :set},
    {:mnemonic_moment_eviction, :ordered_set},
    {:mnemonic_moment_eviction_keys, :set},
    {:mnemonic_status, :set},
    {:mnemonic_associations, :set},
    {:mnemonic_associations_by_scope, :bag},
    {:mnemonic_associations_by_memory, :bag},
    {:mnemonic_entity_registry, :set},
    {:mnemonic_episodes, :set},
    {:mnemonic_episodes_by_scope, :bag},
    {:mnemonic_atlas_dirty, :bag},
    {:mnemonic_erasure_markers, :set},
    {:mnemonic_attention, :set},
    {:mnemonic_artifacts, :set},
    {:mnemonic_action_recipes, :set},
    {:mnemonic_observations, :set},
    {:mnemonic_observations_by_scope, :bag},
    {:mnemonic_mental_models, :set},
    {:mnemonic_mental_models_by_scope, :bag},
    {:mnemonic_governance_states, :set},
    {:mnemonic_governance_states_by_scope, :bag},
    {:mnemonic_governance_facts, :set},
    {:mnemonic_embedding_index, :set},
    {:mnemonic_vettore_collections, :set},
    {:mnemonic_durable_records, :set},
    {:mnemonic_model_cache, :set},
    {:mnemonic_framed_log_counters, :set}
  ]

  @doc "Starts the ETS owner process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Returns true when a key exists in a named mnemonic ETS table."
  @spec member?(atom(), term()) :: boolean()
  def member?(table, key) do
    :ets.member(table, key)
  rescue
    ArgumentError -> false
  end

  @impl GenServer
  @spec init(map()) :: {:ok, map()}
  def init(state) do
    # Named ETS tables are blunt tools, but for hot memory they are fast,
    # observable, and blessedly not pretending to be a distributed brain.
    Enum.each(@tables, &create_table/1)
    {:ok, state}
  end

  @spec create_table({atom(), :set | :bag | :ordered_set}) :: :ok | :ets.tid()
  defp create_table({table, type}) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, type, :compressed, read_concurrency: true])
    end
  end
end
