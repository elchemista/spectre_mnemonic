defmodule SpectreMnemonic.Knowledge.Base do
  @moduledoc """
  Budgeted progressive knowledge loader backed by `knowledge.smem`.
  """

  alias SpectreMnemonic.Knowledge.Record
  alias SpectreMnemonic.Knowledge.SMEM

  @default_config [
    enabled: true,
    max_loaded_bytes: 16_000,
    max_latest_ingestions: 20,
    max_skills: 20,
    max_facts: 20,
    max_procedures: 20
  ]

  @priority %{
    summary: 100,
    skill: 90,
    procedure: 80,
    fact: 70,
    latest_ingestion: 60,
    compaction_marker: 10
  }

  @doc "Returns the effective knowledge config."
  @spec config(keyword()) :: keyword()
  def config(opts \\ []) do
    configured = Application.get_env(:spectre_mnemonic, :knowledge, [])

    @default_config
    |> Keyword.merge(configured)
    |> Keyword.merge(Keyword.get(opts, :knowledge, []))
    |> Keyword.merge(Keyword.take(opts, Keyword.keys(@default_config) ++ [:data_root]))
  end

  @doc "Appends one compact knowledge event."
  @spec append(map(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def append(event, opts \\ []), do: SMEM.append(event, opts)

  @doc "Replays compact knowledge events."
  @spec events(keyword()) :: {:ok, [map()]}
  def events(opts \\ []), do: SMEM.replay(opts)

  @doc "Loads a compact, budgeted knowledge packet."
  @spec load(keyword()) :: {:ok, Record.t()}
  def load(opts \\ []) do
    cfg = config(opts)

    if Keyword.get(cfg, :enabled, true) do
      {:ok, events} = SMEM.replay(cfg)
      {:ok, build_packet(events, cfg)}
    else
      {:ok, empty_packet(%{disabled?: true})}
    end
  end

  @doc "Searches `knowledge.smem` without loading a full knowledge packet."
  @spec search(term(), keyword()) :: {:ok, [map()]}
  def search(cue, opts \\ []) do
    cfg = config(opts)

    if Keyword.get(cfg, :enabled, true) do
      {:ok, events} = SMEM.replay(cfg)
      limit = Keyword.get(opts, :limit, 10)
      query = cue_text(cue)
      query_terms = query |> terms() |> MapSet.new()

      results =
        events
        |> Enum.map(&SMEM.normalize_event/1)
        |> Enum.map(&score_event(&1, query_terms, query))
        |> Enum.filter(&(&1.score > 0))
        |> Enum.sort_by(fn result ->
          {-result.score, -timestamp(result.event), result.event.id}
        end)
        |> Enum.take(limit)

      {:ok, results}
    else
      {:ok, []}
    end
  end

  @doc "Builds a packet from already-loaded events."
  @spec build_packet([map()], keyword()) :: Record.t()
  def build_packet(events, cfg \\ []) do
    cfg = config(cfg)
    max_bytes = Keyword.fetch!(cfg, :max_loaded_bytes)

    events =
      events
      |> Enum.map(&SMEM.normalize_event/1)
      |> rank_events()

    {summary, used_bytes} = select_summary(events, max_bytes)
    remaining = max(max_bytes - used_bytes, 0)

    selected =
      [:skill, :procedure, :fact, :latest_ingestion]
      |> Enum.reduce(%{bytes: used_bytes, events: %{}}, fn type, acc ->
        limit = limit_for(type, cfg)
        candidates = Enum.filter(events, &(&1.type == type))

        {items, bytes} =
          take_budgeted(candidates, limit, max(remaining - (acc.bytes - used_bytes), 0))

        %{acc | bytes: acc.bytes + bytes, events: Map.put(acc.events, type, items)}
      end)

    %Record{
      id: "knowledge_loaded",
      source_id: "knowledge.smem",
      text: summary || "",
      summary: summary,
      skills: Map.get(selected.events, :skill, []),
      procedures: Map.get(selected.events, :procedure, []),
      facts: Map.get(selected.events, :fact, []),
      latest_ingestions: Map.get(selected.events, :latest_ingestion, []),
      usage: usage(events),
      metadata: %{
        source: :knowledge_smem,
        loaded_events: length(events),
        loaded_bytes: selected.bytes,
        max_loaded_bytes: max_bytes
      },
      inserted_at: DateTime.utc_now()
    }
  end

  @spec empty_packet(map()) :: Record.t()
  defp empty_packet(metadata) do
    %Record{
      id: "knowledge_empty",
      source_id: "knowledge.smem",
      text: "",
      summary: nil,
      metadata: Map.merge(%{source: :knowledge_smem}, metadata),
      inserted_at: DateTime.utc_now()
    }
  end

  @spec rank_events([map()]) :: [map()]
  defp rank_events(events) do
    Enum.sort_by(events, fn event ->
      {-priority(event), -usage_count(event), -attention(event), -timestamp(event), event.id}
    end)
  end

  @spec select_summary([map()], non_neg_integer()) :: {binary() | nil, non_neg_integer()}
  defp select_summary(events, max_bytes) do
    events
    |> Enum.filter(&(&1.type == :summary))
    |> take_budgeted(1, max_bytes)
    |> case do
      {[], _bytes} -> {nil, 0}
      {[event], bytes} -> {event.summary || event.text, bytes}
    end
  end

  @spec take_budgeted([map()], non_neg_integer(), non_neg_integer()) ::
          {[map()], non_neg_integer()}
  defp take_budgeted(events, limit, budget) do
    events
    |> Enum.reduce_while({[], 0, 0}, fn event, {acc, used, count} ->
      encoded = :erlang.term_to_binary(event)
      size = byte_size(encoded)

      cond do
        count >= limit ->
          {:halt, {acc, used, count}}

        used + size > budget ->
          {:halt, {acc, used, count}}

        true ->
          {:cont, {[event | acc], used + size, count + 1}}
      end
    end)
    |> then(fn {selected, used, _count} -> {Enum.reverse(selected), used} end)
  end

  @spec limit_for(atom(), keyword()) :: non_neg_integer()
  defp limit_for(:skill, cfg), do: Keyword.fetch!(cfg, :max_skills)
  defp limit_for(:latest_ingestion, cfg), do: Keyword.fetch!(cfg, :max_latest_ingestions)
  defp limit_for(:fact, cfg), do: Keyword.fetch!(cfg, :max_facts)
  defp limit_for(:procedure, cfg), do: Keyword.fetch!(cfg, :max_procedures)
  defp limit_for(_type, _cfg), do: 0

  @spec priority(map()) :: integer()
  defp priority(event), do: Map.get(@priority, event.type, 0)

  @spec usage_count(map()) :: non_neg_integer()
  defp usage_count(%{usage: %{count: count}}) when is_integer(count), do: max(count, 0)
  defp usage_count(%{usage: %{"count" => count}}) when is_integer(count), do: max(count, 0)
  defp usage_count(_event), do: 0

  @spec attention(map()) :: number()
  defp attention(%{metadata: %{attention: attention}}) when is_number(attention), do: attention

  defp attention(%{metadata: %{"attention" => attention}}) when is_number(attention),
    do: attention

  defp attention(%{metadata: %{confidence: confidence}}) when is_number(confidence),
    do: confidence

  defp attention(%{metadata: %{"confidence" => confidence}}) when is_number(confidence),
    do: confidence

  defp attention(_event), do: 0

  @spec timestamp(map()) :: integer()
  defp timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp timestamp(_event), do: 0

  @spec usage([map()]) :: map()
  defp usage(events) do
    %{
      total_events: length(events),
      used_events: Enum.count(events, &(usage_count(&1) > 0))
    }
  end

  @spec score_event(map(), MapSet.t(binary()), binary()) :: map()
  defp score_event(event, query_terms, query) do
    text = event_text(event)
    event_terms = text |> terms() |> MapSet.new()
    overlap = MapSet.size(MapSet.intersection(query_terms, event_terms))

    phrase_bonus =
      if query != "" and String.contains?(String.downcase(text), query), do: 4, else: 0

    type_bonus = div(priority(event), 25)
    usage_bonus = min(usage_count(event), 5)
    attention_bonus = event |> attention() |> min(5) |> trunc()
    score = overlap * 3 + phrase_bonus + type_bonus + usage_bonus + attention_bonus

    %{
      source: :knowledge_smem,
      family: :knowledge,
      id: event.id,
      type: event.type,
      score: score,
      event: event,
      text: text
    }
  end

  @spec event_text(map()) :: binary()
  defp event_text(event) do
    [
      event.summary,
      event.name,
      event.text,
      inspect(event.steps, limit: 20),
      inspect(event.value, limit: 20),
      inspect(event.metadata, limit: 20)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  @spec cue_text(term()) :: binary()
  defp cue_text(cue) when is_binary(cue), do: String.downcase(String.trim(cue))
  defp cue_text(cue), do: cue |> inspect(limit: 50) |> cue_text()

  @spec terms(binary()) :: [binary()]
  defp terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end
end
