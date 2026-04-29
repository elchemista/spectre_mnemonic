defmodule SpectreMnemonic.Knowledge.Consolidator do
  @moduledoc """
  Moves selected active focus into durable memory records.

  Spectre Mnemonic is not a database of everything.
  Spectre Mnemonic is a living focus that slowly becomes organized memory.
  """

  use GenServer

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Knowledge.{Consolidation, Record}
  alias SpectreMnemonic.Persistence.Manager

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
  """
  @spec consolidate(keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def consolidate(opts \\ []) do
    GenServer.call(__MODULE__, {:consolidate, opts})
  end

  @impl true
  @spec init(map()) :: {:ok, map()}
  def init(state), do: {:ok, state}

  @impl true
  @spec handle_call({:consolidate, keyword()}, GenServer.from(), map()) ::
          {:reply, {:ok, [Record.t()]} | {:error, term()}, map()}
  def handle_call({:consolidate, opts}, _from, state) do
    min_attention = Keyword.get(opts, :min_attention, 1.0)
    now = DateTime.utc_now()

    consolidation =
      min_attention
      |> candidate_moments()
      |> default_consolidation(Focus.associations(), now, opts)

    case run_consolidation(consolidation, opts) do
      {:ok, consolidation} ->
        case persist_consolidation(consolidation) do
          :ok ->
            Manager.compact()
            {:reply, {:ok, consolidation.knowledge}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
    %Consolidation{
      moments: moments,
      associations: associations,
      windows: graph_windows(moments, associations),
      now: now,
      opts: opts,
      knowledge: Enum.map(moments, &knowledge_record(&1, now)),
      summaries: Enum.filter(moments, &(&1.kind == :memory_summary)),
      categories: Enum.filter(moments, &(&1.kind == :memory_category)),
      embeddings: Enum.flat_map(moments, &embedding_record/1),
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
    results =
      consolidation
      |> durable_family_writes()
      |> Kernel.++(Enum.map(consolidation.records, &append_record/1))
      |> Kernel.++(Enum.map(consolidation.tombstones, &append_tombstone/1))
      |> Kernel.++([Manager.append(:consolidation_jobs, consolidation_job(consolidation))])

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec candidate_moments(number()) :: [term()]
  defp candidate_moments(min_attention) do
    Focus.moments()
    |> Enum.filter(&(&1.attention >= min_attention))
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
      metadata: %{stream: moment.stream, task_id: moment.task_id, kind: moment.kind},
      inserted_at: now
    }
  end

  @spec durable_family_writes(Consolidation.t()) :: [term()]
  defp durable_family_writes(%Consolidation{} = consolidation) do
    [
      moments: consolidation.moments,
      knowledge: consolidation.knowledge,
      summaries: consolidation.summaries,
      categories: consolidation.categories,
      embeddings: consolidation.embeddings,
      associations: consolidation.associations
    ]
    |> Enum.flat_map(fn {family, values} ->
      Enum.map(values, &Manager.append(family, &1))
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
    payload =
      tombstone
      |> Map.new(fn
        {"family", value} -> {:family, String.to_atom(value)}
        {"id", value} -> {:id, value}
        {key, value} when is_binary(key) -> {String.to_atom(key), value}
        other -> other
      end)
      |> Map.put_new(:forgotten_at, DateTime.utc_now())

    Manager.append(:tombstones, payload)
  end

  defp append_tombstone(other), do: {:error, {:invalid_consolidation_tombstone, other}}

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec value_list(map(), atom(), term()) :: [term()]
  defp value_list(map, key, default), do: map |> value(key, default) |> List.wrap()

  @spec graph_windows([term()], [term()]) :: [map()]
  defp graph_windows(moments, associations) do
    moment_by_id = Map.new(moments, &{&1.id, &1})
    selected_ids = MapSet.new(Map.keys(moment_by_id))

    # Consolidation windows are connected components in the selected active
    # graph. Associations to memories outside this consolidation run are
    # intentionally ignored so adapters receive self-contained batches.
    graph_associations =
      Enum.filter(associations, fn association ->
        MapSet.member?(selected_ids, association.source_id) and
          MapSet.member?(selected_ids, association.target_id)
      end)

    adjacency =
      Enum.reduce(graph_associations, Map.new(selected_ids, &{&1, MapSet.new()}), fn association,
                                                                                     acc ->
        acc
        |> Map.update!(association.source_id, &MapSet.put(&1, association.target_id))
        |> Map.update!(association.target_id, &MapSet.put(&1, association.source_id))
      end)

    selected_ids
    |> connected_components(adjacency)
    |> Enum.sort_by(&component_sort_key(&1, moment_by_id), :desc)
    |> Enum.with_index(1)
    |> Enum.map(fn {component, index} ->
      component_set = MapSet.new(component)

      component_associations =
        Enum.filter(graph_associations, fn association ->
          MapSet.member?(component_set, association.source_id) and
            MapSet.member?(component_set, association.target_id)
        end)

      window_for(component, component_associations, moment_by_id, index)
    end)
  end

  @spec connected_components(MapSet.t(), map()) :: [[binary()]]
  defp connected_components(ids, adjacency) do
    {components, _seen} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {components, seen} ->
        if MapSet.member?(seen, id) do
          {components, seen}
        else
          component = visit_component([id], adjacency, MapSet.new())
          {[Enum.sort(MapSet.to_list(component)) | components], MapSet.union(seen, component)}
        end
      end)

    components
  end

  @spec visit_component([binary()], map(), MapSet.t()) :: MapSet.t()
  defp visit_component([], _adjacency, seen), do: seen

  defp visit_component([id | rest], adjacency, seen) do
    if MapSet.member?(seen, id) do
      visit_component(rest, adjacency, seen)
    else
      neighbors = adjacency |> Map.get(id, MapSet.new()) |> MapSet.to_list()
      visit_component(neighbors ++ rest, adjacency, MapSet.put(seen, id))
    end
  end

  @spec component_sort_key([binary()], map()) :: integer()
  defp component_sort_key(component, moment_by_id) do
    component
    |> Enum.map(fn id ->
      case Map.get(moment_by_id, id) do
        %{inserted_at: %DateTime{} = inserted_at} -> DateTime.to_unix(inserted_at, :microsecond)
        _moment -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  @spec window_for([binary()], [term()], map(), pos_integer()) :: map()
  defp window_for(component, component_associations, moment_by_id, index) do
    moments = Enum.map(component, &Map.fetch!(moment_by_id, &1))
    streams = moments |> Enum.map(& &1.stream) |> Enum.uniq()
    inserted = moments |> Enum.map(& &1.inserted_at) |> Enum.filter(&match?(%DateTime{}, &1))

    %{
      id: "window_#{index}",
      moment_ids: component,
      association_ids: Enum.map(component_associations, & &1.id),
      stream: if(length(streams) == 1, do: hd(streams), else: :mixed),
      task_ids: moments |> Enum.map(& &1.task_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      time_range: %{
        from: Enum.min_by(inserted, &DateTime.to_unix(&1, :microsecond), fn -> nil end),
        to: Enum.max_by(inserted, &DateTime.to_unix(&1, :microsecond), fn -> nil end)
      },
      keywords:
        moments
        |> Enum.flat_map(&Map.get(&1, :keywords, []))
        |> Enum.uniq()
        |> Enum.take(24),
      metadata: %{
        size: length(moments),
        associations: length(component_associations)
      }
    }
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
