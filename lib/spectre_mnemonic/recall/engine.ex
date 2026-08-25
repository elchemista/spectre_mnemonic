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
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Graph.Traversal
  alias SpectreMnemonic.Knowledge
  alias SpectreMnemonic.Memory.ActionRecipe
  alias SpectreMnemonic.Memory.Artifact
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Recall.Fingerprint
  alias SpectreMnemonic.Recall.Fusion
  alias SpectreMnemonic.Recall.Index
  alias SpectreMnemonic.Recall.Packet
  alias SpectreMnemonic.SearchResult
  alias SpectreMnemonic.Secrets

  @hamming_threshold 0.72
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
      do_recall(context)
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
    budget = budget(opts)
    index_results = result_values(Index.query(cue, opts))
    durable_results = result_values(Manager.search(context, opts))
    index_scores = Map.new(index_results, &{&1.id, &1})

    seed_limit = max(limit, limit * budget.seed_multiplier)

    base_ranked = ranked_moments(cue, index_scores, seed_limit, opts)
    traversal = expand_graph(base_ranked, budget, opts)
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
      |> rerank_moments(cue, index_scores)
      |> filter_moments(opts)

    observation_candidates = recall_observations(context, durable_results, opts)
    mental_model_candidates = recall_mental_models(context, durable_results, opts)
    knowledge_candidates = compact_knowledge(opts)

    # Budgeting is split in two passes: first reserve room for primary evidence,
    # then spend the remaining room on records that only make sense with that
    # evidence, such as associations and action recipes.
    {components, used_tokens} =
      apply_primary_budget(
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
      apply_dependent_budget(
        components,
        artifacts_for(components.moments, associations, opts),
        associations,
        action_recipes_for(components.moments, associations, opts),
        knowledge_candidates,
        opts,
        used_tokens
      )

    revealed = Enum.map(components.moments, &Secrets.maybe_reveal(&1, opts))

    episodes = recall_episodes(revealed, opts)
    trace = recall_trace(traversal.paths, revealed, episodes, opts)

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
      confidence: confidence(components.moments, cue, index_scores),
      usage:
        usage(
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

  @spec ranked_moments(QueryContext.t(), map(), integer(), keyword()) :: [recall_moment()]
  defp ranked_moments(_cue, _index_scores, limit, _opts) when limit <= 0, do: []

  defp ranked_moments(cue, index_scores, limit, opts) do
    Focus.fold_moments(
      [],
      fn moment, ranked ->
        maybe_insert_ranked_moment(moment, ranked, cue, index_scores, limit, opts)
      end,
      opts
    )
    |> Enum.sort_by(&rank_key/1)
    |> Enum.map(fn {_score, moment} -> moment end)
  end

  @spec maybe_insert_ranked_moment(
          recall_moment(),
          [{number(), recall_moment()}],
          QueryContext.t(),
          map(),
          pos_integer(),
          keyword()
        ) :: [{number(), recall_moment()}]
  defp maybe_insert_ranked_moment(moment, ranked, cue, index_scores, limit, opts) do
    score = if memory_visible?(moment, opts), do: score(moment, cue, index_scores, opts), else: 0

    if score > 0 do
      insert_ranked({score, moment}, ranked, limit)
    else
      ranked
    end
  end

  @spec insert_ranked({number(), recall_moment()}, [{number(), recall_moment()}], pos_integer()) ::
          [{number(), recall_moment()}]
  defp insert_ranked(candidate, ranked, limit) do
    [candidate | ranked]
    |> Enum.sort_by(&rank_key/1)
    |> Enum.take(limit)
  end

  @spec rank_key({number(), recall_moment()}) :: {number(), integer()}
  defp rank_key({score, moment}),
    do: {-score, -DateTime.to_unix(moment.inserted_at, :microsecond)}

  @spec score(recall_moment(), QueryContext.t(), map(), keyword()) :: number()
  defp score(moment, cue, index_scores, opts) do
    keyword_score = overlap(moment.keywords, cue.keywords) * 2
    entity_score = overlap(moment.entities, cue.entities) * 3
    semantic_score = semantic_score(moment, cue, index_scores, opts)
    status_bonus = if status_match?(moment, cue), do: 2, else: 0

    match_score = keyword_score + entity_score + semantic_score + status_bonus

    if match_score > 0, do: match_score + moment.attention, else: 0
  end

  @spec rerank_moments([{float(), recall_moment()}], QueryContext.t(), map()) ::
          [recall_moment()]
  defp rerank_moments(fused, cue, index_scores) do
    fused
    |> Enum.uniq_by(fn {_rrf_score, moment} -> moment.id end)
    |> Enum.map(fn {rrf_score, moment} ->
      feature_score =
        max(score(moment, cue, index_scores, cue.opts), structured_score(moment, cue))

      normalized_feature = normalize_feature_score(feature_score)
      normalized_rrf = min(1.0, rrf_score * 20.0)
      {normalized_rrf * 0.55 + normalized_feature * 0.45, moment}
    end)
    |> Enum.sort_by(&rank_key/1)
    |> Enum.map(fn {_score, moment} -> moment end)
  end

  @spec normalize_feature_score(number()) :: float()
  defp normalize_feature_score(score) when score > 0, do: score / (score + 4.0)
  defp normalize_feature_score(_score), do: 0.0

  @spec structured_score(recall_moment(), QueryContext.t()) :: number()
  defp structured_score(%{kind: :memory_entity, metadata: metadata} = moment, cue) do
    canonical = Map.get(metadata, :canonical)
    aliases = Map.get(metadata, :aliases, [])
    cue_text = String.downcase(cue.text)

    cond do
      canonical && String.contains?(cue_text, to_string(canonical)) ->
        7 + moment.attention

      Enum.any?(aliases, &String.contains?(cue_text, String.downcase(to_string(&1)))) ->
        6 + moment.attention

      true ->
        0
    end
  end

  defp structured_score(%{kind: :memory_event} = moment, cue) do
    cond do
      asks_when?(cue) and overlap(moment.keywords, cue.keywords) > 0 -> 5 + moment.attention
      asks_action?(cue) and overlap(moment.keywords, cue.keywords) > 0 -> 5 + moment.attention
      true -> 0
    end
  end

  defp structured_score(%{kind: :memory_time} = moment, cue) do
    if asks_when?(cue), do: 3 + moment.attention, else: 0
  end

  defp structured_score(%{kind: :memory_value} = moment, cue) do
    if asks_value?(cue), do: 3 + moment.attention, else: 0
  end

  defp structured_score(_moment, _cue), do: 0

  @spec expand_graph([recall_moment()], map(), keyword()) :: Traversal.result()
  defp expand_graph(moments, budget, opts) do
    traversal_opts =
      opts
      |> Keyword.put_new(:graph_depth, budget.graph_depth)
      |> Keyword.put_new(:hop_decay, budget.hop_decay)
      |> Keyword.put_new(:activation_floor, budget.activation_floor)
      |> Keyword.put_new(:max_graph_nodes, budget.max_graph_nodes)

    Traversal.expand(moments, traversal_opts)
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

  @spec artifacts_for([recall_moment()], [Association.t()], keyword()) :: [Artifact.t()]
  defp artifacts_for(moments, associations, opts) do
    ids = MapSet.new(Enum.map(moments, & &1.id))

    associations
    |> Enum.flat_map(fn assoc ->
      cond do
        MapSet.member?(ids, assoc.source_id) -> [assoc.target_id]
        MapSet.member?(ids, assoc.target_id) -> [assoc.source_id]
        true -> []
      end
    end)
    |> Focus.artifacts(opts)
  end

  @spec action_recipes_for([recall_moment()], [Association.t()], keyword()) ::
          [ActionRecipe.t()]
  defp action_recipes_for(moments, associations, opts) do
    moment_ids = MapSet.new(Enum.map(moments, & &1.id))
    related_ids = related_memory_ids(moment_ids, associations)

    related_ids
    |> Focus.associations_for_ids(opts)
    |> Enum.flat_map(fn assoc ->
      if MapSet.member?(related_ids, assoc.source_id) and assoc.relation == :attached_action do
        [assoc.target_id]
      else
        []
      end
    end)
    |> Focus.action_recipes(opts)
  end

  @spec related_memory_ids(MapSet.t(), [Association.t()]) :: MapSet.t()
  defp related_memory_ids(moment_ids, associations) do
    associations
    |> Enum.reduce(moment_ids, fn assoc, acc ->
      cond do
        MapSet.member?(moment_ids, assoc.source_id) -> MapSet.put(acc, assoc.target_id)
        MapSet.member?(moment_ids, assoc.target_id) -> MapSet.put(acc, assoc.source_id)
        true -> acc
      end
    end)
  end

  @spec filter_moments([recall_moment()], keyword()) :: [recall_moment()]
  defp filter_moments(moments, opts) do
    Enum.filter(moments, &memory_visible?(&1, opts))
  end

  @spec memory_visible?(recall_moment(), keyword()) :: boolean()
  defp memory_visible?(moment, opts) do
    state_opts = Keyword.put(opts, :scope, Scope.scope(moment))

    Scope.match?(moment, opts) and Temporal.match?(moment, opts) and
      Governance.search_visible?(moment.id, state_opts)
  end

  @spec budget(keyword()) :: map()
  defp budget(opts) do
    case Keyword.get(opts, :budget, :mid) do
      :low ->
        %{
          seed_multiplier: 1,
          graph_depth: 1,
          hop_decay: 0.62,
          activation_floor: 0.14,
          max_graph_nodes: 60
        }

      :high ->
        %{
          seed_multiplier: 4,
          graph_depth: 3,
          hop_decay: 0.78,
          activation_floor: 0.045,
          max_graph_nodes: 400
        }

      _mid ->
        %{
          seed_multiplier: 2,
          graph_depth: 2,
          hop_decay: 0.72,
          activation_floor: 0.08,
          max_graph_nodes: 200
        }
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

  @spec apply_primary_budget(
          [recall_moment()],
          [term()],
          [term()],
          keyword(),
          non_neg_integer()
        ) ::
          {map(), non_neg_integer() | nil}
  defp apply_primary_budget(moments, observations, mental_models, opts, limit) do
    # Budgeting starts with primary evidence. Dependent records come later,
    # because citations without the thing they cite are just decorative confetti.
    case max_tokens(opts) do
      nil ->
        {%{
           moments: Enum.take(moments, limit),
           observations: observations,
           mental_models: mental_models,
           knowledge: [],
           artifacts: [],
           associations: [],
           action_recipes: []
         }, nil}

      max_tokens ->
        groups = [
          {:mental_models, mental_models},
          {:observations, observations},
          {:moments, Enum.take(moments, limit)}
        ]

        {selected, used} = select_budgeted_groups(groups, max_tokens, 0)

        {Map.merge(
           %{
             moments: [],
             observations: [],
             mental_models: [],
             knowledge: [],
             artifacts: [],
             associations: [],
             action_recipes: []
           },
           selected
         ), used}
    end
  end

  @spec apply_dependent_budget(
          map(),
          [Artifact.t()],
          [Association.t()],
          [ActionRecipe.t()],
          [Knowledge.Record.t()],
          keyword(),
          non_neg_integer() | nil
        ) ::
          {map(), non_neg_integer() | nil}
  defp apply_dependent_budget(
         components,
         artifacts,
         associations,
         action_recipes,
         knowledge,
         _opts,
         nil
       ) do
    {%{
       components
       | artifacts: artifacts,
         associations: associations,
         action_recipes: action_recipes,
         knowledge: knowledge
     }, nil}
  end

  defp apply_dependent_budget(
         components,
         artifacts,
         associations,
         action_recipes,
         knowledge,
         opts,
         used
       ) do
    max_tokens = max_tokens(opts)

    groups = [
      {:associations, associations},
      {:artifacts, artifacts},
      {:action_recipes, action_recipes},
      {:knowledge, knowledge}
    ]

    {selected, used} = select_budgeted_groups(groups, max_tokens, used)
    {Map.merge(components, selected), used}
  end

  @spec select_budgeted_groups([{atom(), [term()]}], pos_integer(), non_neg_integer()) ::
          {map(), non_neg_integer()}
  defp select_budgeted_groups(groups, max_tokens, used) do
    Enum.reduce(groups, {%{}, used}, fn {key, items}, {selected, current_used} ->
      {selected_items, current_used} = select_budgeted_items(items, max_tokens, current_used)
      {Map.put(selected, key, selected_items), current_used}
    end)
  end

  @spec select_budgeted_items([term()], pos_integer(), non_neg_integer()) ::
          {[term()], non_neg_integer()}
  defp select_budgeted_items(items, max_tokens, used) do
    items
    |> Enum.reduce_while({[], used}, fn item, {selected, current_used} ->
      cost = estimate_tokens(memory_text(item))

      cond do
        selected == [] and current_used == 0 and cost > max_tokens ->
          {:halt, {[item], current_used + cost}}

        current_used + cost <= max_tokens ->
          {:cont, {[item | selected], current_used + cost}}

        true ->
          {:halt, {selected, current_used}}
      end
    end)
    |> then(fn {selected, current_used} -> {Enum.reverse(selected), current_used} end)
  end

  @spec max_tokens(keyword()) :: pos_integer() | nil
  defp max_tokens(opts) do
    case Keyword.get(opts, :max_tokens) do
      max_tokens when is_integer(max_tokens) and max_tokens > 0 -> max_tokens
      _missing -> nil
    end
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

  @spec usage([term()], [term()], [term()], [term()], [term()], [term()], [term()], keyword()) ::
          map()
  defp usage(
         moments,
         observations,
         mental_models,
         knowledge,
         artifacts,
         associations,
         action_recipes,
         opts
       ) do
    estimated =
      (mental_models ++
         observations ++
         moments ++
         knowledge ++
         artifacts ++
         associations ++
         action_recipes)
      |> Enum.map(&estimate_tokens(memory_text(&1)))
      |> Enum.sum()

    %{
      estimated_tokens: estimated,
      max_tokens: Keyword.get(opts, :max_tokens),
      budget: Keyword.get(opts, :budget, :mid)
    }
  end

  @spec memory_text(term()) :: binary()
  defp memory_text(%{text: text}) when is_binary(text), do: text
  defp memory_text(%{statement: statement}) when is_binary(statement), do: statement
  defp memory_text(%{answer: answer}) when is_binary(answer), do: answer
  defp memory_text(%{source: source}) when is_binary(source), do: source

  defp memory_text(%{relation: relation, source_id: source_id, target_id: target_id}) do
    "#{source_id} #{relation} #{target_id}"
  end

  defp memory_text(_memory), do: ""

  @spec estimate_tokens(binary()) :: non_neg_integer()
  defp estimate_tokens(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> length()
    |> Kernel.*(4)
    |> div(3)
    |> max(1)
  end

  @spec confidence([recall_moment()], QueryContext.t(), map()) :: float()
  defp confidence([], _cue, _index_scores), do: 0.0

  defp confidence(moments, cue, index_scores) do
    moments
    |> Enum.take(3)
    |> Enum.map(fn moment ->
      moment
      |> score(cue, index_scores, cue.opts)
      |> max(structured_score(moment, cue))
      |> normalize_feature_score()
    end)
    |> then(&(Enum.sum(&1) / length(&1)))
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

  @spec status_match?(recall_moment(), QueryContext.t()) :: boolean()
  defp status_match?(moment, cue) do
    cue_text = String.downcase(cue.text)

    String.contains?(cue_text, "how") and String.contains?(cue_text, "going") and
      not is_nil(moment.task_id)
  end

  @spec asks_when?(QueryContext.t()) :: boolean()
  defp asks_when?(cue) do
    question_contains?(cue, ~w(when quando cuándo quand wann))
  end

  @spec asks_action?(QueryContext.t()) :: boolean()
  defp asks_action?(cue) do
    question_contains?(cue, ["what", "did", "do", "cosa", "che", "quoi", "que", "qué"])
  end

  @spec asks_value?(QueryContext.t()) :: boolean()
  defp asks_value?(cue) do
    question_contains?(cue, [
      "number",
      "phone",
      "telephone",
      "mobile",
      "age",
      "numero",
      "número",
      "telefono",
      "teléfono",
      "età",
      "eta",
      "edad",
      "âge"
    ])
  end

  @spec question_contains?(QueryContext.t(), [binary()]) :: boolean()
  defp question_contains?(cue, words) do
    cue_words =
      cue.text
      |> String.downcase()
      |> then(&Regex.scan(~r/[\p{L}\p{N}_]+/u, &1))
      |> List.flatten()
      |> MapSet.new()

    Enum.any?(words, &MapSet.member?(cue_words, &1))
  end

  @spec overlap([term()], [term()]) :: non_neg_integer()
  defp overlap(left, right) do
    left = MapSet.new(left)
    right = MapSet.new(right)
    MapSet.size(MapSet.intersection(left, right))
  end

  @spec semantic_score(Moment.t() | map(), QueryContext.t() | map(), map(), keyword()) :: number()
  defp semantic_score(
         %{id: id, vector: left, binary_signature: signature},
         cue,
         index_scores,
         opts
       )
       when is_binary(left) and is_binary(cue.vector) do
    minimum = Keyword.get(opts, :min_vector_similarity, 0.15) * 1.0

    case Map.fetch(index_scores, id) do
      {:ok, result} when result.cosine >= minimum ->
        result.score

      {:ok, _below_threshold} ->
        0.0

      :error ->
        cosine = max(0.0, Vector.cosine(left, cue.vector))

        if cosine >= minimum do
          signature_bits = signature_bits(cue.embedding, signature, cue.binary_signature)
          hamming = Vector.hamming_similarity(signature, cue.binary_signature, signature_bits)
          cosine * 4 + hamming * 4
        else
          0.0
        end
    end
  end

  defp semantic_score(moment, cue, _index_scores, _opts) do
    similarity =
      Fingerprint.hamming_similarity(moment.fingerprint, cue.fingerprint)

    if similarity >= @hamming_threshold do
      similarity * 4
    else
      0.0
    end
  end

  @spec signature_bits(map(), binary() | nil, binary() | nil) :: non_neg_integer()
  defp signature_bits(%{metadata: %{signature_bits: bits}}, _left, _right) when is_integer(bits),
    do: bits

  defp signature_bits(_embedding, left, right),
    do: min(byte_size(left || <<>>) * 8, byte_size(right || <<>>) * 8)

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
        {:budget, &(&1 in [:low, :mid, :high])}
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

  @spec result_values(term()) :: [term()]
  defp result_values({:ok, values}) when is_list(values), do: values
  defp result_values(_result), do: []
end
