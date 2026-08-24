defmodule SpectreMnemonic.Atlas do
  @moduledoc """
  Deterministic mind-map projection for one memory partition.

  Atlas is a bounded read model. Clusters are computed with synchronous weighted
  label propagation, so identical nodes and edges produce identical episodes,
  titles, layout hints, and statistics without a model adapter.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Episode
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Persistence.Manager

  defstruct nodes: [],
            edges: [],
            clusters: [],
            stats: %{},
            layout_hints: %{},
            truncated: %{nodes: false, edges: false}

  @type t :: %__MODULE__{
          nodes: [term()],
          edges: [Association.t()],
          clusters: [Episode.t()],
          stats: map(),
          layout_hints: map(),
          truncated: %{nodes: boolean(), edges: boolean()}
        }

  @doc "Builds a bounded atlas for exactly one namespace/scope partition."
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         {:ok, nodes} <- atlas_moments(opts) do
      build_from_nodes(nodes, opts)
    end
  end

  @spec atlas_moments(keyword()) :: {:ok, [term()]} | {:error, term()}
  defp atlas_moments(opts) do
    case Manager.replay(opts) do
      {:ok, records} ->
        durable =
          records
          |> Enum.filter(&(&1.family == :moments))
          |> Enum.map(& &1.payload)
          |> Enum.filter(&(match?(%Moment{}, &1) or match?(%Secret{}, &1)))

        {:ok, merge_memory_values(Focus.moments(opts), durable)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec atlas_associations(keyword()) :: {:ok, [Association.t()]} | {:error, term()}
  defp atlas_associations(opts) do
    case Manager.replay(opts) do
      {:ok, records} ->
        durable =
          records
          |> Enum.filter(&(&1.family == :associations))
          |> Enum.map(& &1.payload)
          |> Enum.filter(&match?(%Association{}, &1))

        {:ok, merge_memory_values(Focus.associations(opts), durable)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec merge_memory_values([map()], [map()]) :: [map()]
  defp merge_memory_values(hot, durable) do
    (durable ++ hot)
    |> Map.new(&{&1.id, &1})
    |> Map.values()
  end

  @doc false
  @spec materialize(keyword()) :: {:ok, [Episode.t()]} | {:error, term()}
  def materialize(opts) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         {:ok, dirty_ids} <- clustering_ids(opts),
         claimed_ids <- claim_dirty(dirty_ids, opts) do
      case materialize_dirty(claimed_ids, opts) do
        {:ok, clusters} ->
          {:ok, clusters}

        {:error, _reason} = error ->
          restore_dirty(claimed_ids, opts)
          error
      end
    end
  end

  @spec clustering_ids(keyword()) :: {:ok, [binary()]} | {:error, term()}
  defp clustering_ids(opts) do
    if Keyword.get(opts, :recluster, false) do
      case atlas_moments(opts) do
        {:ok, moments} -> {:ok, Enum.map(moments, & &1.id)}
        {:error, _reason} = error -> error
      end
    else
      {:ok, dirty_ids(opts)}
    end
  end

  @doc false
  @spec dirty_ids(keyword()) :: [binary()]
  def dirty_ids(opts) do
    partition = {Identity.namespace!(opts), Keyword.get(opts, :scope)}

    :mnemonic_atlas_dirty
    |> :ets.lookup(partition)
    |> Enum.map(fn {^partition, id} -> id end)
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  @spec materialize_dirty([binary()], keyword()) ::
          {:ok, [Episode.t()]} | {:error, term()}
  defp materialize_dirty([], opts) do
    if Keyword.get(opts, :recluster, false),
      do: persist_all_moments(opts),
      else: {:ok, []}
  end

  defp materialize_dirty(dirty_ids, opts) do
    ids = dirty_ids |> expanded_dirty_ids(opts) |> MapSet.new()

    with {:ok, moments} <- atlas_moments(opts) do
      moments
      |> Enum.filter(&MapSet.member?(ids, &1.id))
      |> persist_atlas(opts)
    end
  end

  @spec persist_all_moments(keyword()) :: {:ok, [Episode.t()]} | {:error, term()}
  defp persist_all_moments(opts) do
    with {:ok, moments} <- atlas_moments(opts), do: persist_atlas(moments, opts)
  end

  @spec persist_atlas([term()], keyword()) :: {:ok, [Episode.t()]} | {:error, term()}
  defp persist_atlas(nodes, opts) do
    with {:ok, atlas} <- build_from_nodes(nodes, opts),
         :ok <- ensure_complete_atlas(atlas),
         :ok <- supersede_clusters(atlas.clusters, atlas.nodes, opts),
         :ok <- persist_clusters(atlas.clusters, opts) do
      {:ok, atlas.clusters}
    end
  end

  @spec ensure_complete_atlas(t()) :: :ok | {:error, term()}
  defp ensure_complete_atlas(%__MODULE__{truncated: %{nodes: false, edges: false}}), do: :ok

  defp ensure_complete_atlas(%__MODULE__{truncated: truncated}),
    do: {:error, {:atlas_truncated, truncated}}

  @spec expanded_dirty_ids([binary()], keyword()) :: [binary()]
  defp expanded_dirty_ids(dirty_ids, opts) do
    limit = positive_limit(opts, :max_nodes, 10_000)
    initial = dirty_ids |> Enum.take(limit) |> MapSet.new()

    expand_component(initial, initial, opts, limit)
    |> MapSet.to_list()
  end

  @spec expand_component(MapSet.t(binary()), MapSet.t(binary()), keyword(), pos_integer()) ::
          MapSet.t(binary())
  defp expand_component(frontier, seen, opts, limit) do
    if MapSet.size(frontier) == 0 or MapSet.size(seen) >= limit do
      seen
    else
      discovered =
        frontier
        |> Focus.associations_for_ids(opts)
        |> Enum.reject(
          &(&1.relation in [:attached_action, :member_of, :same_as] or &1.weight <= 0.03)
        )
        |> Enum.flat_map(&[&1.source_id, &1.target_id])
        |> MapSet.new()
        |> MapSet.difference(seen)
        |> Enum.take(max(limit - MapSet.size(seen), 0))
        |> MapSet.new()

      expand_component(discovered, MapSet.union(seen, discovered), opts, limit)
    end
  end

  @spec claim_dirty([binary()], keyword()) :: [binary()]
  defp claim_dirty(ids, opts) do
    limit = positive_limit(opts, :max_nodes, 10_000)
    claimed = Enum.take(ids, limit)
    partition = {Identity.namespace!(opts), Keyword.get(opts, :scope)}

    Enum.each(claimed, &:ets.delete_object(:mnemonic_atlas_dirty, {partition, &1}))
    claimed
  end

  @spec restore_dirty([binary()], keyword()) :: :ok
  defp restore_dirty(ids, opts) do
    partition = {Identity.namespace!(opts), Keyword.get(opts, :scope)}
    Enum.each(ids, &:ets.insert(:mnemonic_atlas_dirty, {partition, &1}))
  end

  @spec build_from_nodes([term()], keyword()) :: {:ok, t()} | {:error, term()}
  defp build_from_nodes(source_nodes, opts) do
    all_nodes =
      Enum.sort_by(source_nodes, fn node ->
        {-timestamp(node), node.id}
      end)

    node_limit = positive_limit(opts, :max_nodes, 10_000)
    edge_limit = positive_limit(opts, :max_edges, 30_000)
    nodes = all_nodes |> Enum.take(node_limit) |> Enum.sort_by(& &1.id)
    node_ids = MapSet.new(Enum.map(nodes, & &1.id))

    with {:ok, associations} <- atlas_associations(opts) do
      all_edges =
        associations
        |> Enum.filter(&cluster_edge?(&1, node_ids))
        |> Enum.sort_by(& &1.id)

      edges = Enum.take(all_edges, edge_limit)
      clusters = clusters(nodes, edges, opts)

      {:ok,
       %__MODULE__{
         nodes: nodes,
         edges: edges,
         clusters: clusters,
         stats: stats(nodes, edges, clusters, opts),
         layout_hints: layout_hints(nodes),
         truncated: %{
           nodes: length(all_nodes) > length(nodes),
           edges: length(all_edges) > length(edges)
         }
       }}
    end
  end

  @spec timestamp(term()) :: integer()
  defp timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp timestamp(_node), do: 0

  @spec clusters([term()], [Association.t()], keyword()) :: [Episode.t()]
  defp clusters(nodes, edges, opts) do
    ids = Enum.map(nodes, & &1.id)
    labels = Map.new(ids, &{&1, &1})
    adjacency = weighted_adjacency(ids, edges)
    iterations = positive_limit(opts, :cluster_iterations, 12)
    labels = propagate_labels(labels, adjacency, iterations)
    moments = Map.new(nodes, &{&1.id, &1})
    minimum = positive_limit(opts, :cluster_min_size, 2)

    labels
    |> Enum.group_by(fn {_id, label} -> label end, fn {id, _label} -> id end)
    |> Map.values()
    |> Enum.map(&Enum.sort/1)
    |> Enum.filter(&(length(&1) >= minimum))
    |> Enum.sort()
    |> Enum.map(&episode(&1, moments, opts))
  end

  @spec propagate_labels(map(), map(), non_neg_integer()) :: map()
  defp propagate_labels(labels, _adjacency, 0), do: labels

  defp propagate_labels(labels, adjacency, remaining) do
    updated =
      labels
      |> Map.keys()
      |> Enum.sort()
      |> Map.new(fn id -> {id, strongest_label(id, labels, adjacency)} end)

    if updated == labels,
      do: labels,
      else: propagate_labels(updated, adjacency, remaining - 1)
  end

  @spec strongest_label(binary(), map(), map()) :: binary()
  defp strongest_label(id, labels, adjacency) do
    scores =
      adjacency
      |> Map.get(id, [])
      |> Enum.reduce(%{}, fn {neighbor, weight}, acc ->
        Map.update(acc, Map.fetch!(labels, neighbor), weight, &(&1 + weight))
      end)

    case Enum.sort_by(scores, fn {label, score} -> {-score, label} end) do
      [{label, _score} | _] -> min(label, Map.fetch!(labels, id))
      [] -> Map.fetch!(labels, id)
    end
  end

  @spec weighted_adjacency([binary()], [Association.t()]) :: map()
  defp weighted_adjacency(ids, edges) do
    graph = Map.new(ids, &{&1, []})

    Enum.reduce(edges, graph, fn edge, acc ->
      acc
      |> Map.update!(edge.source_id, &[{edge.target_id, edge.weight * 1.0} | &1])
      |> Map.update!(edge.target_id, &[{edge.source_id, edge.weight * 1.0} | &1])
    end)
  end

  @spec episode([binary()], map(), keyword()) :: Episode.t()
  defp episode(member_ids, moments, opts) do
    namespace = Identity.namespace!(opts)
    scope = Keyword.get(opts, :scope)
    digest = stable_digest({namespace, scope, member_ids})
    members = Enum.map(member_ids, &Map.fetch!(moments, &1))
    {title, label_source} = cluster_label(members, member_ids, opts)

    %Episode{
      id: "episode_#{binary_part(digest, 0, 24)}",
      namespace: namespace,
      scope: scope,
      title: title,
      moment_ids: member_ids,
      summary: nil,
      metadata: %{
        namespace: namespace,
        scope: scope,
        algorithm: :weighted_label_propagation,
        deterministic?: label_source == :deterministic,
        label_source: label_source,
        size: length(member_ids)
      },
      inserted_at: latest_timestamp(members)
    }
  end

  @spec cluster_label([term()], [binary()], keyword()) :: {binary(), atom()}
  defp cluster_label(members, member_ids, opts) do
    default = cluster_title(members)

    input = %{default_title: default, member_ids: member_ids, members: members}

    opts
    |> label_adapter()
    |> label_result(input, opts, default)
  rescue
    _exception -> {cluster_title(members), :deterministic}
  catch
    _kind, _reason -> {cluster_title(members), :deterministic}
  end

  @spec label_result(term(), map(), keyword(), binary()) :: {binary(), atom()}
  defp label_result(nil, _input, _opts, default), do: {default, :deterministic}

  defp label_result(adapter, input, opts, default) do
    adapter
    |> call_label_adapter(input, opts)
    |> normalize_label(default)
  end

  @spec normalize_label(term(), binary()) :: {binary(), atom()}
  defp normalize_label({:ok, title}, default) when is_binary(title) do
    title = String.trim(title)
    if title == "", do: {default, :deterministic}, else: {title, :adapter}
  end

  defp normalize_label(_error, default), do: {default, :deterministic}

  @spec label_adapter(keyword()) :: term()
  defp label_adapter(opts) do
    Keyword.get(opts, :atlas_label_adapter) ||
      Application.get_env(:spectre_mnemonic, :atlas_label_adapter)
  end

  @spec call_label_adapter(term(), map(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp call_label_adapter(fun, input, opts) when is_function(fun, 2), do: fun.(input, opts)
  defp call_label_adapter(fun, input, _opts) when is_function(fun, 1), do: fun.(input)

  defp call_label_adapter(adapter, input, opts) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :label, 2),
      do: adapter.label(input, opts),
      else: {:error, {:invalid_atlas_label_adapter, adapter}}
  end

  defp call_label_adapter(adapter, _input, _opts),
    do: {:error, {:invalid_atlas_label_adapter, adapter}}

  @spec cluster_title([term()]) :: binary()
  defp cluster_title(moments) do
    entities =
      moments
      |> Enum.filter(&(&1.kind == :memory_entity))
      |> Enum.map(&Map.get(&1.metadata, :canonical))
      |> Enum.reject(&is_nil/1)

    keywords =
      moments
      |> Enum.flat_map(&Map.get(&1, :keywords, []))
      |> Enum.reject(&(String.length(to_string(&1)) < 3))

    labels = top_values(entities, 2) ++ top_values(keywords, 3)

    case Enum.uniq(labels) |> Enum.take(3) do
      [] -> "memory cluster"
      values -> Enum.join(values, " · ")
    end
  end

  @spec top_values([term()], pos_integer()) :: [binary()]
  defp top_values(values, limit) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, count} -> {-count, value} end)
    |> Enum.take(limit)
    |> Enum.map(fn {value, _count} -> value end)
  end

  @spec stats([term()], [Association.t()], [Episode.t()], keyword()) :: map()
  defp stats(nodes, edges, clusters, opts) do
    degrees =
      Enum.reduce(edges, %{}, fn edge, acc ->
        acc
        |> Map.update(edge.source_id, 1, &(&1 + 1))
        |> Map.update(edge.target_id, 1, &(&1 + 1))
      end)

    orphan_count = Enum.count(nodes, &(Map.get(degrees, &1.id, 0) == 0))

    histogram =
      nodes
      |> Enum.map(fn node -> Governance.state_for(node.id, opts) || :untracked end)
      |> Enum.frequencies()

    %{
      nodes: length(nodes),
      edges: length(edges),
      clusters: length(clusters),
      orphan_ratio: if(nodes == [], do: 0.0, else: orphan_count / length(nodes)),
      top_hubs:
        degrees
        |> Enum.sort_by(fn {id, degree} -> {-degree, id} end)
        |> Enum.take(10)
        |> Enum.map(fn {id, degree} -> %{id: id, degree: degree} end),
      contradictions: Enum.count(edges, &(&1.relation == :contradicts)),
      state_histogram: histogram
    }
  end

  @spec layout_hints([term()]) :: map()
  defp layout_hints(nodes) do
    Map.new(nodes, fn node ->
      <<x::unsigned-32, y::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, node.id)
      {node.id, %{x: x / 4_294_967_295, y: y / 4_294_967_295}}
    end)
  end

  @spec persist_clusters([Episode.t()], keyword()) :: :ok | {:error, term()}
  defp persist_clusters(clusters, opts) do
    Enum.reduce_while(clusters, :ok, fn episode, :ok ->
      with {:ok, _result} <- Manager.append(:episodes, episode, opts),
           :ok <- put_episode_membership(episode, opts) do
        Focus.put_episode(episode)
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec supersede_clusters([Episode.t()], [term()], keyword()) :: :ok | {:error, term()}
  defp supersede_clusters(clusters, nodes, opts) do
    current_ids = MapSet.new(Enum.map(clusters, & &1.id))
    affected_ids = MapSet.new(Enum.map(nodes, & &1.id))

    obsolete =
      opts
      |> Focus.episodes()
      |> Enum.filter(fn episode ->
        not MapSet.member?(current_ids, episode.id) and
          Enum.any?(episode.moment_ids, &MapSet.member?(affected_ids, &1))
      end)

    Enum.reduce_while(obsolete, :ok, fn episode, :ok ->
      case tombstone_episode(episode, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec tombstone_episode(Episode.t(), keyword()) :: :ok | {:error, term()}
  defp tombstone_episode(episode, opts) do
    with {:ok, records} <- Manager.replay(opts),
         targets <- episode_targets(episode, records),
         :ok <- append_episode_tombstones(targets, opts) do
      Focus.drop_episode(episode, opts)
    end
  end

  @spec episode_targets(Episode.t(), [term()]) :: [{atom(), binary()}]
  defp episode_targets(episode, records) do
    memberships =
      records
      |> Enum.flat_map(fn
        %{
          family: :associations,
          payload: %{id: id, relation: :member_of, target_id: target_id}
        }
        when target_id == episode.id ->
          [{:associations, id}]

        _record ->
          []
      end)

    [{:episodes, episode.id} | memberships]
  end

  @spec append_episode_tombstones([{atom(), binary()}], keyword()) :: :ok | {:error, term()}
  defp append_episode_tombstones(targets, opts) do
    now = DateTime.utc_now()

    Enum.reduce_while(targets, :ok, fn {family, id}, :ok ->
      payload = %{family: family, id: id, forgotten_at: now, reason: :episode_superseded}

      case Manager.append(:tombstones, payload, opts) do
        {:ok, _result} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec put_episode_membership(Episode.t(), keyword()) :: :ok | {:error, term()}
  defp put_episode_membership(episode, opts) do
    Enum.reduce_while(episode.moment_ids, :ok, fn moment_id, :ok ->
      association = membership_association(moment_id, episode, opts)

      case Manager.append(:associations, association, opts) do
        {:ok, _result} ->
          Focus.upsert_association(association)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec membership_association(binary(), Episode.t(), keyword()) :: Association.t()
  defp membership_association(moment_id, episode, opts) do
    digest = stable_digest({moment_id, episode.id, :member_of})

    %Association{
      id: "assoc_member_#{binary_part(digest, 0, 24)}",
      namespace: episode.namespace,
      scope: episode.scope,
      source_id: moment_id,
      relation: :member_of,
      target_id: episode.id,
      weight: 1.0,
      metadata: Identity.put_context(%{episode_id: episode.id, durable?: true}, opts),
      inserted_at: episode.inserted_at
    }
  end

  @spec cluster_edge?(Association.t(), MapSet.t(binary())) :: boolean()
  defp cluster_edge?(edge, node_ids) do
    edge.relation not in [:attached_action, :member_of, :same_as] and edge.weight > 0.03 and
      MapSet.member?(node_ids, edge.source_id) and MapSet.member?(node_ids, edge.target_id)
  end

  @spec latest_timestamp([term()]) :: DateTime.t()
  defp latest_timestamp(moments) do
    Enum.max_by(moments, &DateTime.to_unix(&1.inserted_at, :microsecond)).inserted_at
  end

  @spec stable_digest(term()) :: binary()
  defp stable_digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec positive_limit(keyword(), atom(), pos_integer()) :: pos_integer()
  defp positive_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end
end
