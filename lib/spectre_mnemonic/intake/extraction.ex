defmodule SpectreMnemonic.Intake.Extraction do
  @moduledoc """
  Hybrid structured extraction for entity timeline memory.

  The deterministic path extracts language-neutral names, dates, email/number
  values, and simple actor/action/object events. Applications can configure an
  adapter for richer multilingual extraction without adding an LLM dependency to
  this library.
  """

  @email_regex ~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/iu
  @iso_date_regex ~r/\b\d{4}-\d{2}-\d{2}\b/u
  @phone_regex ~r/(?<![\w@])(?:\+\d{1,3}[\s.-]?)?(?:\d[\s.-]?){6,}\d(?![\w@])/u
  @number_regex ~r/(?<![\w@])\d+(?:[.,]\d+)?(?![\w@])/u
  @name_regex ~r/\b\p{Lu}[\p{L}\p{N}_'-]*\b/u
  @month_date_regex ~r/\b(\d{1,2})\s+(gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|janvier|février|fevrier|mars|avril|mai|juin|juillet|août|aout|septembre|octobre|novembre|décembre|decembre)\s+(\d{4})\b/iu

  @month_numbers %{
    "gennaio" => 1,
    "febbraio" => 2,
    "marzo" => 3,
    "aprile" => 4,
    "maggio" => 5,
    "giugno" => 6,
    "luglio" => 7,
    "agosto" => 8,
    "settembre" => 9,
    "ottobre" => 10,
    "novembre" => 11,
    "dicembre" => 12,
    "enero" => 1,
    "febrero" => 2,
    "abril" => 4,
    "mayo" => 5,
    "junio" => 6,
    "julio" => 7,
    "septiembre" => 9,
    "octubre" => 10,
    "diciembre" => 12,
    "janvier" => 1,
    "février" => 2,
    "fevrier" => 2,
    "mars" => 3,
    "avril" => 4,
    "mai" => 5,
    "juin" => 6,
    "juillet" => 7,
    "août" => 8,
    "aout" => 8,
    "septembre" => 9,
    "décembre" => 12,
    "decembre" => 12
  }

  @stop_entities MapSet.new(~w(
    A An And At Category Date Email Entity Event I Il La Le Les Los On The Time Value
  ))

  @doc "Extracts and normalizes a graph fragment from text."
  @spec extract(binary(), keyword()) :: {:ok, map()}
  def extract(text, opts \\ []) when is_binary(text) do
    deterministic = deterministic(text, opts)

    adapter =
      Keyword.get(opts, :entity_extraction_adapter) ||
        Application.get_env(:spectre_mnemonic, :entity_extraction_adapter)

    adapter_result = adapter_extract(adapter, text, opts)

    {:ok,
     deterministic
     |> merge(adapter_result)
     |> dedupe()}
  end

  @spec deterministic(binary(), keyword()) :: map()
  defp deterministic(text, opts) do
    sensitive_numbers = Keyword.get(opts, :sensitive_numbers, :classify)
    input = Keyword.get(opts, :input)

    entities = text_entities(text) ++ structured_entities(input)
    times = iso_times(text) ++ month_times(text) ++ structured_times(input)

    values =
      text_values(text, entities, sensitive_numbers) ++
        structured_values(input, sensitive_numbers)

    events = text_events(text, times)
    relations = inferred_relations(entities, events, times, values)

    %{
      entities: entities,
      events: events,
      times: times,
      values: values,
      relations: relations,
      metadata: %{provider: :deterministic}
    }
  end

  @spec adapter_extract(module() | nil, binary(), keyword()) :: map()
  defp adapter_extract(nil, _text, _opts), do: empty()

  defp adapter_extract(adapter, text, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :extract, 2) do
      adapter.extract(text, opts)
      |> case do
        {:ok, result} -> normalize(result, %{provider: adapter})
        {:error, reason} -> %{empty() | metadata: %{provider: adapter, error: reason}}
        result when is_map(result) -> normalize(result, %{provider: adapter})
        other -> %{empty() | metadata: %{provider: adapter, error: {:invalid_result, other}}}
      end
    else
      %{empty() | metadata: %{provider: adapter, error: :adapter_not_available}}
    end
  rescue
    exception -> %{empty() | metadata: %{provider: adapter, error: exception}}
  end

  @spec text_entities(binary()) :: [map()]
  defp text_entities(text) do
    @name_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reject(&MapSet.member?(@stop_entities, &1))
    |> Enum.map(&entity/1)
  end

  @spec structured_entities(term()) :: [map()]
  defp structured_entities(input) when is_map(input) do
    input
    |> flat_pairs()
    |> Enum.flat_map(fn {key, value} ->
      key = key_name(key)

      if key in ["name", "person", "entity", "actor"] and is_binary(value),
        do: [entity(value)],
        else: []
    end)
  end

  defp structured_entities(_input), do: []

  @spec iso_times(binary()) :: [map()]
  defp iso_times(text) do
    @iso_date_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(fn date ->
      time(date, date, :date)
    end)
  end

  @spec month_times(binary()) :: [map()]
  defp month_times(text) do
    Regex.scan(@month_date_regex, text, capture: :all_but_first)
    |> Enum.flat_map(fn [day, month_name, year] ->
      with {day, ""} <- Integer.parse(day),
           {year, ""} <- Integer.parse(year),
           month <- Map.get(@month_numbers, String.downcase(month_name)),
           true <- is_integer(month),
           {:ok, date} <- Date.new(year, month, day) do
        [time("#{day} #{month_name} #{year}", Date.to_iso8601(date), :date)]
      else
        _other -> []
      end
    end)
  end

  @spec structured_times(term()) :: [map()]
  defp structured_times(input) when is_map(input) do
    input
    |> flat_pairs()
    |> Enum.flat_map(fn {key, value} ->
      key = key_name(key)

      if key in ["date", "time", "when", "inserted_at"] and is_binary(value),
        do: [time(value, value, :date)],
        else: []
    end)
  end

  defp structured_times(_input), do: []

  @spec text_values(binary(), [map()], atom()) :: [map()]
  defp text_values(text, entities, sensitive_numbers) do
    phones = phone_values(text, entities, sensitive_numbers)
    emails = email_values(text, entities)
    ages = age_values(text)
    phone_exclusions = phone_exclusion_values(text)
    numbers = number_values(text, entities, phones ++ ages ++ phone_exclusions)

    phones ++ emails ++ ages ++ numbers
  end

  @spec phone_exclusion_values(binary()) :: [map()]
  defp phone_exclusion_values(text) do
    @phone_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.flat_map(fn raw ->
      [%{value: raw} | Enum.map(phone_number_fragments(raw), &%{value: &1})]
    end)
  end

  @spec phone_number_fragments(binary()) :: [binary()]
  defp phone_number_fragments(raw) do
    @number_regex
    |> Regex.scan(raw)
    |> List.flatten()
  end

  @spec phone_values(binary(), [map()], atom()) :: [map()]
  defp phone_values(_text, _entities, :skip), do: []

  defp phone_values(text, entities, sensitive_numbers) do
    entity_ref = single_entity_ref(entities)

    @phone_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(fn raw ->
      display = if sensitive_numbers == :raw, do: raw, else: "[redacted phone]"

      value(:phone, raw, display,
        sensitive?: true,
        raw_value?: sensitive_numbers == :raw,
        entity: nearby_entity(text, raw) || entity_ref
      )
    end)
  end

  @spec email_values(binary(), [map()]) :: [map()]
  defp email_values(text, entities) do
    entity_ref = single_entity_ref(entities)

    @email_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&value(:email, &1, &1, entity: entity_ref))
  end

  @spec age_values(binary()) :: [map()]
  defp age_values(text) do
    Regex.scan(
      ~r/\b(\p{Lu}[\p{L}\p{N}_'-]*)\b.{0,24}\b(?:is|age|aged|ha|tiene|età|eta|edad|âge|age)\s+(?:is\s+)?(\d{1,3})\b/iu,
      text,
      capture: :all_but_first
    )
    |> Enum.map(fn [name, age] ->
      value(:age, age, age, entity: entity_id(name), sensitive?: false)
    end)
  end

  @spec number_values(binary(), [map()], [map()]) :: [map()]
  defp number_values(text, entities, excluded_values) do
    excluded = MapSet.new(Enum.map(excluded_values, &Map.fetch!(&1, :value)))
    entity_ref = single_entity_ref(entities)

    @number_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reject(&(MapSet.member?(excluded, &1) or date_part?(text, &1)))
    |> Enum.map(&value(:number, &1, &1, entity: entity_ref))
  end

  @spec structured_values(term(), atom()) :: [map()]
  defp structured_values(input, sensitive_numbers) when is_map(input) do
    entity_ref =
      input
      |> structured_entities()
      |> single_entity_ref()

    input
    |> flat_pairs()
    |> Enum.flat_map(fn {key, value} ->
      key = key_name(key)

      cond do
        key in ["age", "count", "amount", "number"] ->
          [value(key, to_string(value), to_string(value), entity: entity_ref)]

        key in ["phone", "telephone", "mobile"] and sensitive_numbers != :skip ->
          [structured_phone_value(value, entity_ref, sensitive_numbers)]

        key == "email" ->
          [value(:email, to_string(value), to_string(value), entity: entity_ref)]

        true ->
          []
      end
    end)
  end

  defp structured_values(_input, _sensitive_numbers), do: []

  @spec structured_phone_value(term(), binary() | nil, atom()) :: map()
  defp structured_phone_value(value, entity_ref, sensitive_numbers) do
    raw = to_string(value)
    display = if sensitive_numbers == :raw, do: raw, else: "[redacted phone]"

    value(:phone, raw, display,
      sensitive?: true,
      raw_value?: sensitive_numbers == :raw,
      entity: entity_ref
    )
  end

  @spec text_events(binary(), [map()]) :: [map()]
  defp text_events(text, times) do
    event_patterns()
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text, capture: :all_but_first)
      |> Enum.map(fn captures ->
        event_from_captures(captures, text, times)
      end)
    end)
  end

  @spec event_patterns :: [Regex.t()]
  defp event_patterns do
    [
      ~r/\b(\p{Lu}[\p{L}\p{N}_'-]*)\s+(called|completed|did|bought|paid|met|visited|emailed|sent|received|fixed|implemented)\s+(\p{Lu}[\p{L}\p{N}_'-]*)?/u,
      ~r/\b(\p{Lu}[\p{L}\p{N}_'-]*)\s+(?:ha\s+)?(chiamato|completato|fatto|comprato|pagato|incontrato|visitato|inviato|ricevuto|sistemato|implementato)\s+(\p{Lu}[\p{L}\p{N}_'-]*)?/u
    ]
  end

  @spec event_from_captures([binary()], binary(), [map()]) :: map()
  defp event_from_captures([actor, action, object | _rest], text, times) do
    acted_on = if object == "", do: nil, else: entity_id(object)
    time_ref = times |> List.first() |> then(&(&1 && &1.id))

    %{
      id: local_id("event", "#{actor}:#{action}:#{object}:#{time_ref}"),
      text: event_text(actor, action, object),
      action: action,
      actor: entity_id(actor),
      acted_on: acted_on,
      time: time_ref,
      source_span: event_span(text, actor, action, object),
      language: :unknown,
      confidence: 0.62
    }
  end

  defp event_from_captures(_captures, _text, _times), do: %{}

  @spec inferred_relations([map()], [map()], [map()], [map()]) :: [map()]
  defp inferred_relations(entities, events, _times, values) do
    event_relations =
      Enum.flat_map(events, fn event ->
        [
          relation(event.id, :actor, event.actor, 1.0),
          relation(event.id, :acted_on, event.acted_on, 0.9),
          relation(event.id, :happened_at, event.time, 0.9)
        ]
      end)

    value_relations =
      values
      |> Enum.flat_map(fn value ->
        case Map.get(value, :entity) || single_entity_ref(entities) do
          nil -> []
          entity -> [relation(entity, :has_value, value.id, 0.9)]
        end
      end)

    event_relations ++ value_relations
  end

  @spec normalize(map(), map()) :: map()
  defp normalize(result, metadata) do
    %{
      entities: result |> get_list(:entities) |> Enum.map(&normalize_entity/1),
      events: result |> get_list(:events) |> Enum.map(&normalize_event/1),
      times: result |> get_list(:times) |> Enum.map(&normalize_time/1),
      values: result |> get_list(:values) |> Enum.map(&normalize_value/1),
      relations: result |> get_list(:relations) |> Enum.map(&normalize_relation/1),
      metadata: Map.merge(metadata, Map.new(get_value(result, :metadata, %{})))
    }
  end

  @spec normalize_entity(map()) :: map()
  defp normalize_entity(entity) do
    name = get_value(entity, :name) || get_value(entity, :canonical) || get_value(entity, :text)

    %{
      id: get_value(entity, :id) || entity_id(name),
      name: to_string(name),
      canonical: canonical(name),
      aliases: List.wrap(get_value(entity, :aliases, [])),
      type: label_value(get_value(entity, :type), "unknown"),
      language: label_value(get_value(entity, :language), "unknown"),
      confidence: number_value(get_value(entity, :confidence), 0.7)
    }
  end

  @spec normalize_time(map()) :: map()
  defp normalize_time(time) do
    text = get_value(time, :text) || get_value(time, :value)
    value = get_value(time, :value) || text

    %{
      id: get_value(time, :id) || local_id("time", value),
      text: to_string(text),
      value: to_string(value),
      kind: label_value(get_value(time, :kind), "date"),
      confidence: number_value(get_value(time, :confidence), 0.7)
    }
  end

  @spec normalize_value(map()) :: map()
  defp normalize_value(value) do
    raw = get_value(value, :value) || get_value(value, :text)
    kind = label_value(get_value(value, :kind), "number")

    %{
      id: get_value(value, :id) || local_id("value", "#{kind}:#{raw}"),
      text: to_string(get_value(value, :text) || raw),
      value: to_string(raw),
      display: to_string(get_value(value, :display) || raw),
      kind: kind,
      entity: get_value(value, :entity),
      sensitive?: boolean_value(get_value(value, :sensitive?), false),
      raw_value?: boolean_value(get_value(value, :raw_value?), true),
      confidence: number_value(get_value(value, :confidence), 0.7)
    }
  end

  @spec normalize_event(map()) :: map()
  defp normalize_event(event) do
    text = get_value(event, :text) || get_value(event, :action) || "event"

    %{
      id: get_value(event, :id) || local_id("event", text),
      text: to_string(text),
      action: get_value(event, :action),
      actor: get_value(event, :actor),
      acted_on: get_value(event, :acted_on),
      time: get_value(event, :time),
      values: List.wrap(get_value(event, :values, [])),
      source_span: get_value(event, :source_span),
      language: label_value(get_value(event, :language), "unknown"),
      confidence: number_value(get_value(event, :confidence), 0.7)
    }
  end

  @spec normalize_relation(map()) :: map()
  defp normalize_relation(relation) do
    %{
      source: get_value(relation, :source),
      relation: relation_value(get_value(relation, :relation)),
      target: get_value(relation, :target),
      weight: number_value(get_value(relation, :weight), 1.0),
      metadata: Map.new(get_value(relation, :metadata, %{}))
    }
  end

  @spec merge(map(), map()) :: map()
  defp merge(left, right) do
    %{
      entities: Map.get(left, :entities, []) ++ Map.get(right, :entities, []),
      events: Map.get(left, :events, []) ++ Map.get(right, :events, []),
      times: Map.get(left, :times, []) ++ Map.get(right, :times, []),
      values: Map.get(left, :values, []) ++ Map.get(right, :values, []),
      relations: Map.get(left, :relations, []) ++ Map.get(right, :relations, []),
      metadata: Map.merge(Map.get(left, :metadata, %{}), Map.get(right, :metadata, %{}))
    }
  end

  @spec dedupe(map()) :: map()
  defp dedupe(graph) do
    %{
      graph
      | entities: Enum.uniq_by(graph.entities, & &1.canonical),
        events: graph.events |> Enum.reject(&(&1 == %{})) |> Enum.uniq_by(& &1.id),
        times: Enum.uniq_by(graph.times, & &1.value),
        values: Enum.uniq_by(graph.values, &{&1.kind, &1.value, &1.entity}),
        relations:
          graph.relations
          |> Enum.reject(&(is_nil(&1.source) or is_nil(&1.target)))
          |> Enum.uniq_by(&{&1.source, &1.relation, &1.target})
    }
  end

  @spec empty :: map()
  defp empty do
    %{entities: [], events: [], times: [], values: [], relations: [], metadata: %{}}
  end

  @spec entity(binary()) :: map()
  defp entity(name) do
    %{
      id: entity_id(name),
      name: name,
      canonical: canonical(name),
      aliases: [],
      type: :unknown,
      language: :unknown,
      confidence: 0.55
    }
  end

  @spec entity_id(term()) :: binary() | nil
  defp entity_id(nil), do: nil
  defp entity_id(name), do: local_id("entity", canonical(name))

  @spec time(binary(), binary(), atom() | binary()) :: map()
  defp time(text, value, kind) do
    %{
      id: local_id("time", value),
      text: text,
      value: value,
      kind: label_value(kind, "date"),
      confidence: 0.72
    }
  end

  @spec value(atom() | binary(), binary(), binary(), keyword()) :: map()
  defp value(kind, raw, display, opts) do
    kind = label_value(kind, "number")

    %{
      id: local_id("value", "#{kind}:#{raw}:#{Keyword.get(opts, :entity)}"),
      text: display,
      value: raw,
      display: display,
      kind: kind,
      entity: Keyword.get(opts, :entity),
      sensitive?: Keyword.get(opts, :sensitive?, false),
      raw_value?: Keyword.get(opts, :raw_value?, true),
      confidence: Keyword.get(opts, :confidence, 0.65)
    }
  end

  @spec relation(term(), atom(), term(), number()) :: map()
  defp relation(_source, _relation, nil, _weight), do: %{source: nil, target: nil}

  defp relation(source, relation, target, weight) do
    %{source: source, relation: relation, target: target, weight: weight, metadata: %{}}
  end

  @spec local_id(binary(), term()) :: binary()
  defp local_id(prefix, value) do
    hash =
      value
      |> to_string()
      |> String.downcase()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{prefix}:#{hash}"
  end

  @spec canonical(term()) :: binary()
  defp canonical(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec nearby_entity(binary(), binary()) :: binary() | nil
  defp nearby_entity(text, raw) do
    case String.split(text, raw, parts: 2) do
      [before, _after] ->
        before
        |> String.slice(-40, 40)
        |> text_entities()
        |> List.last()
        |> case do
          nil -> nil
          entity -> entity.id
        end

      _other ->
        nil
    end
  end

  @spec single_entity_ref([map()]) :: binary() | nil
  defp single_entity_ref([entity]), do: entity.id
  defp single_entity_ref(_entities), do: nil

  @spec date_part?(binary(), binary()) :: boolean()
  defp date_part?(text, number) do
    String.contains?(text, "#{number}-") or String.contains?(text, "-#{number}") or
      Regex.match?(~r/\b#{Regex.escape(number)}\s+\p{L}+\s+\d{4}\b/u, text)
  end

  @spec event_text(binary(), binary(), binary()) :: binary()
  defp event_text(actor, action, ""), do: "#{actor} #{action}"
  defp event_text(actor, action, object), do: "#{actor} #{action} #{object}"

  @spec event_span(binary(), binary(), binary(), binary()) :: binary()
  defp event_span(text, actor, action, object) do
    phrase = event_text(actor, action, object)

    if String.contains?(text, phrase), do: phrase, else: "#{actor} #{action}"
  end

  @spec flat_pairs(map()) :: [{term(), term()}]
  defp flat_pairs(map) when is_map(map) do
    Enum.flat_map(map, fn
      {_key, nested} when is_map(nested) -> flat_pairs(nested)
      pair -> [pair]
    end)
  end

  @spec key_name(term()) :: binary()
  defp key_name(key), do: key |> to_string() |> String.downcase()

  @spec get_list(map(), atom()) :: [map()]
  defp get_list(map, key) do
    map
    |> get_value(key, [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  @spec get_value(map(), atom(), term()) :: term()
  defp get_value(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  @spec label_value(term(), binary()) :: binary()
  defp label_value(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp label_value(value, _default) when is_binary(value), do: value
  defp label_value(_value, default), do: default

  @spec relation_value(term()) :: atom()
  defp relation_value(value) when is_atom(value), do: allowed_relation(value)

  defp relation_value(value) when is_binary(value),
    do: value |> String.trim() |> allowed_relation()

  defp relation_value(_value), do: :related_to

  @spec allowed_relation(atom() | binary()) :: atom()
  defp allowed_relation(:actor), do: :actor
  defp allowed_relation("actor"), do: :actor
  defp allowed_relation(:acted_on), do: :acted_on
  defp allowed_relation("acted_on"), do: :acted_on
  defp allowed_relation(:happened_at), do: :happened_at
  defp allowed_relation("happened_at"), do: :happened_at
  defp allowed_relation(:has_value), do: :has_value
  defp allowed_relation("has_value"), do: :has_value
  defp allowed_relation(:mentions_entity), do: :mentions_entity
  defp allowed_relation("mentions_entity"), do: :mentions_entity
  defp allowed_relation(:observed_in), do: :observed_in
  defp allowed_relation("observed_in"), do: :observed_in
  defp allowed_relation(:same_entity), do: :same_entity
  defp allowed_relation("same_entity"), do: :same_entity
  defp allowed_relation(:related_to), do: :related_to
  defp allowed_relation("related_to"), do: :related_to
  defp allowed_relation(_value), do: :related_to

  @spec number_value(term(), number()) :: number()
  defp number_value(value, _default) when is_number(value), do: value
  defp number_value(_value, default), do: default

  @spec boolean_value(term(), boolean()) :: boolean()
  defp boolean_value(value, _default) when is_boolean(value), do: value
  defp boolean_value(_value, default), do: default
end
