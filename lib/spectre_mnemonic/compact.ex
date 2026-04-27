defmodule SpectreMnemonic.Compact do
  @moduledoc """
  Adapter-driven progressive knowledge compaction.
  """

  alias SpectreMnemonic.{Focus, KnowledgeBase}
  alias SpectreMnemonic.Store.KnowledgeSMEM

  @doc "Compacts active memory and existing knowledge events into `knowledge.smem`."
  @spec compact_knowledge(keyword()) ::
          {:ok, %{events: [map()], count: non_neg_integer()}} | {:error, term()}
  def compact_knowledge(opts \\ []) do
    cfg = KnowledgeBase.config(opts)

    with {:ok, existing_events} <- KnowledgeSMEM.replay(cfg),
         input <- build_input(existing_events, cfg, opts),
         {:ok, compacted} <- run_adapter(input, opts),
         {:ok, events} <- normalize_output(compacted),
         events <- add_marker(events),
         {:ok, count} <- KnowledgeSMEM.replace(events, cfg) do
      {:ok, %{events: events, count: count}}
    end
  end

  @spec build_input([map()], keyword(), keyword()) :: map()
  defp build_input(existing_events, cfg, opts) do
    moments = Focus.moments()

    %{
      moments: moments,
      existing_events: existing_events,
      summaries: Enum.filter(moments, &(&1.kind == :memory_summary)),
      categories: Enum.filter(moments, &(&1.kind == :memory_category)),
      skills: Enum.filter(existing_events, &(Map.get(&1, :type) == :skill)),
      budgets: %{
        max_loaded_bytes: Keyword.fetch!(cfg, :max_loaded_bytes),
        max_latest_ingestions: Keyword.fetch!(cfg, :max_latest_ingestions),
        max_skills: Keyword.fetch!(cfg, :max_skills),
        max_facts: Keyword.fetch!(cfg, :max_facts),
        max_procedures: Keyword.fetch!(cfg, :max_procedures)
      },
      opts: opts
    }
  end

  @spec run_adapter(map(), keyword()) :: {:ok, term()} | {:error, term()}
  defp run_adapter(input, opts) do
    case adapter(opts) do
      nil -> {:ok, default_compact(input)}
      module -> compact_with_adapter(module, input, opts)
    end
  end

  @spec adapter(keyword()) :: module() | nil
  defp adapter(opts) do
    Keyword.get(opts, :compact_adapter) ||
      Application.get_env(:spectre_mnemonic, :compact_adapter)
  end

  @spec compact_with_adapter(module(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  defp compact_with_adapter(module, input, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compact, 2) do
      case module.compact(input, opts) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_compact_result, other}}
      end
    else
      {:error, {:invalid_compact_adapter, module}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec default_compact(map()) :: [map()]
  defp default_compact(%{moments: moments, existing_events: existing_events, budgets: budgets}) do
    summary = global_summary(moments, existing_events)

    summaries =
      moments
      |> Enum.filter(&(&1.kind == :memory_summary))
      |> Enum.sort_by(&{-&1.attention, DateTime.to_unix(&1.inserted_at, :microsecond)})
      |> Enum.take(5)
      |> Enum.map(&event_from_moment(&1, :fact))

    latest =
      moments
      |> Enum.reject(&(&1.kind in [:memory_summary, :memory_category]))
      |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond), :desc)
      |> Enum.take(budgets.max_latest_ingestions)
      |> Enum.map(&event_from_moment(&1, :latest_ingestion))

    existing_keep =
      existing_events
      |> Enum.map(&KnowledgeSMEM.normalize_event/1)
      |> Enum.filter(&(&1.type in [:skill, :procedure, :fact]))

    [%{type: :summary, summary: summary, text: summary, metadata: %{strategy: :default}}]
    |> Kernel.++(summaries)
    |> Kernel.++(latest)
    |> Kernel.++(existing_keep)
    |> dedupe_events()
  end

  @spec normalize_output(term()) :: {:ok, [map()]} | {:error, term()}
  defp normalize_output({:ok, output}), do: normalize_output(output)
  defp normalize_output({:error, reason}), do: {:error, reason}
  defp normalize_output(output) when is_list(output), do: {:ok, normalize_events(output)}

  defp normalize_output(output) when is_map(output) do
    events =
      output
      |> events_from_output(:summary)
      |> Kernel.++(events_from_output(output, :skill))
      |> Kernel.++(events_from_output(output, :latest_ingestion))
      |> Kernel.++(events_from_output(output, :fact))
      |> Kernel.++(events_from_output(output, :procedure))
      |> Kernel.++(events_from_output(output, :compaction_marker))

    {:ok, normalize_events(events)}
  end

  defp normalize_output(other), do: {:error, {:invalid_compact_output, other}}

  @spec events_from_output(map(), atom()) :: [map()]
  defp events_from_output(output, :summary) do
    case Map.get(output, :summary) || Map.get(output, "summary") do
      nil -> []
      summary when is_map(summary) -> [Map.put(summary, :type, :summary)]
      summary -> [%{type: :summary, summary: to_text(summary), text: to_text(summary)}]
    end
  end

  defp events_from_output(output, type) do
    key = plural_key(type)
    values = Map.get(output, key) || Map.get(output, Atom.to_string(key)) || []

    values
    |> List.wrap()
    |> Enum.map(fn
      event when is_map(event) -> Map.put(event, :type, type)
      value -> %{type: type, text: to_text(value), value: value}
    end)
  end

  @spec normalize_events([term()]) :: [map()]
  defp normalize_events(events) do
    events
    |> Enum.filter(&is_map/1)
    |> Enum.map(&KnowledgeSMEM.normalize_event/1)
    |> dedupe_events()
  end

  @spec add_marker([map()]) :: [map()]
  defp add_marker(events) do
    marker = %{
      type: :compaction_marker,
      text: "knowledge compacted",
      metadata: %{event_count: length(events)},
      inserted_at: DateTime.utc_now()
    }

    events ++ [KnowledgeSMEM.normalize_event(marker)]
  end

  @spec event_from_moment(map(), atom()) :: map()
  defp event_from_moment(moment, type) do
    %{
      type: type,
      text: compact_moment_text(moment.text),
      source_id: moment.id,
      metadata: %{
        stream: moment.stream,
        task_id: moment.task_id,
        kind: moment.kind,
        attention: moment.attention
      },
      inserted_at: moment.inserted_at
    }
  end

  @spec global_summary([map()], [map()]) :: binary()
  defp global_summary(moments, existing_events) do
    existing_summary =
      existing_events
      |> Enum.map(&KnowledgeSMEM.normalize_event/1)
      |> Enum.find(&(&1.type == :summary))

    cond do
      existing_summary && existing_summary.summary ->
        existing_summary.summary

      moments == [] ->
        "No compact knowledge has been built yet."

      true ->
        moments
        |> Enum.sort_by(&{-&1.attention, DateTime.to_unix(&1.inserted_at, :microsecond)})
        |> Enum.take(5)
        |> Enum.map_join(" | ", &compact_moment_text(&1.text))
    end
  end

  @spec dedupe_events([map()]) :: [map()]
  defp dedupe_events(events) do
    events
    |> Enum.reverse()
    |> Enum.uniq_by(fn event ->
      {Map.get(event, :type),
       Map.get(event, :name) || Map.get(event, :summary) || Map.get(event, :text) ||
         inspect(Map.get(event, :value))}
    end)
    |> Enum.reverse()
  end

  @spec plural_key(atom()) :: atom()
  defp plural_key(:skill), do: :skills
  defp plural_key(:latest_ingestion), do: :latest_ingestions
  defp plural_key(:fact), do: :facts
  defp plural_key(:procedure), do: :procedures
  defp plural_key(:compaction_marker), do: :compaction_markers

  @spec compact_moment_text(term()) :: binary()
  defp compact_moment_text(text), do: text |> to_text() |> String.slice(0, 500)

  @spec to_text(term()) :: binary()
  defp to_text(text) when is_binary(text), do: text
  defp to_text(text), do: inspect(text, limit: 50)
end
