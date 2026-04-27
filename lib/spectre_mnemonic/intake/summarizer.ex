defmodule SpectreMnemonic.Intake.Summarizer do
  @moduledoc """
  Hierarchical summarization wrapper.

  Applications may configure `:summarizer_adapter` to provide richer LLM or
  local summaries. Without an adapter, SpectreMnemonic uses a deterministic
  fallback so intake remains useful offline.
  """

  @default_summary_words 36

  @doc "Summarizes text for a hierarchy scope such as `:chunk` or `:root`."
  @spec summarize(atom(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def summarize(scope, text, opts \\ []) when is_atom(scope) and is_binary(text) do
    input = %{
      scope: scope,
      text: text,
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }

    case adapter(opts) do
      nil -> {:ok, fallback(input, opts)}
      module -> summarize_with_adapter(module, input, opts)
    end
  end

  @spec adapter(keyword()) :: module() | nil
  defp adapter(opts) do
    Keyword.get(opts, :summarizer_adapter) ||
      Application.get_env(:spectre_mnemonic, :summarizer_adapter)
  end

  @spec summarize_with_adapter(module(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp summarize_with_adapter(module, input, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :summarize, 2) do
      case module.summarize(input, opts) do
        {:ok, summary} -> {:ok, normalize_summary(summary, input, :adapter)}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_summarizer_result, other}}
      end
    else
      {:error, {:invalid_summarizer_adapter, module}}
    end
  end

  @spec fallback(map(), keyword()) :: map()
  defp fallback(%{scope: scope, text: text}, opts) do
    words = words(text)
    limit = Keyword.get(opts, :summary_words, @default_summary_words)

    %{
      scope: scope,
      text: words |> Enum.take(limit) |> Enum.join(" "),
      key_points: key_points(text),
      entities: entities(text),
      categories: categories(text),
      relations: [],
      confidence: if(words == [], do: 0.0, else: 0.35),
      metadata: %{provider: :fallback}
    }
  end

  @spec normalize_summary(term(), map(), atom()) :: map()
  defp normalize_summary(summary, input, provider) when is_binary(summary) do
    %{
      scope: input.scope,
      text: summary,
      key_points: [],
      entities: entities(summary),
      categories: [],
      relations: [],
      confidence: 0.75,
      metadata: %{provider: provider}
    }
  end

  defp normalize_summary(summary, input, provider) when is_map(summary) do
    summary = atomize_known_keys(summary)

    %{
      scope: Map.get(summary, :scope, input.scope),
      text: Map.get(summary, :text) || Map.get(summary, :summary) || fallback(input, []).text,
      key_points: List.wrap(Map.get(summary, :key_points, [])),
      entities: List.wrap(Map.get(summary, :entities, [])),
      categories: List.wrap(Map.get(summary, :categories, [])),
      relations: List.wrap(Map.get(summary, :relations, [])),
      confidence: Map.get(summary, :confidence, 0.75),
      metadata: Map.merge(%{provider: provider}, Map.new(Map.get(summary, :metadata, %{})))
    }
  end

  defp normalize_summary(summary, input, provider) when is_list(summary) do
    summary |> Enum.map_join("\n", &to_string/1) |> normalize_summary(input, provider)
  end

  defp normalize_summary(summary, input, provider),
    do: summary |> inspect() |> normalize_summary(input, provider)

  @spec atomize_known_keys(map()) :: map()
  defp atomize_known_keys(map) do
    known = ~w(scope text summary key_points entities categories relations confidence metadata)a

    Enum.reduce(map, %{}, fn {key, value}, acc ->
      key =
        if is_binary(key) do
          Enum.find(known, &(Atom.to_string(&1) == key)) || key
        else
          key
        end

      Map.put(acc, key, value)
    end)
  end

  @spec key_points(binary()) :: [binary()]
  defp key_points(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(3)
  end

  @spec categories(binary()) :: [atom()]
  defp categories(text) do
    tokens = MapSet.new(words(text) |> Enum.map(&String.downcase/1))

    [
      decision: ~w(decision decide decided choose chosen tradeoff because therefore),
      task: ~w(task todo action next must should implement build fix verify deadline),
      research: ~w(research evidence study source finding observed analysis hypothesis),
      error: ~w(error failure failed exception bug issue risk problem blocked),
      tool: ~w(tool command api endpoint script adapter integration function module),
      event: ~w(event happened meeting call update status timeline milestone),
      concept: ~w(concept definition means architecture design pattern model system)
    ]
    |> Enum.filter(fn {_label, rule_words} ->
      Enum.any?(rule_words, &MapSet.member?(tokens, &1))
    end)
    |> Enum.map(fn {label, _rule_words} -> label end)
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b[A-Z][A-Za-z0-9_]+\b/, text)
    |> List.flatten()
    |> Enum.uniq()
  end

  @spec words(binary()) :: [binary()]
  defp words(text) do
    Regex.scan(~r/[\p{L}\p{N}_'-]+/u, text)
    |> List.flatten()
  end
end
