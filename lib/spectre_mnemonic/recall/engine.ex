defmodule SpectreMnemonic.Recall.Engine do
  @moduledoc """
  Builds recall packets from active ETS memory.

  The search is intentionally brute-force in V1: keyword/entity overlap,
  optional vector cosine similarity, fingerprint hamming distance, and graph
  expansion through associations.
  """

  use GenServer

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Knowledge
  alias SpectreMnemonic.Memory.ActionRecipe
  alias SpectreMnemonic.Memory.Artifact
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Recall.Cue
  alias SpectreMnemonic.Recall.Fingerprint
  alias SpectreMnemonic.Recall.Fusion
  alias SpectreMnemonic.Recall.Index
  alias SpectreMnemonic.Recall.Packet
  alias SpectreMnemonic.Secrets

  @hamming_threshold 0.62
  @type recall_moment :: Moment.t() | Secret.t()

  @doc "Starts the recall process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Returns a neighborhood packet for a cue."
  @spec recall(term(), keyword()) :: {:ok, Packet.t()}
  def recall(cue, opts \\ []) do
    GenServer.call(__MODULE__, {:recall, cue, opts})
  end

  @impl GenServer
  @spec init(map()) :: {:ok, map()}
  def init(state), do: {:ok, state}

  @impl GenServer
  @spec handle_call({:recall, term(), keyword()}, GenServer.from(), map()) ::
          {:reply, {:ok, Packet.t()}, map()}
  def handle_call({:recall, cue_input, opts}, _from, state) do
    cue = build_cue(cue_input, opts)
    limit = Keyword.get(opts, :limit, 10)
    budget = budget(opts)
    {:ok, index_results} = Index.query(cue, opts)
    index_scores = Map.new(index_results, &{&1.id, &1})

    seed_limit = max(limit, limit * budget.seed_multiplier)

    base_ranked = ranked_moments(cue, index_scores, seed_limit, opts)
    graph_ranked = expand_graph(base_ranked, budget.graph_depth, opts)

    index_ranked =
      index_results |> Enum.map(& &1.id) |> Focus.moments_by_ids() |> filter_moments(opts)

    ranked_candidates =
      [base_ranked, graph_ranked, index_ranked]
      |> Fusion.rrf()
      |> Enum.map(fn {_score, moment} -> moment end)
      |> Enum.uniq_by(& &1.id)
      |> rerank_moments(cue, index_scores)
      |> filter_moments(opts)

    observation_candidates = recall_observations(cue_input, opts)
    mental_model_candidates = recall_mental_models(cue_input, opts)
    knowledge_candidates = compact_knowledge(opts)

    {components, used_tokens} =
      apply_primary_budget(
        ranked_candidates,
        observation_candidates,
        mental_model_candidates,
        opts,
        limit
      )

    associations = components.moments |> Enum.map(& &1.id) |> Focus.associations_for_ids()

    {components, _used_tokens} =
      apply_dependent_budget(
        components,
        artifacts_for(components.moments, associations),
        associations,
        action_recipes_for(components.moments, associations),
        knowledge_candidates,
        opts,
        used_tokens
      )

    revealed = Enum.map(components.moments, &Secrets.maybe_reveal(&1, opts))

    packet = %Packet{
      cue: cue,
      active_status: active_status(components.moments),
      moments: revealed,
      observations: components.observations,
      mental_models: components.mental_models,
      knowledge: components.knowledge,
      artifacts: components.artifacts,
      associations: components.associations,
      action_recipes: components.action_recipes,
      confidence: confidence(components.moments),
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

    {:reply, {:ok, packet}, state}
  end

  @spec ranked_moments(Cue.t(), map(), integer(), keyword()) :: [recall_moment()]
  defp ranked_moments(_cue, _index_scores, limit, _opts) when limit <= 0, do: []

  defp ranked_moments(cue, index_scores, limit, opts) do
    []
    |> Focus.fold_moments(fn moment, ranked ->
      maybe_insert_ranked_moment(moment, ranked, cue, index_scores, limit, opts)
    end)
    |> Enum.sort_by(&rank_key/1)
    |> Enum.map(fn {_score, moment} -> moment end)
  end

  @spec maybe_insert_ranked_moment(
          recall_moment(),
          [{number(), recall_moment()}],
          Cue.t(),
          map(),
          pos_integer(),
          keyword()
        ) :: [{number(), recall_moment()}]
  defp maybe_insert_ranked_moment(moment, ranked, cue, index_scores, limit, opts) do
    score = if memory_visible?(moment, opts), do: score(moment, cue, index_scores), else: 0

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
  defp rank_key({score, moment}), do: {-score, DateTime.to_unix(moment.inserted_at, :microsecond)}

  @spec build_cue(term(), keyword()) :: Cue.t()
  defp build_cue(input, opts) do
    text = if is_binary(input), do: input, else: inspect(input)
    embedding = Service.embed(input, opts)

    %Cue{
      input: input,
      text: text,
      keywords: keywords(text),
      entities: entities(text),
      vector: embedding.vector,
      binary_signature: Map.get(embedding, :binary_signature),
      embedding: embedding,
      fingerprint: Fingerprint.build(text),
      opts: opts
    }
  end

  @spec score(recall_moment(), Cue.t(), map()) :: number()
  defp score(moment, cue, index_scores) do
    keyword_score = overlap(moment.keywords, cue.keywords) * 2
    entity_score = overlap(moment.entities, cue.entities) * 3
    semantic_score = semantic_score(moment, cue, index_scores)
    status_bonus = if status_match?(moment, cue), do: 2, else: 0

    match_score = keyword_score + entity_score + semantic_score + status_bonus

    if match_score > 0, do: match_score + moment.attention, else: 0
  end

  @spec rerank_moments([recall_moment()], Cue.t(), map()) :: [recall_moment()]
  defp rerank_moments(moments, cue, index_scores) do
    moments
    |> Enum.map(fn moment ->
      base_score = score(moment, cue, index_scores)
      {max(base_score, structured_score(moment, cue)), moment}
    end)
    |> Enum.sort_by(&rank_key/1)
    |> Enum.map(fn {_score, moment} -> moment end)
  end

  @spec structured_score(recall_moment(), Cue.t()) :: number()
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

  @spec expand_graph([recall_moment()], non_neg_integer(), keyword()) :: [recall_moment()]
  defp expand_graph(moments, depth, opts), do: expand_graph(moments, depth, opts, MapSet.new())

  @spec expand_graph([recall_moment()], non_neg_integer(), keyword(), MapSet.t()) ::
          [recall_moment()]
  defp expand_graph(moments, 0, _opts, _seen), do: moments

  defp expand_graph(moments, depth, opts, _seen) do
    ids = MapSet.new(Enum.map(moments, & &1.id))
    associations = Focus.associations_for_ids(ids)

    linked_ids =
      associations
      |> Enum.flat_map(fn assoc ->
        cond do
          MapSet.member?(ids, assoc.source_id) -> [assoc.target_id]
          MapSet.member?(ids, assoc.target_id) -> [assoc.source_id]
          true -> []
        end
      end)
      |> MapSet.new()

    next =
      linked_ids
      |> Enum.reject(&MapSet.member?(ids, &1))
      |> Focus.moments_by_ids()
      |> filter_moments(opts)

    if next == [] do
      moments
    else
      expand_graph(moments ++ next, depth - 1, opts, ids)
    end
  end

  @spec active_status([recall_moment()]) :: [map()]
  defp active_status(moments) do
    moments
    |> Enum.flat_map(&[&1.stream, &1.task_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn key ->
      case Focus.status(key) do
        {:ok, status} -> [status]
        {:error, _} -> []
      end
    end)
    |> Enum.uniq_by(fn status -> {status.stream, status.task_id} end)
  end

  @spec artifacts_for([recall_moment()], [Association.t()]) :: [Artifact.t()]
  defp artifacts_for(moments, associations) do
    ids = MapSet.new(Enum.map(moments, & &1.id))

    associations
    |> Enum.flat_map(fn assoc ->
      cond do
        MapSet.member?(ids, assoc.source_id) -> [assoc.target_id]
        MapSet.member?(ids, assoc.target_id) -> [assoc.source_id]
        true -> []
      end
    end)
    |> Focus.artifacts()
  end

  @spec action_recipes_for([recall_moment()], [Association.t()]) :: [ActionRecipe.t()]
  defp action_recipes_for(moments, associations) do
    moment_ids = MapSet.new(Enum.map(moments, & &1.id))
    related_ids = related_memory_ids(moment_ids, associations)

    related_ids
    |> Focus.associations_for_ids()
    |> Enum.flat_map(fn assoc ->
      if MapSet.member?(related_ids, assoc.source_id) and assoc.relation == :attached_action do
        [assoc.target_id]
      else
        []
      end
    end)
    |> Focus.action_recipes()
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
    Scope.match?(moment, opts) and Temporal.match?(moment, opts)
  end

  @spec budget(keyword()) :: map()
  defp budget(opts) do
    case Keyword.get(opts, :budget, :mid) do
      :low -> %{seed_multiplier: 1, graph_depth: 1}
      :high -> %{seed_multiplier: 4, graph_depth: 3}
      _mid -> %{seed_multiplier: 2, graph_depth: 2}
    end
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
          {:moments, moments}
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

  @spec recall_observations(term(), keyword()) :: [term()]
  defp recall_observations(cue, opts) do
    if Keyword.get(opts, :include_observations, true) do
      opts = Keyword.put_new(opts, :limit, Keyword.get(opts, :observation_limit, 5))
      {:ok, observations} = SpectreMnemonic.search_observations(cue, opts)
      observations
    else
      []
    end
  end

  @spec recall_mental_models(term(), keyword()) :: [term()]
  defp recall_mental_models(cue, opts) do
    if Keyword.get(opts, :include_mental_models, true) do
      opts = Keyword.put_new(opts, :limit, Keyword.get(opts, :mental_model_limit, 5))
      {:ok, mental_models} = SpectreMnemonic.search_mental_models(cue, opts)
      mental_models
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

  @spec confidence([recall_moment()]) :: float()
  defp confidence([]), do: 0.0
  defp confidence(moments), do: min(1.0, length(moments) / 5)

  @spec compact_knowledge(keyword()) :: [Knowledge.Record.t()]
  defp compact_knowledge(opts) do
    include? =
      opts
      |> Keyword.get(:include_knowledge, true)

    if include? do
      case Knowledge.Base.load(opts) do
        {:ok, %{summary: nil, skills: [], latest_ingestions: [], facts: [], procedures: []}} -> []
        {:ok, knowledge} -> [knowledge]
      end
    else
      []
    end
  end

  @spec status_match?(recall_moment(), Cue.t()) :: boolean()
  defp status_match?(moment, cue) do
    cue_text = String.downcase(cue.text)

    String.contains?(cue_text, "how") and String.contains?(cue_text, "going") and
      not is_nil(moment.task_id)
  end

  @spec asks_when?(Cue.t()) :: boolean()
  defp asks_when?(cue) do
    question_contains?(cue, ~w(when quando cuándo quand wann))
  end

  @spec asks_action?(Cue.t()) :: boolean()
  defp asks_action?(cue) do
    question_contains?(cue, ["what", "did", "do", "cosa", "che", "quoi", "que", "qué"])
  end

  @spec asks_value?(Cue.t()) :: boolean()
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

  @spec question_contains?(Cue.t(), [binary()]) :: boolean()
  defp question_contains?(cue, words) do
    text = String.downcase(cue.text)
    Enum.any?(words, &String.contains?(text, &1))
  end

  @spec overlap([term()], [term()]) :: non_neg_integer()
  defp overlap(left, right) do
    left = MapSet.new(left)
    right = MapSet.new(right)
    MapSet.size(MapSet.intersection(left, right))
  end

  @spec semantic_score(Moment.t() | map(), Cue.t() | map(), map()) :: number()
  defp semantic_score(%{id: id, vector: left, binary_signature: signature}, cue, index_scores)
       when is_binary(left) and is_binary(cue.vector) do
    case Map.fetch(index_scores, id) do
      {:ok, result} ->
        result.score

      :error ->
        cosine = max(0.0, Vector.cosine(left, cue.vector))
        signature_bits = signature_bits(cue.embedding, signature, cue.binary_signature)
        hamming = Vector.hamming_similarity(signature, cue.binary_signature, signature_bits)
        cosine * 4 + hamming * 4
    end
  end

  defp semantic_score(moment, cue, _index_scores) do
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

  @spec keywords(binary()) :: [binary()]
  defp keywords(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b\p{Lu}[\p{L}\p{N}_]+\b/u, text)
    |> List.flatten()
    |> Enum.uniq()
  end
end
