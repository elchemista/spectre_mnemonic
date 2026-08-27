defmodule SpectreMnemonic.Engine.Projection do
  @moduledoc false

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Engine.Runtime
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Telemetry

  @registry SpectreMnemonic.Engine.Registry

  @type candidate_meta :: %{
          total: non_neg_integer(),
          candidates: non_neg_integer(),
          mode: :candidate_first | :brute_force,
          sources: map()
        }

  @doc false
  @spec upsert(map(), keyword()) :: :ok
  def upsert(moment, opts \\ [])

  def upsert(%{namespace: _namespace} = moment, opts) do
    commit_id =
      {Keyword.get(opts, :batch_id), Keyword.get(opts, :operation_id), moment.id,
       :erlang.phash2(moment)}

    apply_batch(commit_id, [{:upsert, moment}], opts)
  end

  def upsert(_moment, _opts), do: :ok

  @doc false
  @spec apply_batch(term(), [{:upsert | :delete, map()}], keyword()) :: :ok
  def apply_batch(commit_id, changes, opts \\ []) do
    changes
    |> Enum.group_by(&batch_shard/1)
    |> Enum.each(fn
      {{:ok, pid}, shard_changes} ->
        GenServer.call(pid, {:apply_batch, commit_id, shard_changes, opts})

      {{:error, _reason}, _shard_changes} ->
        :ok
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec delete(map()) :: :ok
  def delete(%{namespace: namespace} = moment) do
    with {:ok, runtime} <- Engine.resolve_internal_namespace(namespace),
         {:ok, pid, _tables} <- shard(runtime, namespace, Map.get(moment, :scope)) do
      GenServer.call(pid, {:delete, moment})
    else
      _missing -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  def delete(_moment), do: :ok

  @spec batch_shard({:upsert | :delete, map()}) :: {:ok, pid()} | {:error, term()}
  defp batch_shard({_operation, %{namespace: namespace} = moment}) do
    with {:ok, runtime} <- Engine.resolve_internal_namespace(namespace),
         {:ok, pid, _tables} <- shard(runtime, namespace, Map.get(moment, :scope)) do
      {:ok, pid}
    end
  end

  defp batch_shard(_change), do: {:error, :invalid_projection_change}

  @doc false
  @spec candidates(QueryContext.t(), [binary()], keyword()) ::
          {:ok, [map()], candidate_meta()} | {:fallback, candidate_meta()}
  def candidates(%QueryContext{} = cue, vector_ids, opts) do
    with {:ok, runtime} <- runtime(opts, cue.namespace),
         {:ok, _pid, tables} <- shard(runtime, cue.namespace, cue.scope) do
      partition = {cue.namespace, cue.scope}
      total = count(tables.metadata, partition)
      threshold = runtime.config.brute_force_threshold
      max_candidates = candidate_limit(runtime.config, opts)

      if total <= threshold do
        meta = %{total: total, candidates: total, mode: :brute_force, sources: %{}}
        emit([:recall, :full_scan_fallback], meta, opts)
        {:fallback, meta}
      else
        keys = candidate_keys(cue, opts)
        seed_ids = normalize_ids(Keyword.get(opts, :seed_ids, []))

        {ids, sources} =
          collect_ids(tables, partition, keys, vector_ids ++ seed_ids, max_candidates)

        moments = fetch_documents(tables.documents, ids, partition)

        meta = %{
          total: total,
          candidates: length(moments),
          mode: :candidate_first,
          sources: sources
        }

        emit([:recall, :candidate_collection], meta, opts)
        {:ok, moments, meta}
      end
    else
      _missing -> {:fallback, %{total: 0, candidates: 0, mode: :brute_force, sources: %{}}}
    end
  end

  @doc false
  @spec reset(Engine.Ref.t() | pid() | atom() | {:via, module(), term()}) :: :ok
  def reset(reference) do
    with {:ok, runtime} <- Engine.resolve(reference) do
      reset_shards(runtime)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec reset_shards(Runtime.t()) :: :ok
  defp reset_shards(%Runtime{} = runtime) do
    Enum.each(
      0..(runtime.config.projection_shards - 1),
      &reset_shard(runtime.config.ref, &1)
    )
  end

  @spec reset_shard(Engine.Ref.t(), non_neg_integer()) :: :ok
  defp reset_shard(ref, index) do
    case Registry.lookup(@registry, {:projection_shard, ref, index}) do
      [{pid, _tables}] -> GenServer.call(pid, :reset)
      [] -> :ok
    end
  end

  @doc false
  @spec status(Runtime.t()) :: map()
  def status(%Runtime{} = runtime) do
    shards =
      Enum.map(0..(runtime.config.projection_shards - 1), fn index ->
        case Registry.lookup(@registry, {:projection_shard, runtime.config.ref, index}) do
          [{pid, tables}] ->
            %{
              shard: index,
              running?: Process.alive?(pid),
              documents: table_size(tables.documents),
              postings: table_size(tables.postings),
              bytes: table_bytes(tables)
            }

          [] ->
            %{shard: index, running?: false, documents: 0, postings: 0, bytes: 0}
        end
      end)

    %{
      healthy?: Enum.all?(shards, & &1.running?),
      count: length(shards),
      documents: Enum.sum(Enum.map(shards, & &1.documents)),
      bytes: Enum.sum(Enum.map(shards, & &1.bytes)),
      shards: shards
    }
  rescue
    ArgumentError -> %{healthy?: false, count: 0, documents: 0, bytes: 0, shards: []}
  end

  @doc false
  @spec partitions(Runtime.t()) :: [{binary(), term()}]
  def partitions(%Runtime{} = runtime) do
    0..(runtime.config.projection_shards - 1)
    |> Enum.flat_map(fn index ->
      case Registry.lookup(@registry, {:projection_shard, runtime.config.ref, index}) do
        [{_pid, tables}] ->
          :ets.select(tables.metadata, [{{{:count, :"$1"}, :_}, [], [:"$1"]}])

        [] ->
          []
      end
    end)
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  @spec runtime(keyword(), binary()) :: {:ok, Runtime.t()} | {:error, term()}
  defp runtime(opts, namespace) do
    case Keyword.get(opts, :engine_ref) do
      %Ref{} = ref -> Engine.resolve(ref)
      _missing -> Engine.resolve_internal_namespace(namespace)
    end
  end

  @spec shard(Runtime.t(), binary(), term()) :: {:ok, pid(), map()} | {:error, term()}
  defp shard(%Runtime{config: config}, namespace, scope) do
    index = :erlang.phash2({config.ref, namespace, scope}, config.projection_shards)

    case Registry.lookup(@registry, {:projection_shard, config.ref, index}) do
      [{pid, tables}] -> {:ok, pid, tables}
      [] -> {:error, :projection_shard_unavailable}
    end
  end

  @spec count(:ets.tid(), tuple()) :: non_neg_integer()
  defp count(table, partition) do
    case :ets.lookup(table, {:count, partition}) do
      [{{:count, ^partition}, count}] -> count
      [] -> 0
    end
  end

  @spec table_size(:ets.tid()) :: non_neg_integer()
  defp table_size(table), do: :ets.info(table, :size) || 0

  @spec table_bytes(map()) :: non_neg_integer()
  defp table_bytes(tables) do
    word_size = :erlang.system_info(:wordsize)

    tables
    |> Map.values()
    |> Enum.reduce(0, fn table, total -> total + (:ets.info(table, :memory) || 0) end)
    |> Kernel.*(word_size)
  end

  @spec candidate_limit(Config.t(), keyword()) :: pos_integer()
  defp candidate_limit(config, opts) do
    requested = Keyword.get(opts, :max_candidates, config.limits.max_candidates)
    requested |> max(1) |> min(config.limits.max_candidates)
  end

  @spec candidate_keys(QueryContext.t(), keyword()) :: [tuple()]
  defp candidate_keys(cue, opts) do
    term_keys = Enum.map(cue.keywords, &{:term, normalize_term(&1)})
    entity_keys = Enum.map(cue.entities, &{:entity, normalize_term(&1)})

    filters = [
      {:stream, Keyword.get(opts, :stream)},
      {:task, Keyword.get(opts, :task_id)},
      {:kind, Keyword.get(opts, :kind)},
      {:temporal, Keyword.get(opts, :temporal_bucket)}
    ]

    (term_keys ++ entity_keys ++ filters)
    |> Enum.reject(fn {_axis, value} -> is_nil(value) or value == "" end)
    |> Enum.uniq()
  end

  @spec collect_ids(map(), tuple(), [tuple()], [binary()], pos_integer()) :: {[binary()], map()}
  defp collect_ids(tables, partition, keys, explicit_ids, limit) do
    initial = {[], %{}, %{vector_or_seed: 0}}
    initial = add_ids(initial, normalize_ids(explicit_ids), limit, :vector_or_seed)

    {ids, seen, sources} =
      Enum.reduce_while(keys, initial, fn key, acc ->
        if map_size(elem(acc, 1)) >= limit do
          {:halt, acc}
        else
          posting = lookup_ids(tables.postings, {partition, key})
          {:cont, add_ids(acc, posting, limit, source_axis(key))}
        end
      end)

    {ids, _seen, sources} =
      if map_size(seen) < limit do
        add_ids({ids, seen, sources}, lookup_ids(tables.recent, partition), limit, :recent)
      else
        {ids, seen, sources}
      end

    {Enum.reverse(ids), sources}
  end

  @spec add_ids({[binary()], map(), map()}, [binary()], pos_integer(), term()) ::
          {[binary()], map(), map()}
  defp add_ids({ids, seen, sources}, candidates, limit, source) do
    {ids, seen, added} =
      Enum.reduce_while(candidates, {ids, seen, 0}, fn id, {acc, set, count} ->
        cond do
          map_size(set) >= limit ->
            {:halt, {acc, set, count}}

          Map.has_key?(set, id) ->
            {:cont, {acc, set, count}}

          true ->
            {:cont, {[id | acc], Map.put(set, id, true), count + 1}}
        end
      end)

    {ids, seen, Map.update(sources, source, added, &(&1 + added))}
  end

  @spec lookup_ids(:ets.tid(), term()) :: [binary()]
  defp lookup_ids(table, key) do
    case :ets.lookup(table, key) do
      [{^key, ids}] -> ids
      [] -> []
    end
  end

  @spec fetch_documents(:ets.tid(), [binary()], tuple()) :: [map()]
  defp fetch_documents(table, ids, partition) do
    Enum.flat_map(ids, &fetch_document(table, &1, partition))
  end

  @spec fetch_document(:ets.tid(), binary(), tuple()) :: [map()]
  defp fetch_document(table, id, partition) do
    case :ets.lookup(table, id) do
      [{^id, %{namespace: namespace, scope: scope} = moment}]
      when {namespace, scope} == partition ->
        [moment]

      _missing_or_other_partition ->
        []
    end
  end

  @spec normalize_ids(term()) :: [binary()]
  defp normalize_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp normalize_ids(id) when is_binary(id), do: [id]
  defp normalize_ids(_ids), do: []

  @spec normalize_term(term()) :: binary()
  defp normalize_term(value), do: value |> to_string() |> String.downcase()

  defp source_axis({:term, _value}), do: :lexical
  defp source_axis({:entity, _value}), do: :entity
  defp source_axis({axis, _value}) when axis in [:stream, :task, :kind, :temporal], do: axis
  defp source_axis(_key), do: :other

  @spec emit([atom()], map(), keyword()) :: :ok
  defp emit(event, measurements, opts) do
    Telemetry.emit(event, measurements, %{engine_ref: Keyword.get(opts, :engine_ref)})
  end
end
