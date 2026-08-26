defmodule SpectreMnemonic.Recall.Diagnostics do
  @moduledoc false

  alias SpectreMnemonic.QueryContext

  @doc false
  @spec build(QueryContext.t(), map(), term(), map(), [term()], [term()], [term()], [term()]) ::
          map()
  def build(
        cue,
        candidate_meta,
        index_status,
        durable_sources,
        index_results,
        durable_results,
        graph_ranked,
        final_moments
      ) do
    sources =
      %{
        hot_lexical: :ok,
        hot_vector: vector_source_status(cue, index_status),
        durable_index: Map.get(durable_sources, :durable_index, :unknown),
        primary_store: Map.get(durable_sources, :primary_store, :not_requested)
      }
      |> Map.new(fn {source, status} -> {source, sanitize_status(status)} end)

    stores =
      durable_sources
      |> Map.get(:stores, %{})
      |> Map.new(fn {store, status} -> {store, sanitize_status(status)} end)

    projection_sources = projection_source_counts(Map.get(candidate_meta, :sources, %{}))

    %{
      completeness:
        if(Enum.any?(sources, fn {_source, status} -> degraded?(status) end),
          do: :partial,
          else: :complete
        ),
      sources: sources,
      stores: stores,
      candidate_mode: Map.get(candidate_meta, :mode, :brute_force),
      candidates: %{
        lexical: Map.get(projection_sources, :lexical, 0),
        entity: Map.get(projection_sources, :entity, 0),
        recent: Map.get(projection_sources, :recent, 0),
        vector: length(index_results),
        durable: length(durable_results),
        graph: length(graph_ranked),
        final: length(final_moments),
        selected: Map.get(candidate_meta, :candidates, 0),
        total_hot: Map.get(candidate_meta, :total, 0)
      }
    }
  end

  @doc false
  @spec enforce_consistency(map(), keyword()) :: :ok | {:error, term()}
  def enforce_consistency(diagnostics, opts) do
    if Keyword.get(opts, :consistency, :available) == :strict do
      requested = Keyword.get(opts, :required_sources, Map.keys(diagnostics.sources))

      failures =
        diagnostics.sources
        |> Enum.filter(fn {source, status} -> source in requested and degraded?(status) end)
        |> Map.new()

      if map_size(failures) == 0,
        do: :ok,
        else: {:error, {:mnemonic_recall_incomplete, failures}}
    else
      :ok
    end
  end

  @spec vector_source_status(QueryContext.t(), term()) :: term()
  defp vector_source_status(%QueryContext{embedding: %{error: reason}}, _index_status)
       when not is_nil(reason),
       do: {:degraded, reason}

  defp vector_source_status(%QueryContext{vector: nil}, _index_status), do: :not_requested
  defp vector_source_status(_cue, index_status), do: index_status

  @spec projection_source_counts(map()) :: map()
  defp projection_source_counts(sources) do
    Enum.reduce(sources, %{lexical: 0, entity: 0, recent: 0}, fn
      {:lexical, count}, acc -> Map.update!(acc, :lexical, &(&1 + count))
      {:entity, count}, acc -> Map.update!(acc, :entity, &(&1 + count))
      {{:term, _term}, count}, acc -> Map.update!(acc, :lexical, &(&1 + count))
      {{:entity, _entity}, count}, acc -> Map.update!(acc, :entity, &(&1 + count))
      {:recent, count}, acc -> Map.update!(acc, :recent, &(&1 + count))
      {_other, _count}, acc -> acc
    end)
  end

  defp sanitize_status({status, reason}) when status in [:error, :degraded],
    do: {status, safe_reason(reason)}

  defp sanitize_status(status), do: status

  defp safe_reason(reason) when is_atom(reason) or is_number(reason), do: reason

  defp safe_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp safe_reason(reason) when is_exception(reason), do: reason.__struct__
  defp safe_reason(_reason), do: :redacted

  @spec degraded?(term()) :: boolean()
  defp degraded?({:error, _reason}), do: true
  defp degraded?({:degraded, _reason}), do: true
  defp degraded?(:unknown), do: true
  defp degraded?(_status), do: false
end
