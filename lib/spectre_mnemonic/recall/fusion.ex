defmodule SpectreMnemonic.Recall.Fusion do
  @moduledoc false

  @default_k 60

  @doc "Fuses ranked result lists with reciprocal rank fusion."
  @spec rrf([[term()]], keyword()) :: [{float(), term()}]
  def rrf(result_lists, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)

    result_lists
    |> Enum.flat_map(fn results ->
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, rank} -> {result_id(result), 1.0 / (k + rank), result} end)
    end)
    |> Enum.reject(fn {id, _score, _result} -> is_nil(id) end)
    |> Enum.reduce(%{}, fn {id, score, result}, acc ->
      Map.update(acc, id, {score, result}, fn {current, previous} ->
        {current + score, previous || result}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {score, result} -> {-score, result_sort_id(result)} end)
  end

  @spec result_id(term()) :: term()
  defp result_id(%{id: id}), do: id
  defp result_id(%{memory_id: id}), do: id
  defp result_id(%{source_id: id}), do: id
  defp result_id(_result), do: nil

  @spec result_sort_id(term()) :: binary()
  defp result_sort_id(result), do: result |> result_id() |> inspect()
end
