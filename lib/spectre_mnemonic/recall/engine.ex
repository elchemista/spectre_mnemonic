defmodule SpectreMnemonic.Recall.Engine do
  @moduledoc """
  Builds recall packets from active ETS memory.

  The search is intentionally brute-force in V1: keyword/entity overlap,
  optional vector cosine similarity, fingerprint hamming distance, and graph
  expansion through associations.

  Recall is an evidence-gathering layer, not an answer generator. It returns a
  packet containing ranked moments plus related observations, mental models,
  compact knowledge, artifacts, associations, and action recipes. A caller can
  then render that packet, pass it to a reflection adapter, or feed it to an LLM.

  Ranking happens in three passes:

    1. Score visible active moments by text, metadata, status, vector, and
       fingerprint signals.
    2. Expand through memory associations so nearby graph context can join the
       result set.
    3. Apply a token budget that keeps primary evidence first and dependent
       records second.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Atlas
  alias SpectreMnemonic.Engine.PartitionExecutor
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Knowledge
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Recall.Budget
  alias SpectreMnemonic.Recall.Candidates
  alias SpectreMnemonic.Recall.Diagnostics
  alias SpectreMnemonic.Recall.Features
  alias SpectreMnemonic.Recall.Fusion
  alias SpectreMnemonic.Recall.GraphExpansion
  alias SpectreMnemonic.Recall.Index
  alias SpectreMnemonic.Recall.Packet
  alias SpectreMnemonic.Recall.Ranker
  alias SpectreMnemonic.SearchResult
  alias SpectreMnemonic.Secrets

  @type recall_moment :: Moment.t() | Secret.t()

  @doc """
  Returns a neighborhood packet for a cue.

  Common options:

    * `:limit` - maximum primary memory candidates.
    * `:budget` - `:low`, `:mid`, or `:high` preset.
    * `:max_tokens` - best-effort packet budget. The first primary evidence
      item may exceed it so recall does not return an empty packet.
    * `:include_observations` - include derived observations.
    * `:include_mental_models` - include curated models.
    * `:include_knowledge` - include compact progressive knowledge.

  ## Example

      iex> SpectreMnemonic.Recall.Engine.recall("what blocks deploy?", limit: 5)
      {:ok, %SpectreMnemonic.Recall.Packet{}}
  """
  @spec recall(term(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  def recall(cue, opts \\ []) do
    with :ok <- validate_recall_options(opts),
         {:ok, context} <- QueryContext.ensure(cue, opts),
         :ok <- validate_recall_options(context.opts) do
      PartitionExecutor.trans(
        PartitionExecutor.key(context.opts),
        fn -> do_recall(context) end,
        context.opts
      )
    end
  rescue
    exception -> {:error, {:recall_failed, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:recall_failed, kind, reason}}
  end

  @spec do_recall(QueryContext.t()) :: {:ok, Packet.t()}
  defp do_recall(context) do
    # Recall gathers evidence. It does not write the answer, bless the answer,
    # or pretend the top hit is truth. Ranking is useful; certainty is expensive.
    opts = context.opts
    cue = context
    limit = Keyword.get(opts, :limit, 10)
    budget = Budget.profile(opts)
    {index_results, index_status} = source_values(Index.query(cue, opts))

    {durable_results, durable_sources} =
      case Manager.search_with_diagnostics(context, opts) do
        {:ok, results, diagnostics} -> {results, diagnostics}
        {:error, reason} -> {[], %{durable_index: {:error, reason}, primary_store: :unknown}}
      end

    index_scores = Map.new(index_results, &{&1.id, &1})

    seed_limit = max(limit, limit * budget.seed_multiplier)

    {base_ranked, candidate_meta} = ranked_moments(cue, index_scores, seed_limit, opts)
    traversal = GraphExpansion.expand(base_ranked, budget, opts)
    graph_ranked = traversal.moments

    # The dedicated embedding index can find candidates that text scoring misses.
    # Reciprocal-rank fusion lets those candidates compete without requiring all
    # scoring systems to share the same numeric scale.
    index_ranked =
      index_results
      |> Enum.map(& &1.id)
      |> Focus.moments_by_ids(opts)

    ranked_candidates =
      [base_ranked, graph_ranked, index_ranked]
      |> Fusion.rrf()
      |> Ranker.rerank_fused(cue, index_scores)
      |> Ranker.filter_visible(opts)

    observation_candidates = recall_observations(context, durable_results, opts)
    mental_model_candidates = recall_mental_models(context, durable_results, opts)
    knowledge_candidates = compact_knowledge(opts)

    # Budgeting is split in two passes: first reserve room for primary evidence,
    # then spend the remaining room on records that only make sense with that
    # evidence, such as associations and action recipes.
    {components, used_tokens} =
      Budget.apply_primary(
        ranked_candidates,
        observation_candidates,
        mental_model_candidates,
        opts,
        limit
      )

    associations =
      components.moments
      |> Enum.map(& &1.id)
      |> Focus.associations_for_ids(opts)

    {components, _used_tokens} =
      Budget.apply_dependent(
        components,
        GraphExpansion.artifacts(components.moments, associations, opts),
        associations,
        GraphExpansion.action_recipes(components.moments, associations, opts),
        knowledge_candidates,
        opts,
        used_tokens
      )

    revealed = Enum.map(components.moments, &Secrets.maybe_reveal(&1, opts))

    episodes = recall_episodes(revealed, opts)
    trace = recall_trace(traversal.paths, revealed, episodes, opts)

    diagnostics =
      Diagnostics.build(
        cue,
        candidate_meta,
        index_status,
        durable_sources,
        index_results,
        durable_results,
        graph_ranked,
        components.moments
      )

    with :ok <- Diagnostics.enforce_consistency(diagnostics, opts) do
      packet = %Packet{
        cue: cue,
        query_context: context,
        search_results: durable_results,
        active_status: active_status(components.moments, opts),
        moments: revealed,
        observations: components.observations,
        mental_models: components.mental_models,
        episodes: episodes,
        knowledge: components.knowledge,
        artifacts: components.artifacts,
        associations: components.associations,
        action_recipes: components.action_recipes,
        trace: trace,
        confidence: Features.confidence(components.moments, cue, index_scores),
        diagnostics: diagnostics,
        usage:
          Budget.usage(
            revealed,
            components.observations,
            components.mental_models,
            components.knowledge,
            components.artifacts,
            components.associations,
            components.action_recipes,
            opts
          )
      }

      maybe_reinforce(traversal.paths, components.moments, opts)

      {:ok, packet}
    end
  end

  @spec ranked_moments(QueryContext.t(), map(), integer(), keyword()) ::
          {[recall_moment()], map()}
  defp ranked_moments(_cue, _index_scores, limit, _opts) when limit <= 0,
    do: {[], Candidates.empty_meta()}

  defp ranked_moments(cue, index_scores, limit, opts) do
    {candidates, candidate_meta} = Candidates.collect(cue, Map.keys(index_scores), opts)
    {Ranker.rank(candidates, cue, index_scores, limit, opts), candidate_meta}
  end

  @spec active_status([recall_moment()], keyword()) :: [map()]
  defp active_status(moments, opts) do
    moments
    |> Enum.flat_map(&statuses_for_moment(&1, opts))
    |> Enum.uniq_by(fn status ->
      {status.namespace, status.scope, status.stream, status.task_id}
    end)
  end

  @spec statuses_for_moment(recall_moment(), keyword()) :: [map()]
  defp statuses_for_moment(moment, opts) do
    status_opts = Keyword.put(opts, :scope, Scope.scope(moment))

    [moment.stream, moment.task_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&status_for_key(&1, status_opts))
  end

  @spec status_for_key(term(), keyword()) :: [map()]
  defp status_for_key(key, opts) do
    case Focus.status(key, opts) do
      {:ok, status} -> [status]
      {:error, _reason} -> []
    end
  end

  @spec recall_trace(map(), [recall_moment()], [term()], keyword()) :: map() | nil
  defp recall_trace(paths, moments, episodes, opts) do
    if Keyword.get(opts, :trace, false) do
      moments
      |> Map.new(fn moment ->
        path = Map.get(paths, moment.id)
        clusters = clusters_for(moment.id, episodes)
        {moment.id, if(is_nil(path), do: nil, else: Map.put(path, :clusters, clusters))}
      end)
      |> Enum.reject(fn {_id, path} -> is_nil(path) end)
      |> Map.new()
    end
  end

  @spec recall_episodes([recall_moment()], keyword()) :: [term()]
  defp recall_episodes([], _opts), do: []

  defp recall_episodes(moments, opts) do
    ids = MapSet.new(Enum.map(moments, & &1.id))
    materialized = Focus.episodes(opts) |> Enum.filter(&episode_intersects?(&1, ids))

    if materialized == [] and Keyword.get(opts, :trace, false) do
      case Atlas.build(opts) do
        {:ok, atlas} -> Enum.filter(atlas.clusters, &episode_intersects?(&1, ids))
        {:error, _reason} -> []
      end
    else
      materialized
    end
  end

  @spec episode_intersects?(term(), MapSet.t(binary())) :: boolean()
  defp episode_intersects?(episode, ids),
    do: Enum.any?(episode.moment_ids, &MapSet.member?(ids, &1))

  @spec clusters_for(binary(), [term()]) :: [map()]
  defp clusters_for(moment_id, episodes) do
    episodes
    |> Enum.filter(&(moment_id in &1.moment_ids))
    |> Enum.map(&%{id: &1.id, title: &1.title})
    |> Enum.sort_by(& &1.id)
  end

  @spec maybe_reinforce(map(), [recall_moment()], keyword()) :: :ok
  defp maybe_reinforce(paths, moments, opts) do
    _result = Focus.reinforce_attention(Enum.map(moments, & &1.id), opts)

    if Keyword.get(opts, :plasticity?, true) do
      selected = Map.take(paths, Enum.map(moments, & &1.id))
      _result = Plasticity.reinforce(selected, opts)
    end

    :ok
  end

  @spec recall_observations(QueryContext.t(), [SearchResult.t()], keyword()) :: [term()]
  defp recall_observations(context, durable_results, opts) do
    if Keyword.get(opts, :include_observations, true) do
      opts =
        opts
        |> Keyword.put(:limit, Keyword.get(opts, :observation_limit, 5))
        |> Keyword.put(:durable_results, durable_results)

      context.text
      |> SpectreMnemonic.search_observations(opts)
      |> result_values()
    else
      []
    end
  end

  @spec recall_mental_models(QueryContext.t(), [SearchResult.t()], keyword()) :: [term()]
  defp recall_mental_models(context, durable_results, opts) do
    if Keyword.get(opts, :include_mental_models, true) do
      opts =
        opts
        |> Keyword.put(:limit, Keyword.get(opts, :mental_model_limit, 5))
        |> Keyword.put(:durable_results, durable_results)

      context.text
      |> SpectreMnemonic.search_mental_models(opts)
      |> result_values()
    else
      []
    end
  end

  @spec compact_knowledge(keyword()) :: [Knowledge.Record.t()]
  defp compact_knowledge(opts) do
    include? =
      opts
      |> Keyword.get(:include_knowledge, true)

    if include? do
      case Knowledge.Base.load(opts) do
        {:ok, %{summary: nil, skills: [], latest_ingestions: [], facts: [], procedures: []}} -> []
        {:ok, knowledge} -> [knowledge]
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @spec validate_recall_options(term()) :: :ok | {:error, term()}
  defp validate_recall_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      validators = [
        {:limit, &non_negative_integer?/1},
        {:observation_limit, &non_negative_integer?/1},
        {:mental_model_limit, &non_negative_integer?/1},
        {:max_tokens, &positive_integer?/1},
        {:include_observations, &is_boolean/1},
        {:include_mental_models, &is_boolean/1},
        {:include_knowledge, &is_boolean/1},
        {:trace, &is_boolean/1},
        {:plasticity?, &is_boolean/1},
        {:overfetch, &non_negative_integer?/1},
        {:graph_depth, &non_negative_integer?/1},
        {:max_graph_nodes, &non_negative_integer?/1},
        {:hop_decay, &bounded_ratio?/1},
        {:activation_floor, &bounded_ratio?/1},
        {:prune_threshold, &bounded_ratio?/1},
        {:relations, &valid_relations?/1},
        {:relation_types, &valid_relations?/1},
        {:exclude_relations, &valid_relation_list?/1},
        {:min_vector_similarity, &bounded_ratio?/1},
        {:budget, &(&1 in [:low, :mid, :high])},
        {:consistency, &(&1 in [:available, :strict])},
        {:required_sources, &valid_source_list?/1}
      ]

      Enum.reduce_while(validators, :ok, &validate_recall_option(&1, &2, opts))
    else
      {:error, {:invalid_recall_options, opts}}
    end
  end

  defp validate_recall_options(opts), do: {:error, {:invalid_recall_options, opts}}

  @spec validate_recall_option(
          {atom(), (term() -> boolean())},
          :ok,
          keyword()
        ) :: {:cont, :ok} | {:halt, {:error, term()}}
  defp validate_recall_option({key, valid?}, :ok, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> validate_recall_option_value(key, value, valid?)
      :error -> {:cont, :ok}
    end
  end

  @spec validate_recall_option_value(atom(), term(), (term() -> boolean())) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp validate_recall_option_value(key, value, valid?) do
    if valid?.(value),
      do: {:cont, :ok},
      else: {:halt, {:error, {:invalid_recall_option, key, value}}}
  end

  @spec non_negative_integer?(term()) :: boolean()
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  @spec positive_integer?(term()) :: boolean()
  defp positive_integer?(value), do: is_integer(value) and value > 0

  @spec bounded_ratio?(term()) :: boolean()
  defp bounded_ratio?(value), do: is_number(value) and value >= 0 and value <= 1

  @spec valid_relations?(term()) :: boolean()
  defp valid_relations?(:all), do: true
  defp valid_relations?(relations), do: valid_relation_list?(relations)

  @spec valid_relation_list?(term()) :: boolean()
  defp valid_relation_list?(relations) when is_list(relations),
    do: Enum.all?(relations, &is_atom/1)

  defp valid_relation_list?(_relations), do: false

  @spec valid_source_list?(term()) :: boolean()
  defp valid_source_list?(sources) when is_list(sources), do: Enum.all?(sources, &is_atom/1)
  defp valid_source_list?(_sources), do: false

  @spec source_values(term()) :: {[term()], :ok | {:error, term()}}
  defp source_values({:ok, values}) when is_list(values), do: {values, :ok}
  defp source_values({:error, reason}), do: {[], {:error, reason}}

  @spec result_values(term()) :: [term()]
  defp result_values(result), do: result |> source_values() |> elem(0)
end
