defmodule SpectreMnemonic.Erasure do
  @moduledoc """
  Durable-first physical erasure for one `{namespace, scope}` partition.

  Erasure writes tombstones, rewrites progressive knowledge, installs a durable
  anti-resurrection marker, purges hot projections, and runs erase-mode file
  compaction with no retained previous snapshot or rotated segment.
  """

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Engine.PartitionExecutor
  alias SpectreMnemonic.Erasure.Report
  alias SpectreMnemonic.FailureInjection
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Knowledge.SMEM
  alias SpectreMnemonic.Memory.{Scope, Temporal}
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Recall.Index, as: RecallIndex
  alias SpectreMnemonic.Secrets
  alias SpectreMnemonic.Telemetry

  @internal_families [:tombstones, :erasure_markers]

  @doc "Physically erases exactly one explicitly named partition."
  @spec erase_partition(keyword()) :: {:ok, Report.t()} | {:error, term()}
  def erase_partition(opts) do
    Telemetry.span([:erasure], Telemetry.metadata(opts), fn -> request_erasure(opts) end)
  end

  defp request_erasure(opts) do
    with :ok <- validate_explicit_partition(opts),
         {:ok, opts} <- Identity.put_namespace(opts) do
      PartitionExecutor.trans(
        PartitionExecutor.key(opts),
        fn -> do_erase_partition(opts) end,
        opts
      )
    end
  end

  @spec do_erase_partition(keyword()) :: {:ok, Report.t()} | {:error, term()}
  defp do_erase_partition(opts) do
    with :ok <- FailureInjection.checkpoint(:erasure_begin, opts),
         :ok <- Manager.ensure_erasure_supported(opts),
         {:ok, records} <- Manager.replay(opts),
         marker = latest_marker(records),
         targets = Enum.reject(records, &(&1.family in @internal_families)),
         target_keys = Enum.map(targets, &target_key/1),
         :ok <- write_tombstones(targets, :partition_erasure, opts),
         {:ok, knowledge_events} <- erase_knowledge(opts),
         {:ok, initial_hot} <- Focus.purge_partition(opts),
         {:ok, crypto_shred} <- Secrets.shred_report(Scope.from_opts(opts), opts),
         {:ok, marker_record} <- install_marker(marker, opts),
         :ok <- FailureInjection.checkpoint(:erasure_sealed, opts),
         {:ok, raced_hot} <- Focus.purge_partition(opts),
         {:ok, compaction} <-
           Manager.compact(
             opts
             |> Keyword.put(:mode, :erase)
             |> Keyword.put(:erasure_targets, target_keys)
           ),
         :ok <- validate_compaction(compaction),
         :ok <- DurableIndex.purge_legacy_snapshot(opts),
         :ok <- DurableIndex.rebuild(opts),
         :ok <- RecallIndex.purge_partition(opts),
         :ok <- Manager.verify_erased(target_keys, opts),
         :ok <- SMEM.verify_erased(opts),
         :ok <- Manager.evict_dedupe(opts),
         :ok <- verify_postcondition(opts),
         {:ok, final_hot} <- Focus.purge_partition(opts) do
      {:ok,
       %Report{
         families: targets |> Enum.frequencies_by(& &1.family),
         hot: merge_hot_counts([initial_hot, raced_hot, final_hot]),
         knowledge_events: knowledge_events,
         compaction: :erased,
         marker_id: payload_id(marker_record.payload),
         crypto_shred: crypto_shred,
         already_erased?: not is_nil(marker) and targets == [] and knowledge_events == 0
       }}
    end
  end

  @spec merge_hot_counts([map()]) :: map()
  defp merge_hot_counts(counts) do
    Enum.reduce(counts, %{}, fn count, merged ->
      Map.merge(merged, count, fn _key, left, right -> left + right end)
    end)
  end

  @doc "Forgets currently active records whose `valid_until` has passed."
  @spec sweep_expired(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_expired(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         %DateTime{} = now <- Keyword.get(opts, :now, DateTime.utc_now()),
         {:ok, records} <- Manager.replay(opts),
         expired_ids <- expired_moment_ids(records, now),
         hot_expired_ids <- expired_hot_moment_ids(opts, now),
         {:ok, _active_count} <- Focus.forget(&expired?(&1, now), opts),
         {:ok, remaining} <- Manager.replay(opts),
         targets <- retention_targets(remaining, expired_ids),
         :ok <- write_tombstones(targets, :retention_expired, opts) do
      {:ok, expired_ids |> MapSet.union(hot_expired_ids) |> MapSet.size()}
    else
      {:error, _reason} = error -> error
      now -> {:error, {:invalid_sweep_option, :now, now}}
    end
  end

  @spec expired_hot_moment_ids(keyword(), DateTime.t()) :: MapSet.t(binary())
  defp expired_hot_moment_ids(opts, now) do
    opts
    |> Focus.moments()
    |> Enum.filter(&expired?(&1, now))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  @spec expired_moment_ids([Record.t()], DateTime.t()) :: MapSet.t(binary())
  defp expired_moment_ids(records, now) do
    records
    |> Enum.filter(&(&1.family == :moments and expired?(&1.payload, now)))
    |> Enum.map(&payload_id(&1.payload))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @spec retention_targets([Record.t()], MapSet.t(binary())) :: [Record.t()]
  defp retention_targets(records, expired_ids) do
    signal_ids =
      records
      |> Enum.filter(
        &(&1.family == :moments and MapSet.member?(expired_ids, payload_id(&1.payload)))
      )
      |> Enum.map(&map_value(&1.payload, :signal_id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    root_ids = MapSet.union(expired_ids, signal_ids)

    attached_ids =
      records
      |> Enum.filter(fn record ->
        references_any?(record.payload, root_ids) and record.family == :associations and
          map_value(record.payload, :relation) == :attached_action
      end)
      |> Enum.map(&map_value(&1.payload, :target_id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    all_ids = MapSet.union(root_ids, attached_ids)

    Enum.filter(records, fn record ->
      MapSet.member?(all_ids, payload_id(record.payload)) or
        references_any?(record.payload, all_ids)
    end)
  end

  @spec references_any?(term(), MapSet.t(binary())) :: boolean()
  defp references_any?(payload, ids) when is_map(payload) do
    direct = [
      map_value(payload, :source_id),
      map_value(payload, :target_id),
      map_value(payload, :memory_id),
      map_value(payload, :signal_id)
    ]

    lists =
      List.wrap(map_value(payload, :source_ids)) ++
        List.wrap(map_value(payload, :moment_ids)) ++ provenance_source_ids(payload)

    Enum.any?(direct ++ lists, &MapSet.member?(ids, &1))
  end

  defp references_any?(_payload, _ids), do: false

  @spec provenance_source_ids(map()) :: [term()]
  defp provenance_source_ids(payload) do
    metadata = map_value(payload, :metadata) || %{}
    provenance = if is_map(metadata), do: map_value(metadata, :provenance) || %{}, else: %{}
    if is_map(provenance), do: List.wrap(map_value(provenance, :source_ids)), else: []
  end

  @spec expired?(term(), DateTime.t()) :: boolean()
  defp expired?(memory, now), do: Temporal.expired?(memory, now)

  @doc false
  @spec ensure_durable_write(atom(), keyword()) :: :ok | {:error, :partition_erased}
  def ensure_durable_write(family, opts) do
    if family in @internal_families or Keyword.get(opts, :erasure_internal?, false),
      do: :ok,
      else: ensure_writable(opts)
  end

  @doc false
  @spec ensure_writable(keyword()) ::
          :ok | {:error, :partition_erased | {:erasure_guard_unavailable, term()}}
  def ensure_writable(opts) do
    partition = {Identity.namespace!(opts), Scope.from_opts(opts)}

    case checked_marker_for(partition, opts) do
      {:ok, %{sealed?: true}} -> {:error, :partition_erased}
      {:ok, %{"sealed?" => true}} -> {:error, :partition_erased}
      {:ok, _missing_or_open} -> :ok
      {:error, reason} -> {:error, {:erasure_guard_unavailable, reason}}
    end
  end

  @doc false
  @spec ensure_commit_allowed(Record.t(), keyword()) ::
          :ok | {:error, :partition_erased | :stale_erasure_generation | term()}
  def ensure_commit_allowed(%Record{} = record, opts) do
    if record.family in @internal_families or Keyword.get(opts, :erasure_internal?, false) do
      :ok
    else
      partition = {record.namespace, record.scope}
      record_generation = map_value(record.metadata, :erasure_generation)

      case ETS.lookup(:mnemonic_erasure_markers, partition) do
        [{^partition, :none}] when is_nil(record_generation) -> :ok
        [{^partition, :none}] -> {:error, :stale_erasure_generation}
        [{^partition, marker}] -> validate_commit_marker(marker, record_generation)
        [] -> {:error, {:erasure_guard_unavailable, :marker_not_cached}}
      end
    end
  rescue
    ArgumentError -> {:error, {:erasure_guard_unavailable, :marker_table_unavailable}}
  end

  @spec validate_commit_marker(map(), term()) :: :ok | {:error, atom()}
  defp validate_commit_marker(marker, record_generation) do
    cond do
      map_value(marker, :sealed?) == true -> {:error, :partition_erased}
      marker_generation(marker) == record_generation -> :ok
      true -> {:error, :stale_erasure_generation}
    end
  end

  @doc false
  @spec generation(keyword()) :: binary() | nil
  def generation(opts) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         {:ok, marker} <-
           checked_marker_for({Identity.namespace!(opts), Scope.from_opts(opts)}, opts) do
      marker_generation(marker)
    else
      _unavailable -> nil
    end
  end

  @doc false
  @spec marker(keyword()) :: map() | nil
  def marker(opts) do
    case Identity.put_namespace(opts) do
      {:ok, opts} ->
        case checked_marker_for({Identity.namespace!(opts), Scope.from_opts(opts)}, opts) do
          {:ok, marker} -> marker
          {:error, _reason} -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  @spec checked_marker_for(tuple(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  defp checked_marker_for(partition, opts) do
    case ETS.lookup(:mnemonic_erasure_markers, partition) do
      [{^partition, :none}] -> {:ok, nil}
      [{^partition, marker}] -> {:ok, marker}
      [] -> load_marker(partition, opts)
    end
  rescue
    ArgumentError -> {:error, :marker_table_unavailable}
  end

  @spec load_marker(tuple(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  defp load_marker(partition, opts) do
    case Manager.replay(opts) do
      {:ok, records} ->
        records
        |> latest_marker()
        |> case do
          %Record{payload: marker} ->
            ETS.insert(:mnemonic_erasure_markers, {partition, marker})
            {:ok, marker}

          nil ->
            ETS.insert(:mnemonic_erasure_markers, {partition, :none})
            {:ok, nil}
        end

      {:error, reason} ->
        {:error, {:marker_replay_failed, reason}}
    end
  rescue
    ArgumentError -> {:error, :marker_table_unavailable}
  end

  @spec validate_explicit_partition(term()) :: :ok | {:error, term()}
  defp validate_explicit_partition(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) -> {:error, :invalid_erasure_options}
      not Keyword.has_key?(opts, :namespace) -> {:error, :erasure_namespace_required}
      not Keyword.has_key?(opts, :scope) -> {:error, :erasure_scope_required}
      true -> :ok
    end
  end

  defp validate_explicit_partition(_opts), do: {:error, :invalid_erasure_options}

  @spec write_tombstones([Record.t()], atom(), keyword()) :: :ok | {:error, term()}
  defp write_tombstones(records, reason, opts) do
    now = DateTime.utc_now()
    internal_opts = Keyword.put(opts, :erasure_internal?, true)

    Enum.reduce_while(records, :ok, fn record, :ok ->
      id = payload_id(record.payload) || record.source_event_id || record.id

      payload = %{
        family: record.family,
        id: id,
        forgotten_at: now,
        reason: reason
      }

      case Manager.append(:tombstones, payload, internal_opts) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec erase_knowledge(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp erase_knowledge(opts) do
    with {:ok, events} <- SMEM.replay(opts),
         marker = knowledge_erasure_marker(opts),
         {:ok, _written} <- SMEM.replace([marker], Keyword.put(opts, :erasure_internal?, true)) do
      {:ok, length(events)}
    end
  end

  @spec knowledge_erasure_marker(keyword()) :: map()
  defp knowledge_erasure_marker(opts) do
    namespace = Identity.namespace!(opts)
    scope = Scope.from_opts(opts)
    digest = scope_digest(namespace, scope)

    %{
      id: "knowledge_erase_#{binary_part(digest, 0, 24)}",
      namespace: namespace,
      scope: scope,
      type: :compaction_marker,
      metadata: %{erasure?: true, scope_digest: digest},
      inserted_at: DateTime.utc_now()
    }
  end

  @spec validate_compaction(term()) :: :ok | {:error, term()}
  defp validate_compaction(results) when is_list(results) do
    failures =
      Enum.flat_map(results, fn
        {_store, {:ok, _path}} -> []
        {store, {:error, reason}} -> [{store, reason}]
        other -> [{:unknown, other}]
      end)

    if failures == [], do: :ok, else: {:error, {:erasure_compaction_failed, failures}}
  end

  defp validate_compaction(other), do: {:error, {:erasure_compaction_failed, other}}

  @spec install_marker(Record.t() | nil, keyword()) :: {:ok, Record.t()} | {:error, term()}
  defp install_marker(_existing, opts) do
    now = DateTime.utc_now()
    namespace = Identity.namespace!(opts)
    scope = Scope.from_opts(opts)
    id = marker_id(namespace, scope)

    payload = %{
      id: id,
      generation: Identity.generate("erase_generation", opts),
      namespace: namespace,
      scope: scope,
      scope_digest: scope_digest(namespace, scope),
      erased_at: now,
      sealed?: Keyword.get(opts, :sealed, true)
    }

    internal_opts =
      opts
      |> Keyword.put(:erasure_internal?, true)
      |> Keyword.put(:record_id, id)

    with {:ok, %{record: record}} <- Manager.append(:erasure_markers, payload, internal_opts) do
      ETS.insert(:mnemonic_erasure_markers, {{namespace, scope}, payload})
      {:ok, record}
    end
  end

  @spec verify_postcondition(keyword()) :: :ok | {:error, term()}
  defp verify_postcondition(opts) do
    with {:ok, records} <- Manager.replay(opts),
         {:ok, knowledge} <- SMEM.replay(opts) do
      survivors = Enum.reject(records, &(&1.family == :erasure_markers))

      if survivors == [] and knowledge == [],
        do: :ok,
        else: {:error, {:erasure_postcondition_failed, length(survivors), length(knowledge)}}
    end
  end

  @spec latest_marker([Record.t()]) :: Record.t() | nil
  defp latest_marker(records) do
    records
    |> Enum.filter(&(&1.family == :erasure_markers))
    |> Enum.max_by(&record_time/1, fn -> nil end)
  end

  @spec record_time(Record.t()) :: integer()
  defp record_time(%Record{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp record_time(_record), do: 0

  @spec marker_generation(term()) :: binary() | nil
  defp marker_generation(marker) when is_map(marker) do
    case map_value(marker, :generation) do
      generation when is_binary(generation) and generation != "" -> generation
      _missing -> nil
    end
  end

  defp marker_generation(_marker), do: nil

  @spec marker_id(binary(), term()) :: binary()
  defp marker_id(namespace, scope),
    do: "erase_#{binary_part(scope_digest(namespace, scope), 0, 24)}"

  @spec scope_digest(binary(), term()) :: binary()
  defp scope_digest(namespace, scope) do
    {namespace, scope}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec payload_id(term()) :: binary() | nil
  defp payload_id(payload) when is_map(payload),
    do: Map.get(payload, :id) || Map.get(payload, "id")

  defp payload_id(_payload), do: nil

  @spec map_value(map(), atom()) :: term()
  defp map_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @spec target_key(Record.t()) :: {atom(), binary()}
  defp target_key(record) do
    {record.family, payload_id(record.payload) || record.source_event_id || record.id}
  end
end
