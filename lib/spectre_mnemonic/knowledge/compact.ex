defmodule SpectreMnemonic.Knowledge.Compact do
  @moduledoc """
  Adapter-driven progressive knowledge compaction.

  Compact knowledge is the small, always-loadable memory layer stored in
  `knowledge.smem`. Compaction combines recent active memory with existing
  knowledge events, optionally hands that bundle to an adapter, normalizes the
  adapter output, and replaces the compact event log.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Knowledge.Base
  alias SpectreMnemonic.Knowledge.SMEM

  @doc """
  Compacts active memory and existing knowledge events into `knowledge.smem`.

  Without an adapter, the default strategy keeps a global summary, important
  summaries, latest ingestions, and existing skill/procedure/fact events. With an
  adapter, the adapter receives a map containing `:moments`, `:existing_events`,
  `:summaries`, `:categories`, `:skills`, `:budgets`, and original opts.

  ## Examples

      iex> SpectreMnemonic.Knowledge.Compact.compact_knowledge()
      {:ok, %{events: _events, count: _count}}

      iex> SpectreMnemonic.Knowledge.Compact.compact_knowledge(compact_adapter: MyCompactAdapter)
      {:ok, %{events: _events, count: _count}}
  """
  @spec compact_knowledge(keyword()) ::
          {:ok, %{events: [map()], count: non_neg_integer()}} | {:error, term()}
  def compact_knowledge(opts \\ []) do
    cfg = Base.config(opts)

    with {:ok, existing_events} <- SMEM.replay(cfg),
         input <- build_input(existing_events, cfg, opts),
         {:ok, compacted} <- run_adapter(input, opts),
         {:ok, events} <- normalize_output(compacted),
         events <- add_marker(events),
         {:ok, count} <- SMEM.replace(events, cfg) do
      {:ok, %{events: events, count: count}}
    end
  end

  @spec build_input([map()], keyword(), keyword()) :: map()
  defp build_input(existing_events, cfg, opts) do
    moments = Focus.moments()

    # Adapters receive a bounded, domain-shaped input. They do not need to know
    # about ETS, SMEM files, or how budget settings are stored in app config.
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
      module
      |> apply(:compact, [input, opts])
      |> normalize_adapter_result()
    else
      {:error, {:invalid_compact_adapter, module}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec normalize_adapter_result(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_adapter_result({:ok, output}), do: {:ok, output}
  defp normalize_adapter_result({:error, reason}), do: {:error, reason}
  defp normalize_adapter_result(other), do: {:error, {:unexpected_compact_result, other}}

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
      |> Enum.map(&SMEM.normalize_event/1)
      |> Enum.filter(&(&1.type in [:skill, :procedure, :fact]))

    [
      [%{type: :summary, summary: summary, text: summary, metadata: %{strategy: :default}}],
      summaries,
      latest,
      existing_keep
    ]
    |> List.flatten()
    |> dedupe_events()
  end

  @spec normalize_output(term()) :: {:ok, [map()]} | {:error, term()}
  defp normalize_output({:ok, output}), do: normalize_output(output)
  defp normalize_output({:error, reason}), do: {:error, reason}
  defp normalize_output(output) when is_list(output), do: {:ok, normalize_events(output)}

  defp normalize_output(output) when is_map(output) do
    events =
      [
        events_from_output(output, :summary),
        events_from_output(output, :skill),
        events_from_output(output, :latest_ingestion),
        events_from_output(output, :fact),
        events_from_output(output, :procedure),
        events_from_output(output, :compaction_marker)
      ]
      |> List.flatten()

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
    |> Enum.map(&SMEM.normalize_event/1)
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

    List.flatten([events, [SMEM.normalize_event(marker)]])
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
      |> Enum.map(&SMEM.normalize_event/1)
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
