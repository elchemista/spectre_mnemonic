defmodule SpectreMnemonic.Reflection do
  @moduledoc false

  alias SpectreMnemonic.Reflection.Packet

  @observation_rank %{
    decision: 0,
    preference: 1,
    project_state: 2,
    pattern: 3,
    fact: 4
  }

  @doc "Builds an evidence packet and optionally lets an adapter respond."
  @spec reflect(term(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  def reflect(query, opts \\ []) do
    model_limit = Keyword.get(opts, :mental_model_limit, Keyword.get(opts, :limit, 5))
    observation_limit = Keyword.get(opts, :observation_limit, Keyword.get(opts, :limit, 5))

    with {:ok, mental_models} <-
           SpectreMnemonic.search_mental_models(query, Keyword.put(opts, :limit, model_limit)),
         {:ok, observations} <-
           SpectreMnemonic.search_observations(
             query,
             Keyword.put(opts, :limit, observation_limit)
           ),
         {:ok, recall} <- SpectreMnemonic.recall(query, opts) do
      observations = rank_observations(observations)

      packet =
        %Packet{
          query: query,
          mental_models: mental_models,
          observations: observations,
          raw_memories: recall.moments,
          knowledge: recall.knowledge,
          citations: citations(mental_models, observations, recall.moments),
          directives: Keyword.get(opts, :directives),
          disposition: Keyword.get(opts, :disposition),
          confidence: confidence(mental_models, observations, recall.moments),
          usage: Map.get(recall, :usage, %{}),
          metadata: %{adapter?: not is_nil(reflection_adapter(opts))}
        }

      run_adapter(packet, opts)
    end
  end

  @spec run_adapter(Packet.t(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  defp run_adapter(packet, opts) do
    case reflection_adapter(opts) do
      nil ->
        {:ok, packet}

      adapter ->
        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :reflect, 2) do
          adapter.reflect(packet, opts)
          |> normalize_response(packet)
        else
          {:error, {:invalid_reflection_adapter, adapter}}
        end
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec reflection_adapter(keyword()) :: module() | nil
  defp reflection_adapter(opts) do
    Keyword.get(opts, :adapter) ||
      Keyword.get(opts, :reflection_adapter) ||
      Application.get_env(:spectre_mnemonic, :reflection_adapter)
  end

  @spec normalize_response(term(), Packet.t()) :: {:ok, Packet.t()} | {:error, term()}
  defp normalize_response({:ok, %Packet{} = packet}, _default), do: {:ok, packet}
  defp normalize_response({:ok, response}, packet), do: {:ok, %{packet | response: response}}
  defp normalize_response({:error, reason}, _packet), do: {:error, reason}
  defp normalize_response(%Packet{} = packet, _default), do: {:ok, packet}
  defp normalize_response(response, packet), do: {:ok, %{packet | response: response}}

  @spec citations([term()], [term()], [term()]) :: [map()]
  defp citations(mental_models, observations, raw_memories) do
    model_citations =
      Enum.map(mental_models, fn model ->
        %{
          source: :mental_model,
          id: Map.get(model, :id),
          source_ids: Map.get(model, :source_ids, [])
        }
      end)

    observation_citations =
      Enum.map(observations, fn observation ->
        %{
          source: :observation,
          id: Map.get(observation, :id),
          source_ids: Map.get(observation, :source_ids, [])
        }
      end)

    raw_citations =
      Enum.map(raw_memories, fn memory ->
        %{source: :moment, id: Map.get(memory, :id), source_ids: [Map.get(memory, :id)]}
      end)

    model_citations ++ observation_citations ++ raw_citations
  end

  @spec rank_observations([term()]) :: [term()]
  defp rank_observations(observations) do
    observations
    |> Enum.with_index()
    |> Enum.sort_by(fn {observation, index} -> {observation_rank(observation), index} end)
    |> Enum.map(fn {observation, _index} -> observation end)
  end

  @spec observation_rank(term()) :: non_neg_integer()
  defp observation_rank(observation) do
    type =
      case Map.get(observation, :metadata, %{}) do
        metadata when is_map(metadata) -> Map.get(metadata, :observation_type, :fact)
        _metadata -> :fact
      end

    Map.get(@observation_rank, type, map_size(@observation_rank))
  end

  @spec confidence([term()], [term()], [term()]) :: float()
  defp confidence(mental_models, observations, raw_memories) do
    cond do
      mental_models != [] -> 0.9
      observations != [] -> min(0.85, 0.4 + length(observations) * 0.1)
      raw_memories != [] -> min(0.7, 0.25 + length(raw_memories) * 0.08)
      true -> 0.0
    end
  end
end
