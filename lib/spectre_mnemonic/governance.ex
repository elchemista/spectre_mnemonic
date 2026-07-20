defmodule SpectreMnemonic.Governance do
  @moduledoc """
  Materialized, scoped lifecycle governance for memory.

  Lifecycle changes remain append-only in persistent memory, while this process
  owns a rebuildable ETS projection. All transitions pass through one explicit
  state machine; terminal or pinned memories therefore cannot be silently
  promoted by a later consolidation run.
  """

  use GenServer

  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Manager

  @state_table :mnemonic_governance_states
  @fact_table :mnemonic_governance_facts
  @states [:candidate, :short_term, :promoted, :pinned, :stale, :contradicted, :forgotten]
  @terminal_states [:contradicted, :forgotten]
  @fact_attributes ~w(email phone age status birthday deadline owner)
  @default_stale_after_ms 30 * 24 * 60 * 60 * 1_000
  @repeatable_reasons [:fact_verified, :observation_verified, :manual_verification]

  @transitions %{
    candidate: [:short_term, :promoted, :pinned, :stale, :contradicted, :forgotten],
    short_term: [:promoted, :pinned, :stale, :contradicted, :forgotten],
    promoted: [:pinned, :stale, :contradicted, :forgotten],
    pinned: [:forgotten],
    stale: [:promoted, :pinned, :contradicted, :forgotten],
    contradicted: [:forgotten],
    forgotten: []
  }

  @type state ::
          :candidate | :short_term | :promoted | :pinned | :stale | :contradicted | :forgotten

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns known lifecycle states."
  @spec states() :: [state()]
  def states, do: @states

  @doc "Merges normalized provenance into metadata."
  @spec with_provenance(map(), keyword()) :: map()
  def with_provenance(metadata, opts \\ []) when is_map(metadata) do
    provenance =
      metadata
      |> Map.get(:provenance, Map.get(metadata, "provenance", %{}))
      |> Map.new()
      |> Map.merge(provenance(opts))

    Map.put(metadata, :provenance, provenance)
  end

  @doc "Observes a persisted moment and writes scoped state/fact governance."
  @spec observe_moment(map(), keyword()) :: :ok | {:error, term()}
  def observe_moment(moment, opts \\ [])

  def observe_moment(%{id: id} = moment, opts) when is_binary(id) do
    opts = context_opts(moment, opts)

    state =
      normalize_state(Keyword.get(opts, :memory_state, Keyword.get(opts, :state, :short_term)))

    case fact_claim(moment) do
      nil -> append_state(id, state, :observed, opts, %{kind: Map.get(moment, :kind)})
      fact -> govern_fact(moment, fact, state, opts)
    end
  end

  def observe_moment(_moment, _opts), do: :ok

  @doc "Promotes only memories whose current state allows promotion."
  @spec promote_moments([map()], keyword()) :: :ok | {:error, term()}
  def promote_moments(moments, opts \\ []) do
    Enum.reduce_while(moments, :ok, fn
      %{id: id} = moment, :ok when is_binary(id) ->
        event_opts = context_opts(moment, opts)

        case append_state(id, :promoted, :consolidated, event_opts, %{
               kind: Map.get(moment, :kind)
             }) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, :ok ->
        {:cont, :ok}
    end)
  end

  @doc "Returns whether consolidation may promote a memory in its scoped lifecycle."
  @spec consolidatable?(map(), keyword()) :: boolean()
  def consolidatable?(memory, opts \\ []) do
    opts = context_opts(memory, opts)
    state_for(Map.get(memory, :id), opts) in [nil, :candidate, :short_term, :stale]
  end

  @doc "Writes a durable forgotten transition."
  @spec forget(binary(), keyword()) :: :ok | {:error, term()}
  def forget(id, opts \\ []) when is_binary(id),
    do: append_state(id, :forgotten, :forgotten, opts)

  @doc "Reads the materialized lifecycle state for a namespace/scope/id key."
  @spec state_for(binary() | nil, keyword()) :: state() | nil
  def state_for(memory_id, opts \\ [])

  def state_for(nil, _opts), do: nil

  def state_for(memory_id, opts) when is_binary(memory_id) do
    case Identity.fetch_namespace(opts) do
      {:ok, namespace} ->
        key = {namespace, Keyword.get(opts, :scope), memory_id}

        case safe_lookup(@state_table, key) do
          [{^key, event}] -> event.state
          [] -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  @doc "Returns true unless the scoped lifecycle is contradicted or forgotten."
  @spec search_visible?(binary(), keyword()) :: boolean()
  def search_visible?(memory_id, opts \\ []),
    do: state_for(memory_id, opts) not in @terminal_states

  @doc "Marks old verified facts stale without mutating their payloads."
  @spec decay(keyword()) :: {:ok, %{stale: non_neg_integer()}} | {:error, term()}
  def decay(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      do_decay(opts)
    end
  end

  @spec do_decay(keyword()) :: {:ok, %{stale: non_neg_integer()}} | {:error, term()}
  defp do_decay(opts) do
    stale_after_ms =
      opts
      |> Keyword.get(:stale_after_ms, Keyword.get(opts, :freshness_ms, @default_stale_after_ms))
      |> max(0)

    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -stale_after_ms, :millisecond)

    candidates =
      @state_table
      |> safe_tab2list()
      |> Enum.map(fn {_key, event} -> event end)
      |> Enum.filter(fn event ->
        Scope.match?(event, opts) and fact_state?(event) and should_stale?(event, cutoff)
      end)

    result =
      Enum.reduce_while(candidates, :ok, fn event, :ok ->
        event_opts = [namespace: event.namespace, scope: event.scope, now: now]

        case append_state(event.memory_id, :stale, :freshness_decay, event_opts, %{
               fact_key: event.metadata.fact_key,
               fact_value: event.metadata.fact_value
             }) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok -> {:ok, %{stale: length(candidates)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Builds a namespaced lifecycle event payload."
  @spec state_event(binary(), state(), atom(), keyword(), map()) :: map()
  def state_event(memory_id, state, reason, opts \\ [], metadata \\ %{}) do
    namespace = Identity.namespace!(opts)
    scope = Keyword.get(opts, :scope)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{
      id: Keyword.get(opts, :id) || Identity.generate("mstate", opts),
      namespace: namespace,
      scope: scope,
      memory_id: memory_id,
      state: normalize_state(state),
      reason: reason,
      source_id: Keyword.get(opts, :source_id),
      metadata:
        metadata
        |> Map.new()
        |> Identity.put_context(Keyword.put(opts, :scope, scope))
        |> with_provenance(
          source_ids: [memory_id],
          provider: :spectre_mnemonic,
          observed_at: now,
          last_verified_at: Keyword.get(opts, :last_verified_at)
        ),
      inserted_at: now
    }
  end

  @doc "Persists one valid transition and updates its materialized projection."
  @spec append_state(binary(), state(), atom(), keyword(), map()) :: :ok | {:error, term()}
  def append_state(memory_id, state, reason, opts \\ [], metadata \\ %{}) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      GenServer.call(__MODULE__, {:append_state, memory_id, state, reason, opts, metadata})
    end
  end

  @doc "Extracts a normalized entity fact claim from a memory-like map."
  @spec fact_claim(map()) :: map() | nil
  def fact_claim(%{metadata: metadata} = moment) when is_map(metadata),
    do: from_extracted_value(moment) || from_text(moment)

  def fact_claim(moment), do: from_text(moment)

  @impl GenServer
  def init(_opts) do
    case rebuild_materialized() do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:append_state, memory_id, state, reason, opts, metadata}, _from, server_state) do
    target = normalize_state(state)
    current = current_event(memory_id, opts)

    reply =
      cond do
        repeated_noop?(current, target, reason) ->
          :ok

        valid_transition?(current, target) ->
          event =
            state_event(
              memory_id,
              target,
              reason,
              opts,
              transition_metadata(current, metadata)
            )

          case Manager.append(
                 :memory_states,
                 event,
                 opts
                 |> Keyword.put(:record_id, event.id)
                 |> Keyword.put(:scope, event.scope)
               ) do
            {:ok, _result} ->
              materialize(event)
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          {:error, {:invalid_memory_transition, current_state(current), target}}
      end

    {:reply, reply, server_state}
  end

  @spec rebuild_materialized() :: :ok | {:error, term()}
  defp rebuild_materialized do
    :ets.delete_all_objects(@state_table)
    :ets.delete_all_objects(@fact_table)

    case Manager.replay_all() do
      {:ok, records} ->
        records
        |> Enum.filter(&(&1.family == :memory_states))
        |> Enum.map(& &1.payload)
        |> Enum.filter(&is_map/1)
        |> Enum.sort_by(&event_timestamp/1)
        |> Enum.each(&materialize_if_valid/1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec materialize_if_valid(map()) :: :ok
  defp materialize_if_valid(event) do
    opts = [namespace: Map.get(event, :namespace), scope: Map.get(event, :scope)]
    current = current_event(Map.get(event, :memory_id), opts)

    if valid_transition?(current, Map.get(event, :state)) or current_state(current) == event.state do
      materialize(event)
    end

    :ok
  end

  @spec materialize(map()) :: :ok
  defp materialize(event) do
    key = state_key(event.namespace, event.scope, event.memory_id)
    :ets.insert(@state_table, {key, event})
    materialize_fact(event)
    :ok
  end

  @spec materialize_fact(map()) :: :ok
  defp materialize_fact(%{metadata: %{fact_key: fact_key}} = event) when is_binary(fact_key) do
    key = {event.namespace, event.scope, fact_key}

    cond do
      event.state in @terminal_states ->
        case safe_lookup(@fact_table, key) do
          [{^key, %{memory_id: memory_id}}] when memory_id == event.memory_id ->
            :ets.delete(@fact_table, key)

          _other ->
            :ok
        end

      event.reason == :conflicts_with_pinned_fact ->
        :ok

      true ->
        :ets.insert(@fact_table, {key, event})
    end

    :ok
  end

  defp materialize_fact(_event), do: :ok

  @spec transition_metadata(map() | nil, map()) :: map()
  defp transition_metadata(nil, metadata), do: Map.new(metadata)

  defp transition_metadata(current, metadata) do
    current
    |> Map.get(:metadata, %{})
    |> Map.merge(Map.new(metadata))
  end

  @spec govern_fact(map(), map(), state(), keyword()) :: :ok | {:error, term()}
  defp govern_fact(moment, fact, state, opts) do
    current = current_fact(fact.key, opts)

    cond do
      current == nil ->
        append_fact_state(moment, state, :fact_observed, fact, opts)

      fact_value(current) == fact.value ->
        append_fact_state(moment, state, :fact_verified, fact, opts)

      current.state == :pinned ->
        append_fact_state(moment, :candidate, :conflicts_with_pinned_fact, fact, opts)

      true ->
        with :ok <-
               append_state(current.memory_id, :contradicted, :replaced_by_newer_fact, opts, %{
                 fact_key: fact.key,
                 fact_value: fact_value(current),
                 replaced_by: moment.id
               }) do
          append_fact_state(moment, :promoted, :fact_replaced_previous, fact, opts)
        end
    end
  end

  @spec append_fact_state(map(), state(), atom(), map(), keyword()) :: :ok | {:error, term()}
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
  defp current_fact(fact_key, opts) do
    namespace = Identity.namespace!(opts)
    key = {namespace, Keyword.get(opts, :scope), fact_key}

    case safe_lookup(@fact_table, key) do
      [{^key, event}] -> event
      [] -> nil
    end
  end

  @spec current_event(binary() | nil, keyword()) :: map() | nil
  defp current_event(nil, _opts), do: nil

  defp current_event(memory_id, opts) do
    key = state_key(Identity.namespace!(opts), Keyword.get(opts, :scope), memory_id)

    case safe_lookup(@state_table, key) do
      [{^key, event}] -> event
      [] -> nil
    end
  end

  @spec state_key(binary(), term(), binary()) :: tuple()
  defp state_key(namespace, scope, memory_id), do: {namespace, scope, memory_id}

  @spec valid_transition?(map() | nil, state()) :: boolean()
  defp valid_transition?(nil, target), do: target in @states

  defp valid_transition?(current, target) do
    current.state == target or target in Map.fetch!(@transitions, current.state)
  end

  @spec repeated_noop?(map() | nil, state(), atom()) :: boolean()
  defp repeated_noop?(nil, _target, _reason), do: false

  defp repeated_noop?(current, target, reason),
    do: current.state == target and reason not in @repeatable_reasons

  @spec current_state(map() | nil) :: state() | nil
  defp current_state(nil), do: nil
  defp current_state(event), do: event.state

  @spec fact_value(map()) :: term()
  defp fact_value(event), do: get_in(event, [:metadata, :fact_value])

  @spec context_opts(map(), keyword()) :: keyword()
  defp context_opts(memory, opts) do
    namespace = Identity.namespace(memory) || Identity.namespace!(opts)

    scope =
      cond do
        is_map(memory) and Map.has_key?(memory, :scope) -> Map.get(memory, :scope)
        is_map(memory) and Map.has_key?(memory, "scope") -> Map.get(memory, "scope")
        true -> Scope.scope(memory) || Keyword.get(opts, :scope)
      end

    opts
    |> Keyword.put(:namespace, namespace)
    |> Keyword.put(:scope, scope)
  end

  @spec should_stale?(map(), DateTime.t()) :: boolean()
  defp should_stale?(event, cutoff) do
    last_verified = get_in(event, [:metadata, :provenance, :last_verified_at])
    observed = get_in(event, [:metadata, :provenance, :observed_at]) || event.inserted_at
    reference = last_verified || observed

    event.state not in [:pinned, :stale, :contradicted, :forgotten] and
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
      occurred_at: Keyword.get(opts, :occurred_at),
      observed_at: now,
      last_verified_at: Keyword.get(opts, :last_verified_at, now),
      valid_from: Keyword.get(opts, :valid_from),
      valid_until: Keyword.get(opts, :valid_until)
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
  defp normalize_text(value), do: value |> to_string() |> String.trim() |> String.downcase()

  @spec event_timestamp(map()) :: integer()
  defp event_timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp event_timestamp(_event), do: 0

  @spec safe_lookup(atom(), term()) :: list()
  defp safe_lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  @spec safe_tab2list(atom()) :: list()
  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
