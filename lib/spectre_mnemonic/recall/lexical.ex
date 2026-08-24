defmodule SpectreMnemonic.Recall.Lexical do
  @moduledoc false

  @stopwords ~w(
    a an and are as at be because been before being but by can cannot could did do does
    for from had has have he her hers him his how i if in into is it its may me might mine
    must my no nor not of on onto or our ours she should so than that the their theirs them
    then there these they this those through to under until was we were what when where which
    while who why will with without would you your yours
    al alla alle allo anche che chi come con da dal dalla dalle dallo dei del della delle dello
    di e era erano essere gli ha hanno i il in io la le lo ma mi nei nel nella nelle nello non
    o per perché prima può quando questa queste questi questo se senza si sono su tra tu un una
  )

  @stopword_set MapSet.new(@stopwords)

  @doc false
  @spec keywords(term(), pos_integer()) :: [binary()]
  def keywords(input, minimum_length \\ 3) do
    input
    |> text()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < minimum_length or stopword?(&1)))
    |> Enum.uniq()
  end

  @doc false
  @spec entities(term()) :: [binary()]
  def entities(input) do
    ~r/\b\p{Lu}[\p{L}\p{N}_]+\b/u
    |> Regex.scan(text(input))
    |> List.flatten()
    |> Enum.reject(&(stopword?(&1) or stopword?(String.downcase(&1))))
    |> Enum.uniq()
  end

  @doc false
  @spec stopword?(term()) :: boolean()
  def stopword?(word) when is_binary(word), do: MapSet.member?(@stopword_set, word)
  def stopword?(_word), do: false

  @spec text(term()) :: binary()
  defp text(input) when is_binary(input), do: input
  defp text(input), do: inspect(input)
end
