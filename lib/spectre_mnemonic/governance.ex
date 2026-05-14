defmodule SpectreMnemonic.Governance do
  @moduledoc """
  Lifecycle, provenance, and structured fact governance for durable memory.

  Governance is stored as append-only `:memory_states` records so existing
  memory structs stay backward compatible.
  """

  alias SpectreMnemonic.Persistence.Manager

  @states [:candidate, :short_term, :promoted, :pinned, :stale, :contradicted, :forgotten]
  @fact_attributes ~w(email phone age status birthday deadline owner)
  @default_stale_after_ms 30 * 24 * 60 * 60 * 1_000

  @type state ::
          :candidate | :short_term | :promoted | :pinned | :stale | :contradicted | :forgotten

  @doc "Returns known lifecycle states."
  @spec states :: [state()]
  def states, do: @states

  @doc "Merges a normalized provenance map into metadata."
  @spec with_provenance(map(), keyword()) :: map()
  def with_provenance(metadata, opts \\ []) when is_map(metadata) do
    provenance =
      metadata
      |> Map.get(:provenance, Map.get(metadata, "provenance", %{}))
      |> Map.new()
      |> Map.merge(provenance(opts))

    Map.put(metadata, :provenance, provenance)
  end

  @doc "Observes a persisted moment and writes state/fact governance events."
  @spec observe_moment(map(), keyword()) :: :ok
  def observe_moment(moment, opts \\ [])

  def observe_moment(%{id: id} = moment, opts) when is_binary(id) do
    state =
      normalize_state(Keyword.get(opts, :memory_state, Keyword.get(opts, :state, :short_term)))

    case fact_claim(moment) do
      nil ->
        append_state(id, state, :observed, opts, %{kind: Map.get(moment, :kind)})

      fact ->
        govern_fact(moment, fact, state, opts)
    end

    :ok
  end

  def observe_moment(_moment, _opts), do: :ok

  @doc "Writes promoted state events for consolidated moments."
  @spec promote_moments([map()], keyword()) :: :ok
  def promote_moments(moments, opts \\ []) do
    Enum.each(moments, fn
      %{id: id} = moment when is_binary(id) ->
        append_state(id, :promoted, :consolidated, opts, %{kind: Map.get(moment, :kind)})

      _other ->
        :ok
    end)
  end

  @doc "Writes forgotten state and tombstone events for a memory id."
  @spec forget(binary(), keyword()) :: :ok
  def forget(id, opts \\ []) when is_binary(id) do
    append_state(id, :forgotten, :forgotten, opts)
  end

  @doc "Returns the latest lifecycle state for one memory id."
  @spec state_for(binary(), keyword()) :: state() | nil
  def state_for(memory_id, opts \\ []) when is_binary(memory_id) do
    {:ok, records} = Manager.replay(opts)

    records
    |> Enum.filter(&(&1.family == :memory_states))
    |> Enum.map(& &1.payload)
    |> Enum.filter(&(&1.memory_id == memory_id))
    |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond), :desc)
    |> List.first()
    |> case do
      nil -> nil
      %{state: state} -> state
    end
  end

  @doc "Returns true when a memory should be visible in default search."
  @spec search_visible?(binary(), keyword()) :: boolean()
  def search_visible?(memory_id, opts \\ []) do
    state_for(memory_id, opts) not in [:forgotten, :contradicted]
  end

  @doc "Marks old unverified facts as stale unless pinned or already terminal."
  @spec decay(keyword()) :: {:ok, %{stale: non_neg_integer()}} | {:error, term()}
  def decay(opts \\ []) do
    stale_after_ms =
      opts
      |> Keyword.get(:stale_after_ms, Keyword.get(opts, :freshness_ms, @default_stale_after_ms))
      |> max(0)

    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -stale_after_ms, :millisecond)

    with {:ok, records} <- Manager.replay(opts) do
      states = memory_states(records)

      stale_count =
        records
        |> Enum.filter(&(&1.family == :memory_states))
        |> Enum.map(& &1.payload)
        |> Enum.filter(&fact_state?/1)
        |> Enum.uniq_by(& &1.memory_id)
        |> Enum.count(fn state ->
          should_stale?(state, states, cutoff)
        end)

      records
      |> Enum.filter(&(&1.family == :memory_states))
      |> Enum.map(& &1.payload)
      |> Enum.filter(&fact_state?/1)
      |> Enum.uniq_by(& &1.memory_id)
      |> Enum.filter(&should_stale?(&1, states, cutoff))
      |> Enum.each(fn state ->
        append_state(state.memory_id, :stale, :freshness_decay, opts, %{
          fact_key: state.metadata.fact_key,
          fact_value: state.metadata.fact_value
        })
      end)

      {:ok, %{stale: stale_count}}
    end
  end

  @doc "Builds a state event payload."
  @spec state_event(binary(), state(), atom(), keyword(), map()) :: map()
  def state_event(memory_id, state, reason, opts \\ [], metadata \\ %{}) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{
      id: Keyword.get(opts, :id) || id("mstate"),
      memory_id: memory_id,
      state: normalize_state(state),
      reason: reason,
      source_id: Keyword.get(opts, :source_id),
      metadata:
        metadata
        |> Map.new()
        |> with_provenance(
          source_ids: [memory_id],
          provider: :spectre_mnemonic,
          observed_at: now,
          last_verified_at: Keyword.get(opts, :last_verified_at)
        ),
      inserted_at: now
    }
  end

  @doc "Extracts a normalized entity fact claim from a memory-like map."
  @spec fact_claim(map()) :: map() | nil
  def fact_claim(%{metadata: metadata} = moment) when is_map(metadata) do
    from_extracted_value(moment) || from_text(moment)
  end

  def fact_claim(moment), do: from_text(moment)

  @spec append_state(binary(), state(), atom(), keyword(), map()) :: :ok
  def append_state(memory_id, state, reason, opts \\ [], metadata \\ %{}) do
    event = state_event(memory_id, state, reason, opts, metadata)

    case Manager.append(:memory_states, event, Keyword.put(opts, :record_id, event.id)) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec govern_fact(map(), map(), state(), keyword()) :: :ok
  defp govern_fact(moment, fact, state, opts) do
    current = current_fact(fact.key, opts)

    cond do
      current == nil ->
        append_fact_state(moment, state, :fact_observed, fact, opts)

      current.value == fact.value ->
        append_fact_state(moment, state, :fact_verified, fact, opts)

      current.state == :pinned ->
        append_fact_state(moment, :candidate, :conflicts_with_pinned_fact, fact, opts)

      true ->
        append_state(current.memory_id, :contradicted, :replaced_by_newer_fact, opts, %{
          fact_key: fact.key,
          fact_value: current.value,
          replaced_by: moment.id
        })

        append_fact_state(moment, :promoted, :fact_replaced_previous, fact, opts)
    end
  end

  @spec append_fact_state(map(), state(), atom(), map(), keyword()) :: :ok
  defp append_fact_state(moment, state, reason, fact, opts) do
    append_state(moment.id, state, reason, opts, %{
      kind: Map.get(moment, :kind),
      fact_key: fact.key,
      fact_subject: fact.subject,
      fact_attribute: fact.attribute,
      fact_value: fact.value,
      confidence: fact.confidence
    })
  end

  @spec current_fact(binary(), keyword()) :: map() | nil
  defp current_fact(key, opts) do
    {:ok, records} = Manager.replay(opts)

    records
    |> Enum.filter(&(&1.family == :memory_states))
    |> Enum.map(& &1.payload)
    |> Enum.filter(fn state ->
      get_in(state, [:metadata, :fact_key]) == key and
        state.state in [:promoted, :pinned, :short_term, :candidate]
    end)
    |> Enum.reject(fn state ->
      terminal_state?(state.memory_id, records)
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond), :desc)
    |> List.first()
    |> case do
      nil ->
        nil

      state ->
        %{
          memory_id: state.memory_id,
          state: state.state,
          value: get_in(state, [:metadata, :fact_value])
        }
    end
  end

  @spec terminal_state?(binary(), [map()]) :: boolean()
  defp terminal_state?(memory_id, records) do
    latest =
      records
      |> Enum.filter(&(&1.family == :memory_states))
      |> Enum.map(& &1.payload)
      |> Enum.filter(&(&1.memory_id == memory_id))
      |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond), :desc)
      |> List.first()

    match?(%{state: state} when state in [:contradicted, :forgotten], latest)
  end

  @spec memory_states([map()]) :: map()
  defp memory_states(records) do
    records
    |> Enum.filter(&(&1.family == :memory_states))
    |> Enum.map(& &1.payload)
    |> Enum.group_by(& &1.memory_id)
    |> Map.new(fn {memory_id, states} ->
      latest =
        Enum.max_by(states, &DateTime.to_unix(&1.inserted_at, :microsecond), fn -> nil end)

      {memory_id, latest}
    end)
  end

  @spec should_stale?(map(), map(), DateTime.t()) :: boolean()
  defp should_stale?(state, states, cutoff) do
    latest = Map.get(states, state.memory_id)
    last_verified = get_in(state, [:metadata, :provenance, :last_verified_at])
    observed = get_in(state, [:metadata, :provenance, :observed_at]) || state.inserted_at
    reference = last_verified || observed

    latest.state not in [:pinned, :stale, :contradicted, :forgotten] and
      match?(%DateTime{}, reference) and DateTime.compare(reference, cutoff) == :lt
  end

  @spec fact_state?(map()) :: boolean()
  defp fact_state?(%{metadata: %{fact_key: key}}) when is_binary(key), do: true
  defp fact_state?(_state), do: false

  @spec from_extracted_value(map()) :: map() | nil
  defp from_extracted_value(%{
         metadata: %{extraction_role: :value, entity: entity, value_kind: kind} = metadata
       })
       when not is_nil(entity) do
    value = Map.get(metadata, :value) || Map.get(metadata, :display)
    fact(entity, kind, value, Map.get(metadata, :confidence, 0.7))
  end

  defp from_extracted_value(_moment), do: nil

  @spec from_text(map()) :: map() | nil
  defp from_text(%{text: text}) when is_binary(text) do
    Enum.find_value(@fact_attributes, fn attribute ->
      pattern =
        ~r/\b(?<subject>[\p{L}\p{N}_'-]+)\s+#{attribute}\s+(?:is|=|:)\s+(?<value>[^;\n]+)/iu

      case Regex.named_captures(pattern, text) do
        %{"subject" => subject, "value" => value} ->
          fact(subject, attribute, String.trim_trailing(value, "."), 0.75)

        _missing ->
          nil
      end
    end)
  end

  defp from_text(_moment), do: nil

  @spec fact(term(), term(), term(), number()) :: map() | nil
  defp fact(_subject, _attribute, nil, _confidence), do: nil

  defp fact(subject, attribute, value, confidence) do
    subject = normalize_text(subject)
    attribute = normalize_text(attribute)
    value = normalize_text(value)

    if subject == "" or attribute == "" or value == "" do
      nil
    else
      %{
        key: "#{subject}:#{attribute}",
        subject: subject,
        attribute: attribute,
        value: value,
        confidence: confidence
      }
    end
  end

  @spec provenance(keyword()) :: map()
  defp provenance(opts) do
    now = Keyword.get(opts, :observed_at, Keyword.get(opts, :now, DateTime.utc_now()))

    %{
      source_ids: opts |> Keyword.get(:source_ids, []) |> List.wrap() |> Enum.reject(&is_nil/1),
      source_span: Keyword.get(opts, :source_span),
      provider: Keyword.get(opts, :provider, :spectre_mnemonic),
      confidence: Keyword.get(opts, :confidence),
      observed_at: now,
      last_verified_at: Keyword.get(opts, :last_verified_at, now)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  @spec normalize_state(term()) :: state()
  defp normalize_state(state) when state in @states, do: state

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.to_existing_atom()
    |> normalize_state()
  rescue
    _exception -> :short_term
  end

  defp normalize_state(_state), do: :short_term

  @spec normalize_text(term()) :: binary()
  defp normalize_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec id(binary()) :: binary()
  defp id(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
end
