defmodule SpectreMnemonic.Knowledge.Consolidator do
  @moduledoc """
  Moves selected active focus into durable memory records.

  Spectre Mnemonic is not a database of everything.
  Spectre Mnemonic is a living focus that slowly becomes organized memory.

  Consolidation is the promotion step between hot active memory and durable
  knowledge. The default strategy selects moments above an attention threshold,
  expands them with nearby graph context, builds knowledge records, persists the
  requested durable outputs, and marks source moments as promoted.

  Custom logic can be injected per call with `:consolidate_with` or configured
  globally with `:consolidation_adapter`. Both receive a
  `%SpectreMnemonic.Knowledge.Consolidation{}` struct that already contains
  selected moments, associations, graph windows, timestamps, opts, and default
  durable outputs.
  """

  use GenServer

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Knowledge.Consolidation
  alias SpectreMnemonic.Knowledge.Record
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.Manager

  @tombstone_keys ~w(family id forgotten_at reason)a
  @tombstone_key_by_string Map.new(@tombstone_keys, &{Atom.to_string(&1), &1})

  @doc "Starts the consolidator process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Consolidates active memory into persistent records.

  Pass `:consolidate_with` with a one- or two-arity function for runtime
  experiments, or configure `:consolidation_adapter` for application-level
  promotion logic. Both receive a `%SpectreMnemonic.Knowledge.Consolidation{}`
  with graph windows and default durable outputs already populated.

  Useful options:

    * `:min_attention` - select source moments with at least this attention.
    * `:graph_depth` - include associations around selected moments.
    * `:consolidate_with` - one- or two-arity function for custom promotion.
    * `:consolidation_adapter` - module implementing the adapter behaviour.
    * `:timeout` - GenServer call timeout in milliseconds.

  ## Examples

      iex> SpectreMnemonic.Knowledge.Consolidator.consolidate(min_attention: 1.5)
      {:ok, [%SpectreMnemonic.Knowledge.Record{} | _]}

      iex> fun = fn context ->
      ...>   {:ok, %{context | strategy: :custom, warnings: [:inspected]}}
      ...> end
      iex> SpectreMnemonic.Knowledge.Consolidator.consolidate(consolidate_with: fun)
      {:ok, _records}
  """
  @spec consolidate(keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def consolidate(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:consolidate, opts}, timeout)
  end

  @impl GenServer
  @spec init(map()) :: {:ok, map()}
  def init(state), do: {:ok, state}

  @impl GenServer
  @spec handle_call({:consolidate, keyword()}, GenServer.from(), map()) ::
          {:reply, {:ok, [Record.t()]} | {:error, term()}, map()}
  def handle_call({:consolidate, opts}, _from, state) do
    min_attention = Keyword.get(opts, :min_attention, 1.0)
    now = DateTime.utc_now()
    active_moments = Focus.moments()
    associations = Focus.associations()

    # Build the boring default first, then let custom policy edit it. I picked
    # this path after seeing adapters rebuild half the runtime just to say
    # "promote these three things". That way lies tiny framework lasagna.
    consolidation =
      active_moments
      |> candidate_moments(min_attention)
      |> graph_expanded_candidates(active_moments, associations, opts)
      |> default_consolidation(associations, now, opts)

    with {:ok, consolidation} <- run_consolidation(consolidation, opts),
         :ok <- persist_consolidation(consolidation) do
      Manager.compact()
      {:reply, {:ok, consolidation.knowledge}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec run_consolidation(Consolidation.t(), keyword()) ::
          {:ok, Consolidation.t()} | {:error, term()}
  defp run_consolidation(%Consolidation{} = consolidation, opts) do
    cond do
      fun = Keyword.get(opts, :consolidate_with) ->
        consolidate_with_fun(fun, consolidation, opts)

      adapter =
          Keyword.get(opts, :consolidation_adapter) ||
            Application.get_env(:spectre_mnemonic, :consolidation_adapter) ->
        consolidate_with_adapter(adapter, consolidation, opts)

      true ->
        {:ok, consolidation}
    end
  end

  @spec consolidate_with_fun(function(), Consolidation.t(), keyword()) ::
          {:ok, Consolidation.t()} | {:error, term()}
  defp consolidate_with_fun(fun, consolidation, _opts) when is_function(fun, 1) do
    fun.(consolidation)
    |> normalize_consolidation(consolidation)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp consolidate_with_fun(fun, consolidation, opts) when is_function(fun, 2) do
    fun.(consolidation, opts)
    |> normalize_consolidation(consolidation)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp consolidate_with_fun(fun, _consolidation, _opts),
    do: {:error, {:invalid_consolidation_fun, fun}}

  @spec consolidate_with_adapter(module(), Consolidation.t(), keyword()) ::
          {:ok, Consolidation.t()} | {:error, term()}
  defp consolidate_with_adapter(adapter, consolidation, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :consolidate, 2) do
      adapter.consolidate(consolidation, opts)
      |> normalize_consolidation(consolidation)
    else
      {:error, {:invalid_consolidation_adapter, adapter}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec default_consolidation([term()], [term()], DateTime.t(), keyword()) :: Consolidation.t()
  defp default_consolidation(moments, associations, now, opts) do
    outputs = default_outputs(moments, now)

    %Consolidation{
      moments: moments,
      associations: associations,
      windows: graph_windows(moments, associations),
      now: now,
      opts: opts,
      knowledge: outputs.knowledge,
      summaries: outputs.summaries,
      categories: outputs.categories,
      embeddings: outputs.embeddings,
      records: [],
      tombstones: [],
      strategy: :default
    }
  end

  @spec normalize_consolidation(term(), Consolidation.t()) ::
          {:ok, Consolidation.t()} | {:error, term()}
  defp normalize_consolidation({:ok, consolidation}, default),
    do: normalize_consolidation(consolidation, default)

  defp normalize_consolidation({:error, reason}, _default), do: {:error, reason}

  defp normalize_consolidation(%Consolidation{} = consolidation, _default),
    do: {:ok, consolidation}

  defp normalize_consolidation(plan, %Consolidation{} = default) when is_map(plan) do
    {:ok,
     %{
       default
       | moments: value_list(plan, :moments, default.moments),
         associations: value_list(plan, :associations, default.associations),
         windows: value_list(plan, :windows, default.windows),
         now: value(plan, :now, default.now),
         opts: value(plan, :opts, default.opts),
         knowledge: value_list(plan, :knowledge, default.knowledge),
         summaries: value_list(plan, :summaries, default.summaries),
         categories: value_list(plan, :categories, default.categories),
         embeddings: value_list(plan, :embeddings, default.embeddings),
         records: value_list(plan, :records, default.records),
         tombstones: value_list(plan, :tombstones, default.tombstones),
         strategy: value(plan, :strategy, :custom),
         metadata: value(plan, :metadata, default.metadata),
         warnings: value_list(plan, :warnings, default.warnings),
         errors: value_list(plan, :errors, default.errors)
     }}
  end

  defp normalize_consolidation(knowledge, %Consolidation{} = default) when is_list(knowledge),
    do: {:ok, %{default | knowledge: knowledge, strategy: :custom}}

  defp normalize_consolidation(other, _default),
    do: {:error, {:invalid_consolidation_plan, other}}

  @spec persist_consolidation(Consolidation.t()) :: :ok | {:error, term()}
  defp persist_consolidation(%Consolidation{} = consolidation) do
    with :ok <- persist_family_writes(consolidation),
         :ok <- persist_adapter_records(consolidation.records),
         :ok <- persist_tombstones(consolidation.tombstones),
         {:ok, _result} <- Manager.append(:consolidation_jobs, consolidation_job(consolidation)) do
      Governance.promote_moments(consolidation.moments)
      :ok
    end
  end

  @spec candidate_moments([term()], number()) :: [term()]
  defp candidate_moments(moments, min_attention) do
    Enum.filter(moments, &(&1.attention >= min_attention))
  end

  @spec graph_expanded_candidates([term()], [term()], [term()], keyword()) :: [term()]
  defp graph_expanded_candidates(candidates, active_moments, associations, opts) do
    depth = opts |> graph_depth() |> max(0)
    moment_by_id = Map.new(active_moments, &{&1.id, &1})
    seed_ids = MapSet.new(Enum.map(candidates, & &1.id))
    expanded_ids = expand_ids(seed_ids, seed_ids, associations, moment_by_id, depth)

    Enum.filter(active_moments, &MapSet.member?(expanded_ids, &1.id))
  end

  @spec graph_depth(keyword()) :: non_neg_integer()
  defp graph_depth(opts) do
    Keyword.get(opts, :graph_depth, Keyword.get(opts, :consolidation_graph_depth, 1))
  end

  @spec expand_ids(MapSet.t(binary()), MapSet.t(binary()), [term()], map(), non_neg_integer()) ::
          MapSet.t(binary())
  defp expand_ids(seen, _frontier, _associations, _moment_by_id, 0), do: seen

  defp expand_ids(seen, frontier, associations, moment_by_id, depth) do
    next = associations |> next_expansion_ids(frontier, moment_by_id) |> MapSet.difference(seen)

    if MapSet.size(next) == 0 do
      seen
    else
      expand_ids(MapSet.union(seen, next), next, associations, moment_by_id, depth - 1)
    end
  end

  @spec next_expansion_ids([term()], MapSet.t(binary()), map()) :: MapSet.t(binary())
  defp next_expansion_ids(associations, frontier, moment_by_id) do
    Enum.reduce(associations, MapSet.new(), fn association, ids ->
      case linked_memory_id(association, frontier, moment_by_id) do
        nil -> ids
        id -> MapSet.put(ids, id)
      end
    end)
  end

  @spec linked_memory_id(term(), MapSet.t(binary()), map()) :: binary() | nil
  defp linked_memory_id(association, frontier, moment_by_id) do
    cond do
      MapSet.member?(frontier, association.source_id) and
          Map.has_key?(moment_by_id, association.target_id) ->
        association.target_id

      MapSet.member?(frontier, association.target_id) and
          Map.has_key?(moment_by_id, association.source_id) ->
        association.source_id

      true ->
        nil
    end
  end

  @spec default_outputs([term()], DateTime.t()) :: map()
  defp default_outputs(moments, now) do
    outputs =
      Enum.reduce(moments, %{knowledge: [], summaries: [], categories: [], embeddings: []}, fn
        %{kind: :memory_summary} = moment, acc ->
          acc
          |> Map.update!(:knowledge, &[knowledge_record(moment, now) | &1])
          |> Map.update!(:summaries, &[moment | &1])
          |> add_embeddings(moment)

        %{kind: :memory_category} = moment, acc ->
          acc
          |> Map.update!(:knowledge, &[knowledge_record(moment, now) | &1])
          |> Map.update!(:categories, &[moment | &1])
          |> add_embeddings(moment)

        moment, acc ->
          acc
          |> Map.update!(:knowledge, &[knowledge_record(moment, now) | &1])
          |> add_embeddings(moment)
      end)

    %{
      knowledge: Enum.reverse(outputs.knowledge),
      summaries: Enum.reverse(outputs.summaries),
      categories: Enum.reverse(outputs.categories),
      embeddings: Enum.reverse(outputs.embeddings)
    }
  end

  @spec add_embeddings(map(), term()) :: map()
  defp add_embeddings(outputs, moment) do
    Map.update!(outputs, :embeddings, &Enum.reverse(embedding_record(moment), &1))
  end

  @spec knowledge_record(term(), DateTime.t()) :: Record.t()
  defp knowledge_record(moment, now) do
    %Record{
      id: "know_#{System.unique_integer([:positive, :monotonic])}",
      source_id: moment.id,
      text: moment.text,
      vector: moment.vector,
      binary_signature: moment.binary_signature,
      embedding: moment.embedding,
      metadata:
        Governance.with_provenance(
          %{
            stream: moment.stream,
            task_id: moment.task_id,
            kind: moment.kind,
            scope: Scope.scope(moment)
          }
          |> Temporal.put_metadata(Temporal.temporal_map(moment)),
          source_ids: [moment.id],
          provider: :consolidator,
          confidence: Map.get(moment.metadata, :confidence, 1.0),
          occurred_at: Map.get(Temporal.temporal_map(moment), :occurred_at),
          observed_at: Map.get(Temporal.temporal_map(moment), :observed_at) || now,
          last_verified_at: Map.get(Temporal.temporal_map(moment), :last_verified_at) || now,
          valid_from: Map.get(Temporal.temporal_map(moment), :valid_from),
          valid_until: Map.get(Temporal.temporal_map(moment), :valid_until)
        ),
      inserted_at: now
    }
  end

  @spec persist_family_writes(Consolidation.t()) :: :ok | {:error, term()}
  defp persist_family_writes(%Consolidation{} = consolidation) do
    [
      moments: consolidation.moments,
      knowledge: consolidation.knowledge,
      summaries: consolidation.summaries,
      categories: consolidation.categories,
      embeddings: consolidation.embeddings,
      associations: consolidation.associations
    ]
    |> stop_on_error(fn {family, values} -> persist_values(family, values) end)
  end

  @spec persist_values(atom(), [term()]) :: :ok | {:error, term()}
  defp persist_values(family, values) do
    stop_on_error(values, fn value -> Manager.append(family, value) end)
  end

  @spec persist_adapter_records([term()]) :: :ok | {:error, term()}
  defp persist_adapter_records(records) do
    stop_on_error(records, &append_record/1)
  end

  @spec persist_tombstones([term()]) :: :ok | {:error, term()}
  defp persist_tombstones(tombstones) do
    stop_on_error(tombstones, &append_tombstone/1)
  end

  @spec stop_on_error(Enumerable.t(), (term() -> :ok | {:ok, term()} | {:error, term()})) ::
          :ok | {:error, term()}
  defp stop_on_error(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec append_record({atom(), term()}) :: {:ok, term()} | {:error, term()}
  defp append_record({family, payload}) when is_atom(family), do: Manager.append(family, payload)
  defp append_record(other), do: {:error, {:invalid_consolidation_record, other}}

  @spec consolidation_job(Consolidation.t()) :: map()
  defp consolidation_job(%Consolidation{} = consolidation) do
    %{
      count: length(consolidation.knowledge),
      moments: length(consolidation.moments),
      summaries: length(consolidation.summaries),
      categories: length(consolidation.categories),
      embeddings: length(consolidation.embeddings),
      associations: length(consolidation.associations),
      tombstones: length(consolidation.tombstones),
      windows: length(consolidation.windows),
      strategy: consolidation.strategy,
      metadata: consolidation.metadata,
      warnings: consolidation.warnings,
      inserted_at: consolidation.now || DateTime.utc_now()
    }
  end

  @spec append_tombstone(term()) :: {:ok, term()} | {:error, term()}
  defp append_tombstone({family, id}) when is_atom(family) and is_binary(id) do
    Manager.append(:tombstones, %{family: family, id: id, forgotten_at: DateTime.utc_now()})
  end

  defp append_tombstone(%{family: family, id: id} = tombstone)
       when is_atom(family) and is_binary(id) do
    payload = Map.put_new(tombstone, :forgotten_at, DateTime.utc_now())
    Manager.append(:tombstones, payload)
  end

  defp append_tombstone(%{"family" => family, "id" => id} = tombstone)
       when is_binary(family) and is_binary(id) do
    tombstone
    |> tombstone_payload()
    |> append_tombstone_payload(family)
  end

  defp append_tombstone(other), do: {:error, {:invalid_consolidation_tombstone, other}}

  @spec append_tombstone_payload({:ok, map()} | :error, binary()) ::
          {:ok, term()} | {:error, term()}
  defp append_tombstone_payload({:ok, payload}, _family), do: Manager.append(:tombstones, payload)

  defp append_tombstone_payload(:error, family),
    do: {:error, {:invalid_consolidation_tombstone_family, family}}

  @spec tombstone_payload(map()) :: {:ok, map()} | :error
  defp tombstone_payload(tombstone) do
    # Adapters sometimes send string keys because the outside world keeps doing
    # outside-world things. Normalize once here; dont leak that sadness inward.
    with {:ok, family} <- Family.from_string(Map.fetch!(tombstone, "family")) do
      payload =
        tombstone
        |> Map.new(fn
          {"family", _value} -> {:family, family}
          {key, value} when is_binary(key) -> {Map.get(@tombstone_key_by_string, key, key), value}
          other -> other
        end)
        |> Map.put_new(:forgotten_at, DateTime.utc_now())

      {:ok, payload}
    end
  end

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec value_list(map(), atom(), term()) :: [term()]
  defp value_list(map, key, default), do: map |> value(key, default) |> List.wrap()

  @spec graph_windows([term()], [term()]) :: [map()]
  defp graph_windows(moments, associations) do
    moment_by_id = Map.new(moments, &{&1.id, &1})
    selected_ids = MapSet.new(Map.keys(moment_by_id))

    # Windows are connected components, not whatever the last prompt felt was
    # important. Graph edges give us a boring runtime boundary, which is my
    # favorite kind of boundary because it usually survives lunch.
    graph_associations = graph_associations(associations, selected_ids)
    adjacency = adjacency(selected_ids, graph_associations)

    selected_ids
    |> connected_components(adjacency)
    |> Enum.sort_by(&component_sort_key(&1, moment_by_id), :desc)
    |> Enum.with_index(1)
    |> Enum.map(&window_from_component(&1, graph_associations, moment_by_id))
  end

  @typep memory_id :: binary()
  @typep adjacency :: %{memory_id() => MapSet.t(memory_id())}

  @spec graph_associations([term()], MapSet.t(memory_id())) :: [term()]
  defp graph_associations(associations, selected_ids) do
    Enum.filter(associations, &selected_association?(&1, selected_ids))
  end

  @spec selected_association?(term(), MapSet.t(memory_id())) :: boolean()
  defp selected_association?(association, selected_ids) do
    MapSet.member?(selected_ids, association.source_id) and
      MapSet.member?(selected_ids, association.target_id)
  end

  @spec adjacency(MapSet.t(memory_id()), [term()]) :: adjacency()
  defp adjacency(selected_ids, graph_associations) do
    Enum.reduce(graph_associations, Map.new(selected_ids, &{&1, MapSet.new()}), fn association,
                                                                                   adjacency ->
      adjacency
      |> Map.update!(association.source_id, &MapSet.put(&1, association.target_id))
      |> Map.update!(association.target_id, &MapSet.put(&1, association.source_id))
    end)
  end

  @spec connected_components(MapSet.t(memory_id()), adjacency()) :: [[memory_id()]]
  defp connected_components(ids, adjacency) do
    {components, _seen} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {components, seen} ->
        if MapSet.member?(seen, id) do
          {components, seen}
        else
          component = visit_component([id], adjacency, %{}) |> Map.keys() |> MapSet.new()
          {[Enum.sort(MapSet.to_list(component)) | components], MapSet.union(seen, component)}
        end
      end)

    components
  end

  @spec visit_component([memory_id()], adjacency(), %{optional(memory_id()) => true}) :: %{
          optional(memory_id()) => true
        }
  defp visit_component([], _adjacency, seen), do: seen

  defp visit_component([id | rest], adjacency, seen) do
    if Map.has_key?(seen, id) do
      visit_component(rest, adjacency, seen)
    else
      next = MapSet.to_list(Map.get(adjacency, id, MapSet.new())) ++ rest
      visit_component(next, adjacency, Map.put(seen, id, true))
    end
  end

  @spec component_sort_key([binary()], map()) :: integer()
  defp component_sort_key(component, moment_by_id) do
    component
    |> Enum.map(fn id -> moment_timestamp(Map.get(moment_by_id, id)) end)
    |> Enum.max(fn -> 0 end)
  end

  @spec moment_timestamp(term()) :: integer()
  defp moment_timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp moment_timestamp(_moment), do: 0

  @spec window_from_component({[binary()], pos_integer()}, [term()], map()) :: map()
  defp window_from_component({component, index}, graph_associations, moment_by_id) do
    component_set = MapSet.new(component)

    component_associations =
      graph_associations
      |> Enum.filter(&selected_association?(&1, component_set))

    window_for(component, component_associations, moment_by_id, index)
  end

  @spec window_for([binary()], [term()], map(), pos_integer()) :: map()
  defp window_for(component, component_associations, moment_by_id, index) do
    moments = Enum.map(component, &Map.fetch!(moment_by_id, &1))

    %{
      id: "window_#{index}",
      moment_ids: component,
      association_ids: Enum.map(component_associations, & &1.id),
      stream: window_stream(moments),
      task_ids: window_task_ids(moments),
      time_range: window_time_range(moments),
      keywords: window_keywords(moments),
      metadata: %{
        size: length(moments),
        associations: length(component_associations)
      }
    }
  end

  @spec window_stream([term()]) :: term()
  defp window_stream(moments) do
    case moments |> Enum.map(& &1.stream) |> Enum.uniq() do
      [stream] -> stream
      _streams -> :mixed
    end
  end

  @spec window_task_ids([term()]) :: [term()]
  defp window_task_ids(moments) do
    moments
    |> Enum.map(& &1.task_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec window_time_range([term()]) :: %{from: DateTime.t() | nil, to: DateTime.t() | nil}
  defp window_time_range(moments) do
    inserted = Enum.filter(Enum.map(moments, & &1.inserted_at), &match?(%DateTime{}, &1))

    %{
      from: Enum.min_by(inserted, &DateTime.to_unix(&1, :microsecond), fn -> nil end),
      to: Enum.max_by(inserted, &DateTime.to_unix(&1, :microsecond), fn -> nil end)
    }
  end

  @spec window_keywords([term()]) :: [binary()]
  defp window_keywords(moments) do
    moments
    |> Enum.flat_map(&Map.get(&1, :keywords, []))
    |> Enum.uniq()
    |> Enum.take(24)
  end

  @spec embedding_record(SpectreMnemonic.Memory.Moment.t()) :: [map()]
  defp embedding_record(%{vector: vector} = moment) when is_binary(vector) do
    [
      %{
        id: "emb_#{moment.id}",
        source_id: moment.id,
        vector: moment.vector,
        binary_signature: moment.binary_signature,
        embedding: moment.embedding,
        metadata: %{
          stream: moment.stream,
          task_id: moment.task_id,
          kind: moment.kind,
          dimensions: dimensions(moment.embedding)
        },
        inserted_at: moment.inserted_at
      }
    ]
  end

  defp embedding_record(_moment), do: []

  @spec dimensions(term()) :: term()
  defp dimensions(%{metadata: %{dimensions: dimensions}}), do: dimensions
  defp dimensions(_embedding), do: nil
end
