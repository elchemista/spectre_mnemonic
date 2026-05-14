defmodule SpectreMnemonic.Persistence.Family do
  @moduledoc false

  @known [
    :signals,
    :moments,
    :summaries,
    :categories,
    :embeddings,
    :associations,
    :knowledge,
    :memory_states,
    :consolidation_jobs,
    :semantic_compaction_jobs,
    :artifacts,
    :action_recipes,
    :tombstones
  ]

  @by_string Map.new(@known, &{Atom.to_string(&1), &1})

  @spec from_string(binary()) :: {:ok, atom()} | :error
  def from_string(family) when is_binary(family), do: Map.fetch(@by_string, family)

  @spec from_string!(binary()) :: atom()
  def from_string!(family) when is_binary(family) do
    case from_string(family) do
      {:ok, family} -> family
      :error -> raise ArgumentError, "unknown semantic family: #{family}"
    end
  end
end
