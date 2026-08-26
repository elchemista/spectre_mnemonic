defmodule SpectreMnemonic.Persistence.Compaction do
  @moduledoc false

  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Config
  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.RecordBuilder
  alias SpectreMnemonic.Persistence.Replay
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.Writer
  alias SpectreMnemonic.Telemetry

  @type store :: Config.store()
  @type config :: Config.t()

  @spec run(config(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(config, opts) do
    Telemetry.span([:compaction], Telemetry.metadata(opts), fn -> do_run(config, opts) end)
  end

  defp do_run(config, opts) do
    case mode(opts, config) do
      :physical ->
        {:ok, physical(config, opts)}

      :semantic ->
        {:ok, semantic(config, opts)}

      :all ->
        semantic = semantic(config, opts)
        physical = physical(config, opts)
        {:ok, %{mode: :all, semantic: semantic, physical: physical}}

      invalid ->
        {:error, {:invalid_compact_mode, invalid}}
    end
  end

  @spec mode(keyword(), config()) :: :physical | :semantic | :all | term()
  def mode(opts, config),
    do: Keyword.get(opts, :mode) || Keyword.get(config, :compact_mode, :physical)

  @spec physical(config(), keyword()) :: [{term(), {:ok, Path.t()} | {:error, term()}}]
  def physical(config, opts) do
    config
    |> Config.replayable_stores()
    |> Enum.filter(&(&1.adapter == StoreFile))
    |> Enum.map(fn store ->
      compact_opts =
        Keyword.merge(store.opts, Keyword.take(opts, [:retain_compacted_segments, :erase?]))

      {store.id, StoreFile.compact(compact_opts)}
    end)
  end

  @spec semantic(config(), keyword()) :: map()
  def semantic(config, opts) do
    results =
      config
      |> Keyword.fetch!(:stores)
      |> Enum.map(&semantic_store(&1, config, opts))

    %{
      mode: :semantic,
      results: results,
      written: sum_result(results, :written),
      tombstones: sum_result(results, :tombstones)
    }
  end

  defp semantic_store(store, config, opts) do
    capabilities = Config.safe_capabilities(store)

    cond do
      :semantic_compact in capabilities and
          function_exported?(store.adapter, :semantic_compact, 2) ->
        {store.id, native_semantic_compact(store, config, opts)}

      Config.replay_supported?(store, capabilities) and not is_nil(adapter(config, opts)) ->
        {store.id, replay_semantic_compact(store, config, opts)}

      Config.replay_supported?(store, capabilities) ->
        {store.id, {:skipped, :semantic_adapter_not_configured}}

      true ->
        {store.id, {:skipped, :semantic_compact_not_supported}}
    end
  end

  defp native_semantic_compact(store, config, opts) do
    input = semantic_input(store, [], config, opts)

    case store.adapter.semantic_compact(input, store.opts) do
      {:ok, result} when is_map(result) ->
        result
        |> Map.put_new(:mode, :semantic)
        |> Map.put_new(:strategy, :native)
        |> Map.put_new(:written, 0)
        |> Map.put_new(:tombstones, 0)

      {:ok, other} ->
        %{mode: :semantic, strategy: :native, result: other, written: 0, tombstones: 0}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp replay_semantic_compact(store, config, opts) do
    with records <- Replay.records([store]),
         selected <- select_records(records, config, opts),
         input <- semantic_input(store, selected, config, opts),
         {:ok, output} <- run_adapter(input, config, opts),
         {:ok, plan} <- normalize_output(output, selected, opts),
         {:ok, write_summary} <- write_plan(store, plan) do
      %{
        mode: :semantic,
        strategy: plan.strategy,
        input: length(selected),
        written: write_summary.written,
        tombstones: write_summary.tombstones,
        skipped: write_summary.skipped
      }
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp semantic_input(store, records, config, opts) do
    families = families(config, opts)

    %{
      store: %{id: store.id, role: store.role, adapter: store.adapter, families: store.families},
      records: records,
      records_by_family: Enum.group_by(records, & &1.family),
      families: families,
      limit: limit(config, opts),
      opts: opts
    }
  end

  defp select_records(records, config, opts) do
    families = families(config, opts)
    limit = limit(config, opts)

    records
    |> Enum.filter(&(&1.family in families and Scope.match?(&1, opts)))
    |> Enum.sort_by(&{-record_priority(&1), DateTime.to_unix(&1.inserted_at, :microsecond)})
    |> Enum.take(limit)
  end

  defp run_adapter(input, config, opts), do: with_adapter(adapter(config, opts), input, opts)

  defp adapter(config, opts),
    do:
      Keyword.get(opts, :semantic_compact_adapter) ||
        Keyword.get(config, :semantic_compact_adapter)

  defp with_adapter(module, input, opts) do
    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :compact, 2) do
      module.compact(input, opts) |> normalize_adapter_result()
    else
      {:error, {:invalid_semantic_compact_adapter, module}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_adapter_result({:ok, output}), do: {:ok, output}
  defp normalize_adapter_result({:error, reason}), do: {:error, reason}

  defp normalize_adapter_result(other),
    do: {:error, {:unexpected_semantic_compact_result, other}}

  defp normalize_output(output, selected, opts) when is_list(output),
    do: normalize_output(%{records: output}, selected, opts)

  defp normalize_output(output, selected, opts) when is_map(output) do
    strategy = Map.get(output, :strategy, Map.get(output, "strategy", :custom))

    with {:ok, records} <-
           normalize_values(semantic_values(output, :records), &semantic_record(&1, opts)),
         {:ok, tombstones} <-
           normalize_values(
             List.flatten([
               semantic_values(output, :tombstones),
               replace_id_tombstones(output, selected)
             ]),
             &semantic_tombstone(&1, opts)
           ) do
      {:ok, %{strategy: strategy, records: records, tombstones: tombstones}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_output(other, _selected, _opts),
    do: {:error, {:invalid_semantic_compact_output, other}}

  defp normalize_values(values, normalizer) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, records} ->
      case normalizer.(value) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        :skip -> {:cont, {:ok, records}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp write_plan(store, plan) do
    compact_records = List.flatten([plan.records, plan.tombstones])

    summary =
      Enum.reduce_while(compact_records, %{written: 0, tombstones: 0, skipped: 0}, fn record,
                                                                                      acc ->
        case Writer.write(store, record) do
          %{result: :ok} ->
            DurableIndex.upsert(record)
            {:cont, write_summary(acc, record)}

          %{result: {:error, reason}} ->
            {:halt, {:error, reason}}
        end
      end)

    case summary do
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  end

  defp write_summary(acc, %{family: :tombstones}),
    do: %{acc | written: acc.written + 1, tombstones: acc.tombstones + 1}

  defp write_summary(acc, _record), do: %{acc | written: acc.written + 1}

  defp semantic_values(output, key) do
    output
    |> Map.get(key, Map.get(output, Atom.to_string(key), []))
    |> List.wrap()
  end

  defp semantic_record(%Record{} = record, opts), do: RecordBuilder.normalize(record, opts)

  defp semantic_record({family, payload}, opts) when is_atom(family) do
    with {:ok, payload} <- RecordBuilder.prepare_payload_context(payload, opts) do
      {:ok,
       RecordBuilder.build(
         family,
         :put,
         payload,
         Keyword.put(opts, :metadata, %{semantic_compacted?: true})
       )}
    end
  end

  defp semantic_record(%{family: family, payload: payload}, opts) when is_atom(family),
    do: semantic_record({family, payload}, opts)

  defp semantic_record(%{"family" => family, "payload" => payload}, opts)
       when is_binary(family) do
    case Family.from_string(family) do
      {:ok, family} -> semantic_record({family, payload}, opts)
      :error -> :skip
    end
  end

  defp semantic_record(_other, _opts), do: :skip

  defp semantic_tombstone(%Record{} = record, opts) do
    case semantic_record(record, opts) do
      {:ok, %Record{family: :tombstones} = tombstone} -> {:ok, tombstone}
      {:ok, %Record{family: family}} -> {:error, {:invalid_tombstone_family, family}}
      other -> other
    end
  end

  defp semantic_tombstone({family, id}, opts) when is_atom(family) and is_binary(id) do
    semantic_record(
      {:tombstones, %{family: family, id: id, forgotten_at: DateTime.utc_now()}},
      opts
    )
  end

  defp semantic_tombstone(%{family: family, id: id}, opts)
       when is_atom(family) and is_binary(id),
       do: semantic_tombstone({family, id}, opts)

  defp semantic_tombstone(%{"family" => family, "id" => id}, opts)
       when is_binary(family) and is_binary(id) do
    case Family.from_string(family) do
      {:ok, family} -> semantic_tombstone({family, id}, opts)
      :error -> :skip
    end
  end

  defp semantic_tombstone(_other, _opts), do: :skip

  defp replace_id_tombstones(output, selected) do
    selected_by_id = Map.new(selected, fn record -> {record.id, record} end)

    output
    |> semantic_values(:replace_ids)
    |> Enum.flat_map(fn id ->
      case Map.fetch(selected_by_id, id) do
        {:ok, record} ->
          [{record.family, RecordBuilder.payload_id(record.payload) || record.source_event_id}]

        :error ->
          []
      end
    end)
    |> Enum.reject(fn {_family, id} -> is_nil(id) end)
  end

  defp families(config, opts) do
    opts
    |> Keyword.get(
      :semantic_compact_families,
      Keyword.get(config, :semantic_compact_families, [])
    )
    |> List.wrap()
  end

  defp limit(config, opts) do
    case Keyword.get(
           opts,
           :semantic_compact_limit,
           Keyword.get(config, :semantic_compact_limit, 1_000)
         ) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> 1_000
    end
  end

  defp record_priority(%Record{payload: %{attention: attention}}) when is_number(attention),
    do: attention

  defp record_priority(%Record{payload: %{metadata: %{confidence: confidence}}})
       when is_number(confidence),
       do: confidence

  defp record_priority(_record), do: 0

  defp sum_result(results, key) do
    Enum.reduce(results, 0, fn
      {_id, result}, acc when is_map(result) -> acc + Map.get(result, key, 0)
      _other, acc -> acc
    end)
  end
end
