defmodule SpectreMnemonic.Knowledge.Consolidator do
  @moduledoc """
  Moves selected active focus into durable memory records.

  Spectre Mnemonic is not a database of everything.
  Spectre Mnemonic is a living focus that slowly becomes organized memory.
  """

  use GenServer

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Knowledge.Record
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
  promotion logic.
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

    moments =
      Focus.moments()
      |> Enum.filter(&(&1.attention >= min_attention))

    associations = Focus.associations()
    context = %{moments: moments, associations: associations, now: now, opts: opts}

    case build_plan(context, opts) do
      {:ok, plan} ->
        case persist_plan(plan, now) do
          :ok ->
            Manager.compact()
            {:reply, {:ok, Map.get(plan, :knowledge, [])}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec build_plan(map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp build_plan(context, opts) do
    cond do
      fun = Keyword.get(opts, :consolidate_with) ->
        consolidate_with_fun(fun, context, opts)

      adapter =
          Keyword.get(opts, :consolidation_adapter) ||
            Application.get_env(:spectre_mnemonic, :consolidation_adapter) ->
        consolidate_with_adapter(adapter, context, opts)

      true ->
        {:ok, default_plan(context)}
    end
  end

  @spec consolidate_with_fun(function(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp consolidate_with_fun(fun, context, _opts) when is_function(fun, 1) do
    fun.(context)
    |> normalize_plan(context)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp consolidate_with_fun(fun, context, opts) when is_function(fun, 2) do
    fun.(context, opts)
    |> normalize_plan(context)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp consolidate_with_fun(fun, _context, _opts), do: {:error, {:invalid_consolidation_fun, fun}}

  @spec consolidate_with_adapter(module(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp consolidate_with_adapter(adapter, context, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :consolidate, 2) do
      adapter.consolidate(context, opts)
      |> normalize_plan(context)
    else
      {:error, {:invalid_consolidation_adapter, adapter}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec default_plan(map()) :: map()
  defp default_plan(%{moments: moments, associations: associations, now: now}) do
    knowledge =
      moments
      |> Enum.map(fn moment ->
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
      end)

    %{
      moments: moments,
      knowledge: knowledge,
      summaries: Enum.filter(moments, &(&1.kind == :memory_summary)),
      categories: Enum.filter(moments, &(&1.kind == :memory_category)),
      embeddings: Enum.flat_map(moments, &embedding_record/1),
      associations: associations,
      records: [],
      strategy: :default
    }
  end

  @spec normalize_plan(term(), map()) :: {:ok, map()} | {:error, term()}
  defp normalize_plan({:ok, plan}, context), do: normalize_plan(plan, context)
  defp normalize_plan({:error, reason}, _context), do: {:error, reason}

  defp normalize_plan(plan, context) when is_map(plan) do
    default = default_plan(context)

    {:ok,
     %{
       moments: List.wrap(Map.get(plan, :moments, Map.get(plan, "moments", default.moments))),
       knowledge:
         List.wrap(Map.get(plan, :knowledge, Map.get(plan, "knowledge", default.knowledge))),
       summaries:
         List.wrap(Map.get(plan, :summaries, Map.get(plan, "summaries", default.summaries))),
       categories:
         List.wrap(Map.get(plan, :categories, Map.get(plan, "categories", default.categories))),
       embeddings:
         List.wrap(Map.get(plan, :embeddings, Map.get(plan, "embeddings", default.embeddings))),
       associations:
         List.wrap(
           Map.get(plan, :associations, Map.get(plan, "associations", default.associations))
         ),
       records: List.wrap(Map.get(plan, :records, Map.get(plan, "records", []))),
       strategy: Map.get(plan, :strategy, Map.get(plan, "strategy", :custom))
     }}
  end

  defp normalize_plan(knowledge, context) when is_list(knowledge) do
    context
    |> default_plan()
    |> Map.put(:knowledge, knowledge)
    |> normalize_plan(context)
  end

  defp normalize_plan(other, _context), do: {:error, {:invalid_consolidation_plan, other}}

  @spec persist_plan(map(), DateTime.t()) :: :ok | {:error, term()}
  defp persist_plan(plan, now) do
    results =
      Enum.map(plan.moments, &Manager.append(:moments, &1)) ++
        Enum.map(plan.knowledge, &Manager.append(:knowledge, &1)) ++
        Enum.map(plan.summaries, &Manager.append(:summaries, &1)) ++
        Enum.map(plan.categories, &Manager.append(:categories, &1)) ++
        Enum.map(plan.embeddings, &Manager.append(:embeddings, &1)) ++
        Enum.map(plan.associations, &Manager.append(:associations, &1)) ++
        Enum.map(plan.records, fn {family, payload} ->
          Manager.append(family, payload)
        end) ++
        [
          Manager.append(:consolidation_jobs, %{
            count: length(plan.knowledge),
            moments: length(plan.moments),
            summaries: length(plan.summaries),
            categories: length(plan.categories),
            embeddings: length(plan.embeddings),
            associations: length(plan.associations),
            strategy: plan.strategy,
            inserted_at: now
          })
        ]

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
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
