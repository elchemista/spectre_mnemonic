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

  @doc "Builds a structured evidence packet without generating an answer."
  @spec reflect(term(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  def reflect(query, opts \\ []) do
    # Reflection is a packet builder before it is an adapter call. I want sources
    # lined up first, then the model can talk. Receipts before poetry.
    model_limit = Keyword.get(opts, :mental_model_limit, Keyword.get(opts, :limit, 5))
    observation_limit = Keyword.get(opts, :observation_limit, Keyword.get(opts, :limit, 5))

    recall_opts =
      opts
      |> Keyword.put(:mental_model_limit, model_limit)
      |> Keyword.put(:observation_limit, observation_limit)
      |> Keyword.put(:include_mental_models, true)
      |> Keyword.put(:include_observations, true)

    with {:ok, recall} <- SpectreMnemonic.recall(query, recall_opts) do
      mental_models = Enum.take(recall.mental_models, model_limit)
      observations = recall.observations |> rank_observations() |> Enum.take(observation_limit)
      evidence = evidence(mental_models, observations, recall.moments)

      packet =
        %Packet{
          query: query,
          mental_models: mental_models,
          observations: observations,
          raw_memories: recall.moments,
          knowledge: recall.knowledge,
          evidence: evidence,
          citations: citations(mental_models, observations, recall.moments),
          directives: Keyword.get(opts, :directives),
          disposition: Keyword.get(opts, :disposition),
          confidence: confidence(mental_models, observations, recall.moments),
          usage: Map.get(recall, :usage, %{}),
          metadata: %{
            query_context: recall.query_context,
            response_generation: :spectre
          }
        }

      {:ok, packet}
    end
  end

  @spec evidence([term()], [term()], [term()]) :: [map()]
  defp evidence(mental_models, observations, raw_memories) do
    model_evidence =
      Enum.map(mental_models, fn model ->
        %{
          type: :mental_model,
          id: Map.get(model, :id),
          claim: Map.get(model, :answer),
          query: Map.get(model, :query),
          source_ids: Map.get(model, :source_ids, []),
          citations: Map.get(model, :citations, []),
          state: Map.get(model, :state),
          provenance: provenance(model)
        }
      end)

    observation_evidence =
      Enum.map(observations, fn observation ->
        %{
          type: :observation,
          id: Map.get(observation, :id),
          claim: Map.get(observation, :statement),
          source_ids: Map.get(observation, :source_ids, []),
          evidence: Map.get(observation, :evidence, []),
          confidence: Map.get(observation, :confidence),
          state: Map.get(observation, :state),
          provenance: provenance(observation)
        }
      end)

    memory_evidence =
      Enum.map(raw_memories, fn memory ->
        %{
          type: :moment,
          id: Map.get(memory, :id),
          claim: Map.get(memory, :text),
          source_ids: [Map.get(memory, :id)],
          occurred_at: Map.get(memory, :occurred_at),
          observed_at: Map.get(memory, :observed_at),
          provenance: provenance(memory)
        }
      end)

    model_evidence ++ observation_evidence ++ memory_evidence
  end

  @spec provenance(term()) :: map()
  defp provenance(memory) do
    case Map.get(memory, :metadata, %{}) do
      metadata when is_map(metadata) -> Map.get(metadata, :provenance, %{})
      _metadata -> %{}
    end
  end

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
