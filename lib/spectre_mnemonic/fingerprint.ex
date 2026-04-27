defmodule SpectreMnemonic.Fingerprint do
  @moduledoc """
  Builds compact fingerprints for adapter-free recall.

  This is a simple SimHash-style fingerprint: each token votes across 32 bits,
  then hamming distance between fingerprints gives a rough similarity signal.
  It is deliberately small and local so recall keeps working without embeddings.
  """

  import Bitwise

  @bits 32
  @range 4_294_967_296

  @doc "Returns a 32-bit fingerprint for text or any inspectable term."
  def build(input) do
    input
    |> to_text()
    |> tokens()
    |> case do
      [] -> [:erlang.phash2(to_text(input), @range)]
      tokens -> tokens
    end
    |> Enum.reduce(List.duplicate(0, @bits), &vote_token/2)
    |> bits_to_integer()
  end

  @doc "Counts differing bits between two integer fingerprints."
  def hamming_distance(left, right) when is_integer(left) and is_integer(right) do
    left
    |> bxor(right)
    |> Integer.digits(2)
    |> Enum.count(&(&1 == 1))
  end

  @doc "Returns similarity in the `0.0..1.0` range from hamming distance."
  def hamming_similarity(left, right) when is_integer(left) and is_integer(right) do
    max(0.0, 1.0 - hamming_distance(left, right) / @bits)
  end

  def hamming_similarity(_left, _right), do: 0.0

  defp vote_token(token, votes) do
    hash = :erlang.phash2(token, @range)

    Enum.with_index(votes)
    |> Enum.map(fn {score, bit} ->
      if (hash &&& 1 <<< bit) == 0, do: score - 1, else: score + 1
    end)
  end

  defp bits_to_integer(votes) do
    votes
    |> Enum.with_index()
    |> Enum.reduce(0, fn {score, bit}, acc ->
      if score >= 0, do: acc ||| 1 <<< bit, else: acc
    end)
  end

  defp tokens(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
  end

  defp to_text(input) when is_binary(input), do: input
  defp to_text(input), do: inspect(input)
end
