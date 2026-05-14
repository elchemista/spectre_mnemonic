defmodule SpectreMnemonic.Recall.Engine do
  @moduledoc """
  Builds recall packets from active ETS memory.

  The search is intentionally brute-force in V1: keyword/entity overlap,
  optional vector cosine similarity, fingerprint hamming distance, and graph
  expansion through associations.
  """

  use GenServer

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Embedding.{Service, Vector}
  alias SpectreMnemonic.Knowledge
  alias SpectreMnemonic.Memory.{ActionRecipe, Artifact, Association, Moment, Secret}
  alias SpectreMnemonic.Recall.{Cue, Fingerprint, Index, Packet}
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

  @impl true
  @spec init(map()) :: {:ok, map()}
  def init(state), do: {:ok, state}

  @impl true
  @spec handle_call({:recall, term(), keyword()}, GenServer.from(), map()) ::
          {:reply, {:ok, Packet.t()}, map()}
  def handle_call({:recall, cue_input, opts}, _from, state) do
    cue = build_cue(cue_input, opts)
    limit = Keyword.get(opts, :limit, 10)
    {:ok, index_results} = Index.query(cue, opts)
    index_scores = Map.new(index_results, &{&1.id, &1})

    seed_limit = max(limit, limit * 2)

    ranked =
      cue
      |> ranked_moments(index_scores, seed_limit)
      |> expand_graph()
      |> Enum.uniq_by(& &1.id)
      |> rerank_moments(cue, index_scores)
      |> Enum.take(limit)

    associations = ranked |> Enum.map(& &1.id) |> Focus.associations_for_ids()
    revealed = Enum.map(ranked, &Secrets.maybe_reveal(&1, opts))

    packet = %Packet{
      cue: cue,
      active_status: active_status(ranked),
      moments: revealed,
      knowledge: compact_knowledge(opts),
      artifacts: artifacts_for(ranked, associations),
      associations: associations,
      action_recipes: action_recipes_for(ranked, associations),
      confidence: confidence(ranked)
    }

    {:reply, {:ok, packet}, state}
  end

  @spec ranked_moments(Cue.t(), map(), integer()) :: [recall_moment()]
  defp ranked_moments(_cue, _index_scores, limit) when limit <= 0, do: []

  defp ranked_moments(cue, index_scores, limit) do
    []
    |> Focus.fold_moments(fn moment, ranked ->
      case score(moment, cue, index_scores) do
        score when score > 0 -> insert_ranked({score, moment}, ranked, limit)
        _score -> ranked
      end
    end)
    |> Enum.sort_by(&rank_key/1)
    |> Enum.map(fn {_score, moment} -> moment end)
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

  @spec expand_graph([recall_moment()]) :: [recall_moment()]
  defp expand_graph(moments), do: expand_graph(moments, 2)

  @spec expand_graph([recall_moment()], non_neg_integer()) :: [recall_moment()]
  defp expand_graph(moments, 0), do: moments

  defp expand_graph(moments, depth) do
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

    if next == [] do
      moments
    else
      expand_graph(moments ++ next, depth - 1)
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
