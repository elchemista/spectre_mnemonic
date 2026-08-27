defmodule SpectreMnemonic.Recall.GraphExpansion do
  @moduledoc false

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Graph.Traversal

  @doc false
  @spec expand([map()], map(), keyword()) :: Traversal.result()
  def expand(moments, budget, opts) do
    traversal_opts =
      opts
      |> Keyword.put_new(:graph_depth, budget.graph_depth)
      |> Keyword.put_new(:hop_decay, budget.hop_decay)
      |> Keyword.put_new(:activation_floor, budget.activation_floor)
      |> Keyword.put_new(:max_graph_nodes, budget.max_graph_nodes)

    Traversal.expand(moments, traversal_opts)
  end

  @doc false
  @spec artifacts([map()], [map()], keyword()) :: [term()]
  def artifacts(moments, associations, opts) do
    ids = MapSet.new(Enum.map(moments, & &1.id))

    associations
    |> Enum.flat_map(fn association ->
      cond do
        MapSet.member?(ids, association.source_id) -> [association.target_id]
        MapSet.member?(ids, association.target_id) -> [association.source_id]
        true -> []
      end
    end)
    |> Focus.artifacts(opts)
  end

  @doc false
  @spec action_recipes([map()], [map()], keyword()) :: [term()]
  def action_recipes(moments, associations, opts) do
    moment_ids = MapSet.new(Enum.map(moments, & &1.id))
    related_ids = related_memory_ids(moment_ids, associations)

    related_ids
    |> Focus.associations_for_ids(opts)
    |> Enum.flat_map(fn association ->
      if MapSet.member?(related_ids, association.source_id) and
           association.relation == :attached_action do
        [association.target_id]
      else
        []
      end
    end)
    |> Focus.action_recipes(opts)
  end

  @spec related_memory_ids(MapSet.t(), [map()]) :: MapSet.t()
  defp related_memory_ids(moment_ids, associations) do
    Enum.reduce(associations, moment_ids, fn association, acc ->
      cond do
        MapSet.member?(moment_ids, association.source_id) ->
          MapSet.put(acc, association.target_id)

        MapSet.member?(moment_ids, association.target_id) ->
          MapSet.put(acc, association.source_id)

        true ->
          acc
      end
    end)
  end
end
