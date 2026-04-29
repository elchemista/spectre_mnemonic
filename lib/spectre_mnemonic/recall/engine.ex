defmodule SpectreMnemonic.Recall.Engine do
  @moduledoc """
  Builds recall packets from active ETS memory.

  The search is intentionally brute-force in V1: keyword/entity overlap,
  optional vector cosine similarity, fingerprint hamming distance, and graph
  expansion through associations.
  """

  use GenServer

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Memory.{Moment, Secret}
  alias SpectreMnemonic.Recall.{Cue, Index, Packet}
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
    moments = Focus.moments()
    associations = Focus.associations()
    limit = Keyword.get(opts, :limit, 10)
    {:ok, index_results} = Index.query(cue, opts)
    index_scores = Map.new(index_results, &{&1.id, &1})

    ranked =
      moments
      |> Enum.map(&{score(&1, cue, index_scores), &1})
      |> Enum.filter(fn {score, _moment} -> score > 0 end)
      |> Enum.sort_by(fn {score, moment} ->
        {-score, DateTime.to_unix(moment.inserted_at, :microsecond)}
      end)
      |> Enum.map(fn {_score, moment} -> moment end)
      |> expand_graph(associations)
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(limit)

    revealed = Enum.map(ranked, &Secrets.maybe_reveal(&1, opts))

    packet = %Packet{
      cue: cue,
      active_status: active_status(ranked),
      moments: revealed,
      knowledge: compact_knowledge(opts),
      artifacts: artifacts_for(ranked, associations),
      associations: associations_for(ranked, associations),
      action_recipes: action_recipes_for(ranked, associations),
      confidence: confidence(ranked)
    }

    {:reply, {:ok, packet}, state}
  end

  @spec build_cue(term(), keyword()) :: Cue.t()
  defp build_cue(input, opts) do
    text = if is_binary(input), do: input, else: inspect(input)
    embedding = SpectreMnemonic.Embedding.Service.embed(input, opts)

    %Cue{
      input: input,
      text: text,
      keywords: keywords(text),
      entities: entities(text),
      vector: embedding.vector,
      binary_signature: Map.get(embedding, :binary_signature),
      embedding: embedding,
      fingerprint: SpectreMnemonic.Recall.Fingerprint.build(text),
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

  @spec expand_graph([recall_moment()], [SpectreMnemonic.Memory.Association.t()]) :: [
          recall_moment()
        ]
  defp expand_graph(moments, associations) do
    ids = MapSet.new(Enum.map(moments, & &1.id))

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

    linked =
      Focus.moments()
      |> Enum.filter(&MapSet.member?(linked_ids, &1.id))

    moments ++ linked
  end

  @spec associations_for([recall_moment()], [SpectreMnemonic.Memory.Association.t()]) ::
          [SpectreMnemonic.Memory.Association.t()]
  defp associations_for(moments, associations) do
    ids = MapSet.new(Enum.map(moments, & &1.id))

    Enum.filter(associations, fn assoc ->
      MapSet.member?(ids, assoc.source_id) or MapSet.member?(ids, assoc.target_id)
    end)
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

  @spec artifacts_for([recall_moment()], [SpectreMnemonic.Memory.Association.t()]) ::
          [SpectreMnemonic.Memory.Artifact.t()]
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

  @spec action_recipes_for([recall_moment()], [SpectreMnemonic.Memory.Association.t()]) ::
          [SpectreMnemonic.Memory.ActionRecipe.t()]
  defp action_recipes_for(moments, associations) do
    moment_ids = MapSet.new(Enum.map(moments, & &1.id))
    related_ids = related_memory_ids(moment_ids, associations)

    associations
    |> Enum.flat_map(fn assoc ->
      if MapSet.member?(related_ids, assoc.source_id) and assoc.relation == :attached_action do
        [assoc.target_id]
      else
        []
      end
    end)
    |> Focus.action_recipes()
  end

  @spec related_memory_ids(MapSet.t(), [SpectreMnemonic.Memory.Association.t()]) :: MapSet.t()
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

  @spec compact_knowledge(keyword()) :: [SpectreMnemonic.Knowledge.Record.t()]
  defp compact_knowledge(opts) do
    include? =
      opts
      |> Keyword.get(:include_knowledge, true)

    if include? do
      case SpectreMnemonic.Knowledge.Base.load(opts) do
        {:ok, %{summary: nil, skills: [], latest_ingestions: [], facts: [], procedures: []}} -> []
        {:ok, knowledge} -> [knowledge]
      end
    else
      []
    end
  end

  @spec status_match?(recall_moment(), Cue.t()) :: boolean()
  defp status_match?(moment, cue) do
    String.contains?(cue.text, "how") and String.contains?(cue.text, "going") and
      not is_nil(moment.task_id)
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
      SpectreMnemonic.Recall.Fingerprint.hamming_similarity(moment.fingerprint, cue.fingerprint)

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
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b[A-Z][A-Za-z0-9_]+\b/, text)
    |> List.flatten()
    |> Enum.uniq()
  end
end
