defmodule SpectreMnemonic.Recall.Features do
  @moduledoc false

  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Recall.Fingerprint

  @hamming_threshold 0.72

  @doc false
  @spec score(map(), QueryContext.t(), map(), keyword()) :: number()
  def score(moment, cue, index_scores, opts) do
    keyword_score = overlap(moment.keywords, cue.keywords) * 2
    entity_score = overlap(moment.entities, cue.entities) * 3
    semantic_score = semantic_score(moment, cue, index_scores, opts)
    status_bonus = if status_match?(moment, cue), do: 2, else: 0
    match_score = keyword_score + entity_score + semantic_score + status_bonus

    if match_score > 0, do: match_score + moment.attention, else: 0
  end

  @doc false
  @spec structured_score(map(), QueryContext.t()) :: number()
  def structured_score(%{kind: :memory_entity, metadata: metadata} = moment, cue) do
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

  def structured_score(%{kind: :memory_event} = moment, cue) do
    cond do
      asks_when?(cue) and overlap(moment.keywords, cue.keywords) > 0 -> 5 + moment.attention
      asks_action?(cue) and overlap(moment.keywords, cue.keywords) > 0 -> 5 + moment.attention
      true -> 0
    end
  end

  def structured_score(%{kind: :memory_time} = moment, cue) do
    if asks_when?(cue), do: 3 + moment.attention, else: 0
  end

  def structured_score(%{kind: :memory_value} = moment, cue) do
    if asks_value?(cue), do: 3 + moment.attention, else: 0
  end

  def structured_score(_moment, _cue), do: 0

  @doc false
  @spec normalize(number()) :: float()
  def normalize(score) when score > 0, do: score / (score + 4.0)
  def normalize(_score), do: 0.0

  @doc false
  @spec confidence([map()], QueryContext.t(), map()) :: float()
  def confidence([], _cue, _index_scores), do: 0.0

  def confidence(moments, cue, index_scores) do
    moments
    |> Enum.take(3)
    |> Enum.map(fn moment ->
      moment
      |> score(cue, index_scores, cue.opts)
      |> max(structured_score(moment, cue))
      |> normalize()
    end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end

  @spec status_match?(map(), QueryContext.t()) :: boolean()
  defp status_match?(moment, cue) do
    cue_text = String.downcase(cue.text)

    String.contains?(cue_text, "how") and String.contains?(cue_text, "going") and
      not is_nil(moment.task_id)
  end

  @spec asks_when?(QueryContext.t()) :: boolean()
  defp asks_when?(cue), do: question_contains?(cue, ~w(when quando cuándo quand wann))

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

  @spec semantic_score(map(), QueryContext.t(), map(), keyword()) :: number()
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
    similarity = Fingerprint.hamming_similarity(moment.fingerprint, cue.fingerprint)
    if similarity >= @hamming_threshold, do: similarity * 4, else: 0.0
  end

  @spec signature_bits(map(), binary() | nil, binary() | nil) :: non_neg_integer()
  defp signature_bits(%{metadata: %{signature_bits: bits}}, _left, _right)
       when is_integer(bits),
       do: bits

  defp signature_bits(_embedding, left, right),
    do: min(byte_size(left || <<>>) * 8, byte_size(right || <<>>) * 8)
end
