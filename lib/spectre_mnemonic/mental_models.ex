defmodule SpectreMnemonic.MentalModels do
  @moduledoc """
  Curated mental models stored beside existing durable memory.

  Mental models are stable guidance records: strategies, preferences,
  procedures, or domain principles that should be easy to recall without
  depending on raw moment recency. They can be searched alongside recall and
  reflection packets.
  """

  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.MentalModel
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Manager

  @mental_model_table :mnemonic_mental_models

  @doc """
  Stores or replaces a curated mental model.

  Accepted input can be a map, keyword list, or text. Maps may include `:id`,
  `:title`, `:query`, `:answer`, `:scope`, `:source_ids`, `:citations`,
  `:metadata`, and temporal fields. Text input uses the first non-empty line as
  title/query and the full text as the answer.

  ## Examples

      iex> SpectreMnemonic.MentalModels.put("Debugging\\nPrefer the smallest reproducible case.")
      {:ok, %SpectreMnemonic.Memory.MentalModel{}}

      iex> SpectreMnemonic.MentalModels.put(%{query: "How to review PRs?", answer: "Find risks first."})
      {:ok, %SpectreMnemonic.Memory.MentalModel{}}
  """
  @spec put(term(), keyword()) :: {:ok, MentalModel.t()} | {:error, term()}
  def put(input, opts \\ []) do
    # Mental models are curated on purpose. If everything becomes a principle,
    # nothing is a principle and we are back to prompt soup with nicer labels.
    with {:ok, opts} <- Identity.put_namespace(opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      model = build(input, opts, now)

      if Keyword.get(opts, :persist?, true) do
        with {:ok, _result} <- Manager.append(:mental_models, model, opts),
             :ok <-
               Governance.append_state(model.id, model.state, :mental_model_stored, opts) do
          :ets.insert(@mental_model_table, {model.id, model})
          {:ok, model}
        end
      else
        :ets.insert(@mental_model_table, {model.id, model})
        {:ok, model}
      end
    end
  end

  @doc """
  Searches active and durable mental models.

  Search filters by scope and temporal options, then returns matching active
  models plus durable model records found by persistent search.

  ## Example

      iex> SpectreMnemonic.MentalModels.search("review PR risks", limit: 3)
      {:ok, _models}
  """
  @spec search(term(), keyword()) ::
          {:ok, [MentalModel.t() | map()]} | {:error, :namespace_required}
  def search(cue, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      active =
        @mental_model_table
        |> safe_tab2list()
        |> Enum.map(fn {_id, model} -> model end)
        |> Enum.filter(&visible?(&1, opts))
        |> score_models(cue)

      durable = durable_models(cue, opts)

      limit = Keyword.get(opts, :limit, 10)
      {:ok, (active ++ durable) |> Enum.uniq_by(&Map.get(&1, :id)) |> Enum.take(limit)}
    end
  end

  @spec durable_models(term(), keyword()) :: [MentalModel.t() | map()]
  defp durable_models(cue, opts) do
    result =
      case Keyword.fetch(opts, :durable_results) do
        {:ok, results} -> {:ok, results}
        :error -> safe_manager_search(cue, opts)
      end

    case result do
      {:ok, results} ->
        results
        |> Enum.filter(&(Map.get(&1, :family) == :mental_models))
        |> Enum.map(&Map.get(&1, :record, &1))
        |> Enum.filter(&visible?(&1, opts))

      {:error, _reason} ->
        []
    end
  end

  @spec safe_manager_search(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp safe_manager_search(cue, opts) do
    Manager.search(cue, opts)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec build(term(), keyword(), DateTime.t()) :: MentalModel.t()
  defp build(input, opts, now) do
    # Build accepts friendly shapes, then pins them into one struct. Humans can
    # type text; runtime still gets ids, scope, provenance, and time.
    map = input_map(input)
    query = value(map, :query, Keyword.get(opts, :query) || value(map, :title, ""))

    answer =
      value(map, :answer, Keyword.get(opts, :answer) || value(map, :text, inspect(input)))

    title = value(map, :title, Keyword.get(opts, :title))
    text = Enum.join(Enum.reject([title, query, answer], &is_nil/1), "\n")
    embedding = Service.embed(text, opts)
    temporal = Temporal.from_opts(temporal_opts(map, opts), now)
    namespace = Identity.namespace!(opts)
    scope = Keyword.get(opts, :scope, value(map, :scope, nil))
    id =
      value(map, :id, Keyword.get(opts, :id) || stable_model_id(namespace, scope, query, answer))

    %MentalModel{
      id: id,
      namespace: namespace,
      title: title,
      query: query,
      answer: answer,
      scope: scope,
      source_ids: List.wrap(value(map, :source_ids, Keyword.get(opts, :source_ids, []))),
      citations: List.wrap(value(map, :citations, Keyword.get(opts, :citations, []))),
      state: value(map, :state, Keyword.get(opts, :state, :promoted)),
      vector: embedding.vector,
      binary_signature: Map.get(embedding, :binary_signature),
      embedding: embedding,
      keywords: keywords(text),
      entities: entities(text),
      occurred_at: temporal.occurred_at,
      observed_at: temporal.observed_at,
      last_verified_at: temporal.last_verified_at,
      valid_from: temporal.valid_from,
      valid_until: temporal.valid_until,
      metadata:
        metadata_value(opts, map)
        |> Map.new()
        |> Identity.put_context(Keyword.put(opts, :scope, scope))
        |> Governance.with_provenance(
          source_ids: List.wrap(value(map, :source_ids, Keyword.get(opts, :source_ids, []))),
          provider: :mental_models,
          confidence: Keyword.get(opts, :confidence, 1.0),
          observed_at: temporal.observed_at || now,
          last_verified_at: temporal.last_verified_at || now
        )
        |> Temporal.put_metadata(temporal),
      inserted_at: now
    }
  end

  @spec score_models([MentalModel.t()], term()) :: [MentalModel.t()]
  defp score_models(models, cue) do
    query_terms = cue |> to_string() |> keywords() |> MapSet.new()

    models
    |> Enum.map(fn model ->
      overlap =
        model.keywords
        |> MapSet.new()
        |> MapSet.intersection(query_terms)
        |> MapSet.size()

      {overlap, model}
    end)
    |> Enum.filter(fn {score, _model} -> score > 0 end)
    |> Enum.sort_by(fn {score, model} -> {-score, model.id} end)
    |> Enum.map(fn {_score, model} -> model end)
  end

  @spec input_map(term()) :: map()
  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)
  defp input_map(input) when is_binary(input), do: binary_input_map(input)
  defp input_map(_input), do: %{}

  @spec binary_input_map(binary()) :: map()
  defp binary_input_map(input) do
    title = input |> non_empty_lines() |> List.first()

    %{
      title: title,
      query: title || "",
      answer: input,
      text: input
    }
  end

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec metadata_value(keyword(), map()) :: map()
  defp metadata_value(opts, map) do
    Keyword.get(opts, :metadata, value(map, :metadata, %{})) || %{}
  end

  @spec temporal_opts(map(), keyword()) :: keyword()
  defp temporal_opts(map, opts) do
    Enum.reduce(Temporal.fields(), opts, fn field, acc ->
      put_temporal_opt(acc, map, field)
    end)
  end

  @spec put_temporal_opt(keyword(), map(), atom()) :: keyword()
  defp put_temporal_opt(opts, map, field) do
    value = value(map, field, nil)

    cond do
      Keyword.has_key?(opts, field) -> opts
      is_nil(value) -> opts
      true -> Keyword.put(opts, field, value)
    end
  end

  @spec visible?(map(), keyword()) :: boolean()
  defp visible?(memory, opts), do: Scope.match?(memory, opts) and Temporal.match?(memory, opts)

  @spec stable_model_id(binary(), term(), binary(), binary()) :: binary()
  defp stable_model_id(namespace, scope, query, answer) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary({namespace, scope, query, answer}))
    "mm_#{Base.encode16(hash, case: :lower) |> binary_part(0, 24)}"
  end

  @spec safe_tab2list(atom()) :: list()
  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end

  @spec keywords(binary()) :: [binary()]
  defp keywords(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
  end

  @spec non_empty_lines(binary()) :: [binary()]
  defp non_empty_lines(text) do
    text
    |> String.split(~r/\R/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b\p{Lu}[\p{L}\p{N}_]+\b/u, text)
    |> List.flatten()
    |> Enum.uniq()
  end
end
