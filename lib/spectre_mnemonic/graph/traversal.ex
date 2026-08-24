defmodule SpectreMnemonic.Graph.Traversal do
  @moduledoc """
  Weighted, typed spreading activation over one active-memory partition.

  Activation propagates through association weights, hop decay, and logarithmic
  hub damping. The result includes stable paths that callers can expose as a
  recall explanation without crossing a partition boundary.
  """

  alias SpectreMnemonic.Active.Focus

  @type result :: %{
          moments: [term()],
          activations: %{optional(binary()) => float()},
          paths: %{optional(binary()) => map()}
        }

  @doc "Expands seed moments using bounded spreading activation."
  @spec expand([term()], keyword()) :: result()
  def expand([], _opts), do: %{moments: [], activations: %{}, paths: %{}}

  def expand(seeds, opts) do
    depth = non_negative(opts, :graph_depth, 2)
    hop_decay = bounded_float(opts, :hop_decay, 0.72, 0.0, 1.0)
    floor = bounded_float(opts, :activation_floor, 0.08, 0.0, 1.0)
    max_nodes = non_negative(opts, :max_graph_nodes, 200)
    associations = Focus.associations(opts) |> Enum.filter(&traversable?(&1, opts))
    adjacency = adjacency(associations)
    degree = Map.new(adjacency, fn {id, edges} -> {id, length(edges)} end)

    seed_ids = seeds |> Enum.map(& &1.id) |> Enum.uniq()
    activations = Map.new(seed_ids, &{&1, 1.0})
    paths = Map.new(seed_ids, &{&1, %{seed_id: &1, activation: 1.0, hops: []}})

    config = %{
      adjacency: adjacency,
      degree: degree,
      decay: hop_decay,
      floor: floor,
      max_nodes: max_nodes
    }

    {activations, paths} = spread(seed_ids, depth, activations, paths, config)

    moments =
      activations
      |> Enum.sort_by(fn {id, activation} -> {-activation, id} end)
      |> Enum.map(fn {id, _activation} -> id end)
      |> Focus.moments_by_ids(opts)
      |> Enum.sort_by(fn moment -> {-Map.get(activations, moment.id, 0.0), moment.id} end)

    %{moments: moments, activations: activations, paths: paths}
  end

  @spec spread([binary()], non_neg_integer(), map(), map(), map()) :: {map(), map()}
  defp spread(_frontier, 0, activations, paths, _config),
    do: {activations, paths}

  defp spread([], _depth, activations, paths, _config),
    do: {activations, paths}

  defp spread(frontier, depth, activations, paths, config) do
    {next, activations, paths} =
      Enum.reduce(frontier, {MapSet.new(), activations, paths}, fn source_id,
                                                                   {next, values, paths} ->
        source_activation = Map.get(values, source_id, 0.0)
        damping = 1.0 / :math.log(2 + Map.get(config.degree, source_id, 0))

        Enum.reduce(Map.get(config.adjacency, source_id, []), {next, values, paths}, fn edge,
                                                                                        acc ->
          propagate(
            edge,
            source_id,
            source_activation,
            damping,
            config.decay,
            config.floor,
            config.max_nodes,
            acc
          )
        end)
      end)

    spread(MapSet.to_list(next), depth - 1, activations, paths, config)
  end

  @spec propagate(map(), binary(), float(), float(), float(), float(), non_neg_integer(), tuple()) ::
          tuple()
  defp propagate(edge, source_id, source_activation, damping, decay, floor, max_nodes, acc) do
    {next, activations, paths} = acc
    target_id = edge.other
    activation = source_activation * edge.association.weight * decay * damping
    previous = Map.get(activations, target_id, 0.0)
    room? = Map.has_key?(activations, target_id) or map_size(activations) < max_nodes

    if room? and activation >= floor and activation > previous do
      source_path = Map.fetch!(paths, source_id)

      hop = %{
        association_id: edge.association.id,
        relation: edge.association.relation,
        weight: edge.association.weight,
        from: source_id,
        to: target_id,
        activation: activation
      }

      path = %{
        seed_id: source_path.seed_id,
        activation: activation,
        hops: source_path.hops ++ [hop]
      }

      {MapSet.put(next, target_id), Map.put(activations, target_id, activation),
       Map.put(paths, target_id, path)}
    else
      acc
    end
  end

  @spec adjacency([term()]) :: map()
  defp adjacency(associations) do
    Enum.reduce(associations, %{}, fn association, graph ->
      graph
      |> Map.update(
        association.source_id,
        [%{other: association.target_id, association: association}],
        &[notify_edge(association.target_id, association) | &1]
      )
      |> Map.update(
        association.target_id,
        [%{other: association.source_id, association: association}],
        &[notify_edge(association.source_id, association) | &1]
      )
    end)
  end

  @spec notify_edge(binary(), term()) :: map()
  defp notify_edge(other, association), do: %{other: other, association: association}

  @spec traversable?(term(), keyword()) :: boolean()
  defp traversable?(association, opts) do
    included = Keyword.get(opts, :relations, Keyword.get(opts, :relation_types, :all))
    excluded = MapSet.new(List.wrap(Keyword.get(opts, :exclude_relations, [])))
    prune = bounded_float(opts, :prune_threshold, 0.03, 0.0, 1.0)

    association.weight >= prune and not MapSet.member?(excluded, association.relation) and
      (included == :all or association.relation in List.wrap(included))
  end

  @spec non_negative(keyword(), atom(), non_neg_integer()) :: non_neg_integer()
  defp non_negative(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end

  @spec bounded_float(keyword(), atom(), float(), float(), float()) :: float()
  defp bounded_float(opts, key, default, low, high) do
    case Keyword.get(opts, key, default) do
      value when is_number(value) -> (value * 1.0) |> max(low) |> min(high)
      _invalid -> default
    end
  end
end
