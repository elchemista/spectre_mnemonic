defmodule SpectreMnemonic.Persistence.Manager do
  @moduledoc """
  Multi-backend persistent memory manager.

  Focus keeps hot memory in ETS. This process normalizes durable writes into
  storage envelopes and fans them out to configured adapters according to the
  current persistence policy.

  The manager is the boundary between domain memory structs and infrastructure.
  Callers pass family-tagged payloads or `%SpectreMnemonic.Persistence.Store.Record{}`
  envelopes; configured store adapters decide how those records are written,
  replayed, searched, or compacted.

  A minimal configuration writes to the local append-only file store:

      config :spectre_mnemonic,
        data_root: "mnemonic_data",
        persistent_memory: [
          stores: [
            [id: :local_file, adapter: SpectreMnemonic.Persistence.Store.File, role: :primary]
          ]
        ]

  Multiple stores can be configured with roles, duplicate policies, and family
  filters. The write result reports each store outcome so callers can diagnose
  partial failures without losing the normalized record.
  """

  use GenServer

  alias SpectreMnemonic.Durable.Index, as: DurableIndex
  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Erasure
  alias SpectreMnemonic.FailureInjection
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Compaction
  alias SpectreMnemonic.Persistence.Config
  alias SpectreMnemonic.Persistence.Dedupe
  alias SpectreMnemonic.Persistence.PrimaryWriter
  alias SpectreMnemonic.Persistence.Receipt
  alias SpectreMnemonic.Persistence.RecordBuilder
  alias SpectreMnemonic.Persistence.Repair
  alias SpectreMnemonic.Persistence.Replay
  alias SpectreMnemonic.Persistence.Runtime, as: PersistenceRuntime
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.Writer
  alias SpectreMnemonic.SearchResult
  alias SpectreMnemonic.Telemetry

  @type store :: %{
          id: atom() | binary(),
          adapter: module(),
          role: atom() | nil,
          duplicate: boolean(),
          families: :all | [atom()],
          opts: keyword()
        }
  @type config :: keyword()
  @type write_result :: %{
          store: term(),
          role: term(),
          result: :ok | :pending | {:error, term()}
        }
  @type compact_mode :: :physical | :semantic | :all | :erase
  @typep manager_state :: Dedupe.state()

  @doc "Starts the persistent memory manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Persists a family-tagged payload using the configured write policy.

  `append/3` builds the storage envelope for you. Use it from application code
  when the payload is already a domain struct or map and belongs to a known
  persistent family such as `:moments`, `:knowledge`, `:observations`, or
  `:mental_models`.

  ## Example

      iex> SpectreMnemonic.Persistence.Manager.append(:knowledge, %{id: "k1", text: "Use retries sparingly"})
      {:ok, %{record: %SpectreMnemonic.Persistence.Store.Record{}, stores: _stores}}
  """
  @spec append(atom(), term(), keyword()) ::
          {:ok, %{record: Record.t(), stores: [write_result()]}} | {:error, term()}
  def append(family, payload, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      opts = Keyword.put(opts, :scope, RecordBuilder.context_scope(payload, opts))

      with :ok <- Erasure.ensure_durable_write(family, opts) do
        opts = RecordBuilder.put_erasure_generation(opts)

        write_call(
          {:append, family, payload, opts},
          opts,
          operation_timeout(opts, :write_timeout)
        )
      end
    end
  end

  @doc """
  Persists an already-built storage record.

  Use `put/2` when an upstream caller has already assigned ids, operation,
  dedupe keys, provenance, or metadata and wants the manager to fan that exact
  envelope out to configured stores.

  ## Example

      iex> record = %SpectreMnemonic.Persistence.Store.Record{
      ...>   id: "pmem_1",
      ...>   family: :knowledge,
      ...>   operation: :put,
      ...>   payload: %{id: "k1", text: "Operator prefers short answers"},
      ...>   dedupe_key: "knowledge:k1",
      ...>   inserted_at: DateTime.utc_now()
      ...> }
      iex> SpectreMnemonic.Persistence.Manager.put(record)
      {:ok, %{record: ^record, stores: _stores}}
  """
  @spec put(Record.t(), keyword()) ::
          {:ok, %{record: Record.t(), stores: [write_result()]}} | {:error, term()}
  def put(%Record{} = record, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         :ok <- Erasure.ensure_durable_write(record.family, opts) do
      opts = RecordBuilder.put_erasure_generation(opts)
      write_call({:put, record, opts}, opts, operation_timeout(opts, :write_timeout))
    end
  end

  @doc """
  Replays and deduplicates records from stores that advertise replay.

  Replay is the recovery path used by durable indexes and startup tooling. It
  folds append-only frames from each replayable store, keeps the latest state by
  family/id, and hides tombstoned records.

  ## Example

      iex> SpectreMnemonic.Persistence.Manager.replay()
      {:ok, [%SpectreMnemonic.Persistence.Store.Record{} | _]}
  """
  @spec replay(keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def replay(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call({:replay, opts}, opts, operation_timeout(opts, :replay_timeout))
    end
  end

  @doc false
  @spec replay_fold(keyword(), acc, (Record.t(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def replay_fold(opts \\ [], acc, fun) when is_function(fun, 2) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call(
        {:replay_fold, opts, acc, fun},
        opts,
        operation_timeout(opts, :replay_timeout)
      )
    end
  end

  @doc false
  @spec replay_all(keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def replay_all(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call({:replay_all, opts}, opts, operation_timeout(opts, :replay_timeout))
    end
  end

  @doc """
  Looks up one durable record from stores that advertise lookup.

  Stores are queried in configured order. The first `{:ok, record}` wins; missing
  or unsupported lookups continue to the next store.

  ## Example

      iex> SpectreMnemonic.Persistence.Manager.get(:knowledge, "k1")
      {:ok, _record}
  """
  @spec get(atom(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(family, id, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call({:get, family, id, opts}, opts, operation_timeout(opts, :read_timeout))
    end
  end

  @doc """
  Searches durable stores that advertise query capabilities.

  The manager merges results from the local durable index and any store adapter
  with `:search`, `:vector_search`, or `:fulltext_search` capability. Results are
  tagged by store before being returned.

  ## Example

      iex> SpectreMnemonic.Persistence.Manager.search("retry policy", limit: 10)
      {:ok, _results}
  """
  @spec search(term(), keyword()) :: {:ok, [SearchResult.t()]} | {:error, term()}
  def search(cue, opts \\ []) do
    case search_with_diagnostics(cue, opts) do
      {:ok, results, _diagnostics} -> {:ok, results}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec search_with_diagnostics(term(), keyword()) ::
          {:ok, [SearchResult.t()], map()} | {:error, term()}
  def search_with_diagnostics(cue, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      {results, diagnostics} = search_records_with_diagnostics(cue, opts)
      {:ok, results, diagnostics}
    end
  end

  @doc """
  Compacts persistent memory.

  Defaults to physical snapshot compaction for backward compatibility.
  Pass `mode: :semantic` to run semantic compaction, or `mode: :all` to run
  semantic compaction followed by physical snapshotting.

  Physical compaction writes a snapshot of replayable records. Semantic
  compaction gives a configured adapter a selected set of records and lets it
  write replacement records and tombstones.

  ## Examples

      iex> SpectreMnemonic.Persistence.Manager.compact(mode: :physical)
      {:ok, _snapshots}

      iex> SpectreMnemonic.Persistence.Manager.compact(mode: :all)
      {:ok, %{mode: :all, semantic: _semantic, physical: _physical}}
  """
  @spec compact(keyword()) ::
          {:ok, [{term(), {:ok, Path.t()} | {:error, term()}}]}
          | {:ok, map()}
          | {:error, term()}
  def compact(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call({:compact, opts}, opts, operation_timeout(opts, :compact_timeout))
    end
  end

  @doc false
  @spec ensure_erasure_supported(keyword()) :: :ok | {:error, term()}
  def ensure_erasure_supported(opts) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call(
        {:ensure_erasure_supported, opts},
        opts,
        operation_timeout(opts, :erasure_timeout)
      )
    end
  end

  @doc false
  @spec verify_erased([{atom(), binary()}], keyword()) :: :ok | {:error, term()}
  def verify_erased(targets, opts) when is_list(targets) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call(
        {:verify_erased, MapSet.new(targets), opts},
        opts,
        operation_timeout(opts, :erasure_timeout)
      )
    end
  end

  @doc false
  @spec evict_dedupe(keyword()) :: :ok | {:error, term()}
  def evict_dedupe(opts) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      manager_call(
        {:evict_dedupe, opts},
        opts,
        operation_timeout(opts, :erasure_timeout)
      )
    end
  end

  @doc """
  Returns the active persistent-memory configuration.

  Configuration is read from application env and normalized with defaults. This
  is useful in tests and diagnostics because it shows the stores after default
  roles, ids, and adapter options have been applied.

  ## Example

      iex> config = SpectreMnemonic.Persistence.Manager.config()
      iex> Keyword.has_key?(config, :stores)
      true
  """
  @spec config :: config()
  def config do
    Config.load()
  end

  @doc false
  @spec reset_dedupe :: :ok
  def reset_dedupe do
    :ok = PrimaryWriter.reset_all()
    :ok = PersistenceRuntime.reset_all()
    :ok
  end

  @doc false
  @spec empty_state :: manager_state()
  def empty_state, do: Dedupe.new()

  @doc false
  @spec reset_state(manager_state()) :: manager_state()
  def reset_state(state), do: Dedupe.reset(state)

  @impl GenServer
  @spec init(keyword()) :: {:ok, manager_state()}
  def init(_opts), do: {:ok, empty_state()}

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), manager_state()) ::
          {:reply, term(), manager_state()}
  def handle_call(request, _from, state) do
    {reply, state} = execute_request(request, state)
    {:reply, reply, state}
  end

  @doc false
  @spec execute_request(term(), manager_state()) :: {term(), manager_state()}
  def execute_request({:append, family, payload, opts}, state),
    do: execute_write({:append, family, payload, opts}, state)

  def execute_request({:put, record, opts}, state),
    do: execute_write({:put, record, opts}, state)

  def execute_request({:replay, opts}, state) do
    Telemetry.span([:replay], Telemetry.metadata(opts), fn ->
      Dedupe.cached_records(opts, state, &Scope.match?(&1, opts))
    end)
  end

  def execute_request({:replay_fold, opts, acc, fun}, state) do
    Telemetry.span([:replay], Telemetry.metadata(opts), fn ->
      {reply, state} = Dedupe.cached_records(opts, state, fn _record -> true end)

      reply =
        case reply do
          {:ok, records} -> Replay.fold_visible(records, opts, acc, fun)
          {:error, _reason} = error -> error
        end

      {reply, state}
    end)
  end

  def execute_request({:replay_all, opts}, state) do
    Telemetry.span([:replay], Telemetry.metadata(opts), fn ->
      Dedupe.cached_records(opts, state, &Scope.match_namespace?(&1, opts))
    end)
  end

  def execute_request({:get, family, id, opts}, state) do
    result =
      opts
      |> effective_config()
      |> Config.lookup_stores()
      |> find_record(family, id, opts)

    {result, state}
  end

  def execute_request({:search, cue, opts}, state),
    do: {{:ok, search_records(cue, opts)}, state}

  def execute_request({:compact, opts}, state) do
    cfg = effective_config(opts)

    reply =
      case Compaction.mode(opts, cfg) do
        :erase -> {:ok, physical_erase(cfg, opts)}
        _mode -> Compaction.run(cfg, opts)
      end

    state = Dedupe.invalidate_all(state)
    {reply, state}
  end

  def execute_request({:ensure_erasure_supported, opts}, state) do
    failures = opts |> effective_config() |> erasure_support_failures()

    reply =
      if failures == [],
        do: :ok,
        else: {:error, {:erasure_unsupported_stores, failures}}

    {reply, state}
  end

  def execute_request({:verify_erased, targets, opts}, state) do
    namespace = Identity.namespace!(opts)
    scope = Scope.from_opts(opts)

    failures = opts |> effective_config() |> verify_erased_stores(namespace, scope, targets, opts)

    reply = if failures == [], do: :ok, else: {:error, {:erasure_verification_failed, failures}}
    {reply, state}
  end

  def execute_request({:evict_dedupe, opts}, state) do
    _partition = {Identity.namespace!(opts), Scope.from_opts(opts)}
    {:ok, Dedupe.invalidate_all(state)}
  end

  def execute_request(:reset_dedupe, state), do: {:ok, reset_state(state)}

  @doc false
  @spec invalidate_state(manager_state()) :: manager_state()
  def invalidate_state(state), do: Dedupe.invalidate(state)

  @doc false
  @spec execute_write(term(), manager_state()) :: {term(), manager_state()}
  def execute_write({:append, family, payload, opts}, state) do
    case RecordBuilder.prepare_payload_context(payload, opts) do
      {:ok, payload} ->
        record = RecordBuilder.build(family, :put, payload, opts)
        persist_once(record, opts, state)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  def execute_write({:put, record, opts}, state) do
    case RecordBuilder.normalize(record, opts) do
      {:ok, record} ->
        persist_once(record, opts, state)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @spec manager_call(term(), keyword(), timeout()) :: term()
  defp manager_call(request, opts, timeout) do
    case resolve_engine_ref(opts) do
      {:ok, ref} -> PersistenceRuntime.call(ref, request, timeout)
      {:error, _reason} = error -> error
    end
  catch
    :exit, {:timeout, _call} -> {:error, {:persistent_memory_timeout, timeout}}
    :exit, reason -> {:error, {:persistent_memory_manager_unavailable, reason}}
  end

  @spec write_call(term(), keyword(), timeout()) :: term()
  defp write_call(request, opts, timeout) do
    case resolve_engine_ref(opts) do
      {:ok, ref} -> PrimaryWriter.call(ref, request, timeout, opts)
      {:error, _reason} = error -> error
    end
  end

  @spec resolve_engine_ref(keyword()) :: {:ok, Ref.t()} | {:error, term()}
  defp resolve_engine_ref(opts) do
    case Keyword.get(opts, :engine_ref) || Keyword.get(opts, :engine) do
      %Ref{} = ref ->
        {:ok, ref}

      reference when not is_nil(reference) ->
        resolve_reference(reference)

      _missing ->
        resolve_from_namespace(opts)
    end
  end

  @spec resolve_reference(term()) :: {:ok, Ref.t()} | {:error, term()}
  defp resolve_reference(reference) do
    case Engine.resolve(reference) do
      {:ok, runtime} -> {:ok, runtime.config.ref}
      {:error, _reason} = error -> error
    end
  end

  @spec resolve_from_namespace(keyword()) :: {:ok, Ref.t()} | {:error, term()}
  defp resolve_from_namespace(opts) do
    result =
      case Keyword.get(opts, :namespace) do
        namespace when is_binary(namespace) ->
          case Engine.resolve_internal_namespace(namespace) do
            {:ok, _runtime} = found -> found
            {:error, _reason} -> Engine.resolve(SpectreMnemonic.DefaultEngine)
          end

        _missing ->
          Engine.resolve(SpectreMnemonic.DefaultEngine)
      end

    case result do
      {:ok, runtime} -> {:ok, runtime.config.ref}
      {:error, _reason} = error -> error
    end
  end

  @spec operation_timeout(keyword(), atom()) :: timeout()
  defp operation_timeout(opts, key) do
    case Keyword.get(opts, key, :infinity) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> :infinity
    end
  end

  @spec persist_once(Record.t(), keyword(), manager_state()) ::
          {{:ok, map()} | {:error, term()}, manager_state()}
  defp persist_once(record, opts, state) do
    cfg = effective_config(opts)
    config_key = Dedupe.key(cfg, record.namespace)
    digest = RecordBuilder.digest(record)

    case Dedupe.fetch(config_key, cfg, record.namespace, state) do
      {:ok, dedupe, state} ->
        persist_deduped(record, cfg, config_key, digest, dedupe, state, opts)

      {:error, failures} ->
        {{:error, {:persistent_memory_replay_failed, failures}}, state}
    end
  end

  @spec persist_deduped(
          Record.t(),
          config(),
          binary(),
          binary(),
          map(),
          manager_state(),
          keyword()
        ) ::
          {{:ok, map()} | {:error, term()}, manager_state()}
  defp persist_deduped(record, cfg, config_key, digest, dedupe, state, opts) do
    case Map.get(dedupe, record.dedupe_key) do
      {^digest, _dedupe_reference} ->
        previous_record = Dedupe.lookup(state, config_key, record.dedupe_key) || record
        reply = {:ok, Receipt.build(previous_record, [], true)}
        {reply, state}

      {_different_digest, _dedupe_reference} when is_binary(record.dedupe_key) ->
        if String.starts_with?(record.dedupe_key, "op:"),
          do: {{:error, {:operation_id_conflict, record.operation_id}}, state},
          else: persist_and_remember(record, cfg, config_key, digest, dedupe, state, opts)

      _missing_or_changed ->
        persist_and_remember(record, cfg, config_key, digest, dedupe, state, opts)
    end
  end

  @spec persist_and_remember(
          Record.t(),
          config(),
          binary(),
          binary(),
          map(),
          manager_state(),
          keyword()
        ) ::
          {{:ok, map()} | {:error, term()}, manager_state()}
  defp persist_and_remember(record, cfg, config_key, digest, dedupe, state, opts) do
    case persist(record, cfg, opts) do
      {:ok, _result} = reply ->
        {reply, Dedupe.remember(state, config_key, record, digest, dedupe)}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  @spec persist(Record.t(), config(), keyword()) ::
          {:ok, %{record: Record.t(), stores: [write_result()]}} | {:error, term()}
  # The write boundary keeps commit sequencing visible in one place.
  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp persist(record, cfg, opts) do
    # This is the write boundary. Domain code hands us one envelope; stores get
    # fan-out, telemetry, and blame labels. Future cleanup: partial failure
    # policy is still a little too ceremonial.
    with :ok <- Erasure.ensure_commit_allowed(record, opts) do
      stores = selected_stores(cfg, record)
      {primary_stores, replica_stores} = Enum.split_with(stores, &(&1.role == :primary))

      with :ok <-
             FailureInjection.checkpoint(:before_primary_commit, opts, %{
               operation_id: record.operation_id,
               commit_id: record.commit_id
             }),
           primary_results = Enum.map(primary_stores, &Writer.write(&1, record)),
           :ok <- Writer.evaluate(cfg, primary_stores, primary_results) do
        :ok =
          observe_after_primary_commit(opts, %{
            operation_id: record.operation_id,
            commit_id: record.commit_id
          })

        replica_results = Repair.dispatch(replica_stores, primary_stores, record, opts)
        results = primary_results ++ replica_results

        if Enum.all?(primary_results, &(&1.result == :ok)) do
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          if is_nil(record.batch_id) and
               record.family not in [:batch_begins, :batch_commits, :repair_jobs] do
            DurableIndex.upsert(record)
          end

          {:ok, Receipt.build(record, results, false)}
        else
          {:error, {:primary_persistent_memory_failed, primary_results}}
        end
      end
    end
  end

  @spec observe_after_primary_commit(keyword(), map()) :: :ok
  defp observe_after_primary_commit(opts, context) do
    if Keyword.has_key?(opts, :failure_injector) do
      try do
        task =
          Task.Supervisor.async_nolink(SpectreMnemonic.SharedTaskSupervisor, fn ->
            FailureInjection.checkpoint(:after_primary_commit, opts, context)
          end)

        _diagnostic =
          Task.yield(task, Keyword.get(opts, :failure_injection_timeout, 1_000)) ||
            Task.shutdown(task, :brutal_kill)
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  @spec search_records(term(), keyword()) :: [SearchResult.t()]
  defp search_records(cue, opts) do
    {results, _diagnostics} = search_records_with_diagnostics(cue, opts)
    results
  end

  @spec search_records_with_diagnostics(term(), keyword()) :: {[SearchResult.t()], map()}
  defp search_records_with_diagnostics(cue, opts) do
    # Query work is independent of the write coordinator. Running this in the
    # caller prevents one slow adapter search from blocking every append.
    cfg = effective_config(opts)

    {adapter_results, store_statuses} =
      cfg
      |> Config.searchable_stores()
      |> Enum.map(&search_store_with_diagnostics(&1, cue, opts))
      |> Enum.reduce({[], %{}}, fn {store_id, results, status}, {all, statuses} ->
        {results ++ all, Map.put(statuses, store_id, status)}
      end)

    {index_results, index_status} = durable_index_results_with_diagnostics(cue, opts)
    primary = cfg |> Keyword.fetch!(:stores) |> Enum.find(&(&1.role == :primary))

    primary_status =
      case primary do
        nil -> {:error, :primary_store_missing}
        store -> Map.get(store_statuses, store.id, :not_requested)
      end

    results =
      index_results
      |> merge_search_results(adapter_results)
      |> Enum.take(search_limit(opts))

    diagnostics = %{
      durable_index: index_status,
      primary_store: primary_status,
      stores: store_statuses
    }

    {results, diagnostics}
  end

  @spec effective_config(keyword()) :: config()
  defp effective_config(opts), do: Config.effective(opts)

  @spec selected_stores(config(), Record.t()) :: [store()]
  defp selected_stores(config, record), do: Config.selected_stores(config, record)

  @spec physical_erase(config(), keyword()) :: [{term(), {:ok, term()} | {:error, term()}}]
  defp physical_erase(cfg, opts) do
    namespace = Identity.namespace!(opts)
    scope = Scope.from_opts(opts)
    targets = opts |> Keyword.get(:erasure_targets, []) |> MapSet.new()

    cfg
    |> Keyword.fetch!(:stores)
    |> Enum.map(fn store ->
      store_opts = Keyword.merge(store.opts, Keyword.take(opts, [:data_root]))

      result =
        safe_store_call(fn ->
          store.adapter.erase_partition(namespace, scope, targets, store_opts)
        end)

      {store.id, result}
    end)
  end

  @spec erasure_support_failures(config()) :: [map()]
  defp erasure_support_failures(cfg) do
    cfg
    |> Keyword.fetch!(:stores)
    |> Enum.flat_map(fn store ->
      capabilities = Config.safe_capabilities(store)

      missing =
        []
        |> maybe_missing_capability(
          :erase_partition,
          :erase_partition in capabilities and
            function_exported?(store.adapter, :erase_partition, 4)
        )
        |> maybe_missing_capability(
          :verify_erasure,
          :verify_erasure in capabilities and
            function_exported?(store.adapter, :verify_erased, 4)
        )

      if missing == [], do: [], else: [%{store: store.id, missing: Enum.reverse(missing)}]
    end)
  end

  @spec maybe_missing_capability([atom()], atom(), boolean()) :: [atom()]
  defp maybe_missing_capability(missing, _capability, true), do: missing
  defp maybe_missing_capability(missing, capability, false), do: [capability | missing]

  @spec verify_erased_stores(config(), binary(), term(), MapSet.t(), keyword()) :: [map()]
  defp verify_erased_stores(cfg, namespace, scope, targets, opts) do
    cfg
    |> Keyword.fetch!(:stores)
    |> Enum.flat_map(&verify_erased_store(&1, namespace, scope, targets, opts))
  end

  @spec verify_erased_store(store(), binary(), term(), MapSet.t(), keyword()) :: [map()]
  defp verify_erased_store(store, namespace, scope, targets, opts) do
    store_opts = Keyword.merge(store.opts, Keyword.take(opts, [:data_root]))

    case safe_store_call(fn ->
           store.adapter.verify_erased(namespace, scope, targets, store_opts)
         end) do
      :ok -> []
      {:error, reason} -> [%{store: store.id, reason: reason}]
      other -> [%{store: store.id, reason: {:unexpected_erasure_verification, other}}]
    end
  end

  @spec safe_store_call((-> term())) :: term()
  defp safe_store_call(fun) do
    fun.()
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec search_limit(keyword()) :: non_neg_integer()
  defp search_limit(opts) do
    case Keyword.get(opts, :limit, 10) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _invalid -> 10
    end
  end

  @spec find_record([store()], atom(), binary(), keyword()) ::
          {:ok, term()} | {:error, :not_found}
  defp find_record([], _family, _id, _opts), do: {:error, :not_found}

  defp find_record([store | rest], family, id, opts) do
    if function_exported?(store.adapter, :get, 3) do
      safe_store_get(store, family, id)
      |> find_record_result(rest, family, id, opts)
    else
      find_record(rest, family, id, opts)
    end
  end

  @spec safe_store_get(store(), atom(), binary()) :: term()
  defp safe_store_get(store, family, id) do
    store.adapter.get(family, id, store.opts)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec find_record_result(term(), [store()], atom(), binary(), keyword()) ::
          {:ok, term()} | {:error, :not_found}
  defp find_record_result({:ok, result}, rest, family, id, opts) do
    if Scope.match?(result, opts),
      do: {:ok, result},
      else: find_record(rest, family, id, opts)
  end

  defp find_record_result(_error, rest, family, id, opts),
    do: find_record(rest, family, id, opts)

  @spec search_store_with_diagnostics(store(), term(), keyword()) ::
          {term(), [SearchResult.t()], :ok | {:error, term()}}
  defp search_store_with_diagnostics(store, cue, opts) do
    if function_exported?(store.adapter, :search, 2) do
      search_opts = Keyword.merge(store.opts, opts)

      case store.adapter.search(cue, search_opts) do
        {:ok, results} ->
          visible =
            results
            |> Enum.map(&tag_search_result(&1, store.id))
            |> Enum.filter(&search_result_visible?(&1, opts))

          {store.id, visible, :ok}

        {:error, reason} ->
          {store.id, [], {:error, reason}}

        other ->
          {store.id, [], {:error, {:unexpected_adapter_result, other}}}
      end
    else
      {store.id, [], {:error, :search_not_supported}}
    end
  rescue
    exception -> {store.id, [], {:error, {exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason -> {store.id, [], {:error, {kind, reason}}}
  end

  @spec search_result_visible?(map(), keyword()) :: boolean()
  defp search_result_visible?(result, opts) do
    memory = Map.get(result, :record) || Map.get(result, :payload) || result
    Scope.match?(memory, opts)
  end

  @spec durable_index_results_with_diagnostics(term(), keyword()) ::
          {[SearchResult.t()], :ok | {:error, term()}}
  defp durable_index_results_with_diagnostics(cue, opts) do
    case DurableIndex.search_diagnosed(cue, opts) do
      {:ok, results} -> {results, :ok}
      {:error, reason} -> {[], {:error, reason}}
    end
  end

  @spec merge_search_results([SearchResult.t()], [SearchResult.t()]) :: [SearchResult.t()]
  defp merge_search_results(index_results, adapter_results) do
    [index_results, adapter_results]
    |> List.flatten()
    |> Enum.map(&SearchResult.new(&1, source: :persistent))
    |> Enum.uniq_by(&SearchResult.key/1)
    |> Enum.sort_by(fn result ->
      {-result.score, result.id || ""}
    end)
  end

  @spec tag_search_result(term(), term()) :: SearchResult.t()
  defp tag_search_result(result, store_id) when is_map(result),
    do: SearchResult.new(result, source: :persistent, store: store_id)

  defp tag_search_result(result, store_id),
    do: SearchResult.new(result, source: :persistent, store: store_id)
end
