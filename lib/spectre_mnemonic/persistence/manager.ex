defmodule SpectreMnemonic.Persistence.Manager do
  @moduledoc """
  Multi-backend persistent memory manager.

  Focus keeps hot memory in ETS. This process normalizes durable writes into
  storage envelopes and fans them out to configured adapters according to the
  current persistence policy.
  """

  use GenServer

  require Logger

  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile

  @default_store_id :local_file
  @type store :: %{
          id: atom() | binary(),
          adapter: module(),
          role: atom() | nil,
          duplicate: boolean(),
          families: :all | [atom()],
          opts: keyword()
        }
  @type config :: keyword()
  @type write_result :: %{store: term(), role: term(), result: :ok | {:error, term()}}
  @type compact_mode :: :physical | :semantic | :all
  @type replay_state :: %{position: non_neg_integer(), records: map()}

  @doc "Starts the persistent memory manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Persists a family-tagged payload using the configured write policy."
  @spec append(atom(), term(), keyword()) ::
          {:ok, %{record: Record.t(), stores: [write_result()]}} | {:error, term()}
  def append(family, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:append, family, payload, opts})
  end

  @doc "Persists an already-built storage record."
  @spec put(Record.t(), keyword()) ::
          {:ok, %{record: Record.t(), stores: [write_result()]}} | {:error, term()}
  def put(%Record{} = record, opts \\ []) do
    GenServer.call(__MODULE__, {:put, record, opts})
  end

  @doc "Replays and deduplicates records from stores that advertise replay."
  @spec replay(keyword()) :: {:ok, [Record.t()]}
  def replay(opts \\ []) do
    GenServer.call(__MODULE__, {:replay, opts})
  end

  @doc "Looks up one durable record from stores that advertise lookup."
  @spec get(atom(), binary(), keyword()) :: {:ok, term()} | {:error, :not_found}
  def get(family, id, opts \\ []) do
    GenServer.call(__MODULE__, {:get, family, id, opts})
  end

  @doc "Searches durable stores that advertise query capabilities."
  @spec search(term(), keyword()) :: {:ok, [map()]}
  def search(cue, opts \\ []) do
    GenServer.call(__MODULE__, {:search, cue, opts})
  end

  @doc """
  Compacts persistent memory.

  Defaults to physical snapshot compaction for backward compatibility.
  Pass `mode: :semantic` to run semantic compaction, or `mode: :all` to run
  semantic compaction followed by physical snapshotting.
  """
  @spec compact(keyword()) ::
          {:ok, [{term(), {:ok, Path.t()} | {:error, term()}}]}
          | {:ok, map()}
          | {:error, term()}
  def compact(opts \\ []) do
    GenServer.call(__MODULE__, {:compact, opts})
  end

  @doc "Returns the active persistent-memory configuration."
  @spec config :: config()
  def config do
    configured = Application.get_env(:spectre_mnemonic, :persistent_memory, [])

    defaults()
    |> Keyword.merge(configured, fn
      :stores, _default, configured -> configured
      _key, _default, configured -> configured
    end)
    |> ensure_stores()
  end

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts), do: {:ok, %{}}

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call({:append, family, payload, opts}, _from, state) do
    record = build_record(family, :put, payload, opts)
    {:reply, persist(record, opts), state}
  end

  def handle_call({:put, record, opts}, _from, state) do
    {:reply, persist(record, opts), state}
  end

  def handle_call({:replay, opts}, _from, state) do
    records =
      opts
      |> effective_config()
      |> replayable_stores()
      |> replay_records()

    {:reply, {:ok, records}, state}
  end

  def handle_call({:get, family, id, opts}, _from, state) do
    result =
      opts
      |> effective_config()
      |> lookup_stores()
      |> find_record(family, id)

    {:reply, result, state}
  end

  def handle_call({:search, cue, opts}, _from, state) do
    results =
      opts
      |> effective_config()
      |> searchable_stores()
      |> Enum.flat_map(&search_store(&1, cue))

    {:reply, {:ok, results}, state}
  end

  def handle_call({:compact, opts}, _from, state) do
    cfg = effective_config(opts)

    reply =
      case compact_mode(opts, cfg) do
        :physical ->
          {:ok, physical_compact(cfg)}

        :semantic ->
          {:ok, semantic_compact(cfg, opts)}

        :all ->
          semantic = semantic_compact(cfg, opts)
          physical = physical_compact(cfg)
          {:ok, %{mode: :all, semantic: semantic, physical: physical}}

        mode ->
          {:error, {:invalid_compact_mode, mode}}
      end

    {:reply, reply, state}
  end

  @spec persist(Record.t(), keyword()) ::
          {:ok, %{record: Record.t(), stores: [write_result()]}} | {:error, term()}
  defp persist(record, opts) do
    cfg = effective_config(opts)
    stores = selected_stores(cfg, record)
    results = Enum.map(stores, &write_store(&1, record))

    case evaluate_results(cfg, stores, results) do
      :ok -> {:ok, %{record: record, stores: results}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_record(atom(), atom(), term(), keyword()) :: Record.t()
  defp build_record(family, operation, payload, opts) do
    now = DateTime.utc_now()
    id = Keyword.get(opts, :record_id) || id("pmem")
    payload_id = payload_id(payload)
    source_event_id = Keyword.get(opts, :source_event_id) || payload_id || id
    dedupe_key = Keyword.get(opts, :dedupe_key) || "#{family}:#{operation}:#{source_event_id}"

    %Record{
      id: id,
      family: family,
      operation: operation,
      payload: payload,
      dedupe_key: dedupe_key,
      inserted_at: now,
      source_event_id: source_event_id,
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }
  end

  @spec effective_config(keyword()) :: config()
  defp effective_config(opts) do
    override = Keyword.get(opts, :persistent_memory, [])

    config()
    |> Keyword.merge(override, fn
      :stores, _base, configured -> configured
      _key, _base, configured -> configured
    end)
    |> normalize_config()
  end

  @spec defaults :: config()
  defp defaults do
    [
      write_mode: :all,
      read_mode: :smart,
      failure_mode: :best_effort,
      compact_mode: :physical,
      semantic_compact_families: [:moments, :knowledge, :summaries, :categories, :associations],
      semantic_compact_limit: 1_000,
      stores: [
        [
          id: @default_store_id,
          adapter: StoreFile,
          role: :primary,
          duplicate: true,
          opts: [data_root: StoreFile.data_root()]
        ]
      ]
    ]
  end

  @spec ensure_stores(config()) :: config()
  defp ensure_stores(config) do
    case Keyword.get(config, :stores, []) do
      [] -> Keyword.put(config, :stores, Keyword.fetch!(defaults(), :stores))
      _stores -> config
    end
  end

  @spec normalize_config(config()) :: config()
  defp normalize_config(config) do
    Keyword.update!(config, :stores, fn stores ->
      stores
      |> Enum.map(&normalize_store/1)
      |> ensure_primary_store()
    end)
  end

  @spec normalize_store(keyword()) :: store()
  defp normalize_store(store) do
    %{
      id: Keyword.fetch!(store, :id),
      adapter: Keyword.fetch!(store, :adapter),
      role: Keyword.get(store, :role),
      duplicate: Keyword.get(store, :duplicate, true),
      families: Keyword.get(store, :families, :all),
      opts: Keyword.get(store, :opts, [])
    }
  end

  @spec ensure_primary_store([store()]) :: [store()]
  defp ensure_primary_store([]), do: []

  defp ensure_primary_store(stores) do
    if Enum.any?(stores, &(&1.role == :primary)) do
      stores
    else
      [first | rest] = stores
      [%{first | role: :primary} | rest]
    end
  end

  @spec selected_stores(config(), Record.t()) :: [store()]
  defp selected_stores(config, record) do
    stores = Keyword.fetch!(config, :stores)

    config
    |> Keyword.get(:write_mode, :all)
    |> do_selected_stores(stores, record)
    |> Enum.uniq_by(& &1.id)
  end

  @spec do_selected_stores(term(), [store()], Record.t()) :: [store()]
  defp do_selected_stores(:all, stores, record) do
    Enum.filter(stores, fn store ->
      store.role == :primary or (store.duplicate and handles_family?(store, record.family))
    end)
  end

  defp do_selected_stores(:primary_only, stores, _record),
    do: Enum.filter(stores, &(&1.role == :primary))

  defp do_selected_stores({:families, rules}, stores, record) do
    routed_ids =
      rules
      |> Keyword.get(record.family, [])
      |> List.wrap()
      |> MapSet.new()

    Enum.filter(stores, fn store ->
      store.role == :primary or MapSet.member?(routed_ids, store.id)
    end)
  end

  defp do_selected_stores(_unknown, stores, record), do: do_selected_stores(:all, stores, record)

  @spec compact_mode(keyword(), config()) :: compact_mode() | term()
  defp compact_mode(opts, cfg) do
    Keyword.get(opts, :mode) || Keyword.get(cfg, :compact_mode, :physical)
  end

  @spec physical_compact(config()) :: [{term(), {:ok, Path.t()} | {:error, term()}}]
  defp physical_compact(cfg) do
    cfg
    |> replayable_stores()
    |> Enum.filter(&(&1.adapter == StoreFile))
    |> Enum.map(fn store -> {store.id, StoreFile.compact(store.opts)} end)
  end

  @spec semantic_compact(config(), keyword()) :: map()
  defp semantic_compact(cfg, opts) do
    results =
      cfg
      |> Keyword.fetch!(:stores)
      |> Enum.map(&semantic_compact_store(&1, cfg, opts))

    %{
      mode: :semantic,
      results: results,
      written: sum_result(results, :written),
      tombstones: sum_result(results, :tombstones)
    }
  end

  @spec semantic_compact_store(store(), config(), keyword()) :: {term(), map() | tuple()}
  defp semantic_compact_store(store, cfg, opts) do
    capabilities = safe_capabilities(store)

    cond do
      :semantic_compact in capabilities and
          function_exported?(store.adapter, :semantic_compact, 2) ->
        {store.id, native_semantic_compact(store, cfg, opts)}

      replay_supported?(store, capabilities) ->
        {store.id, replay_semantic_compact(store, cfg, opts)}

      true ->
        {store.id, {:skipped, :semantic_compact_not_supported}}
    end
  end

  @spec native_semantic_compact(store(), config(), keyword()) :: map() | {:error, term()}
  defp native_semantic_compact(store, cfg, opts) do
    input = semantic_input(store, [], cfg, opts)

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

  @spec replay_semantic_compact(store(), config(), keyword()) :: map() | {:error, term()}
  defp replay_semantic_compact(store, cfg, opts) do
    with records <- replay_records([store]),
         selected <- select_semantic_records(records, cfg, opts),
         input <- semantic_input(store, selected, cfg, opts),
         {:ok, output} <- run_semantic_adapter(input, cfg, opts),
         {:ok, plan} <- normalize_semantic_output(output, selected),
         {:ok, write_summary} <- write_semantic_plan(store, plan) do
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

  @spec semantic_input(store(), [Record.t()], config(), keyword()) :: map()
  defp semantic_input(store, records, cfg, opts) do
    families = semantic_families(cfg, opts)

    %{
      store: %{id: store.id, role: store.role, adapter: store.adapter, families: store.families},
      records: records,
      records_by_family: Enum.group_by(records, & &1.family),
      families: families,
      limit: semantic_limit(cfg, opts),
      opts: opts
    }
  end

  @spec select_semantic_records([Record.t()], config(), keyword()) :: [Record.t()]
  defp select_semantic_records(records, cfg, opts) do
    families = semantic_families(cfg, opts)
    limit = semantic_limit(cfg, opts)

    records
    |> Enum.filter(&(&1.family in families))
    |> Enum.sort_by(&{-record_priority(&1), DateTime.to_unix(&1.inserted_at, :microsecond)})
    |> Enum.take(limit)
  end

  @spec run_semantic_adapter(map(), config(), keyword()) :: {:ok, term()} | {:error, term()}
  defp run_semantic_adapter(input, cfg, opts) do
    case semantic_adapter(cfg, opts) do
      nil -> {:ok, default_semantic_output(input)}
      module -> semantic_with_adapter(module, input, opts)
    end
  end

  @spec semantic_adapter(config(), keyword()) :: module() | nil
  defp semantic_adapter(cfg, opts) do
    Keyword.get(opts, :semantic_compact_adapter) ||
      Keyword.get(cfg, :semantic_compact_adapter)
  end

  @spec semantic_with_adapter(module(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  defp semantic_with_adapter(module, input, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compact, 2) do
      case module.compact(input, opts) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_semantic_compact_result, other}}
      end
    else
      {:error, {:invalid_semantic_compact_adapter, module}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec default_semantic_output(map()) :: map()
  defp default_semantic_output(%{records: records, families: families}) do
    by_family = Enum.group_by(records, & &1.family)

    records =
      families
      |> Enum.flat_map(fn family ->
        family_records = Map.get(by_family, family, [])

        if family_records == [] do
          []
        else
          [
            {:semantic_compaction_jobs,
             %{
               id: "semantic_#{family}_#{System.unique_integer([:positive, :monotonic])}",
               family: family,
               count: length(family_records),
               source_record_ids: Enum.map(family_records, & &1.id),
               inserted_at: DateTime.utc_now()
             }}
          ]
        end
      end)

    %{strategy: :default, records: records, tombstones: []}
  end

  @spec normalize_semantic_output(term(), [Record.t()]) :: {:ok, map()} | {:error, term()}
  defp normalize_semantic_output(output, selected) when is_list(output),
    do: normalize_semantic_output(%{records: output}, selected)

  defp normalize_semantic_output(output, selected) when is_map(output) do
    strategy = Map.get(output, :strategy, Map.get(output, "strategy", :custom))

    records =
      output
      |> semantic_values(:records)
      |> Enum.map(&semantic_record/1)
      |> Enum.reject(&is_nil/1)

    tombstones =
      output
      |> semantic_values(:tombstones)
      |> Kernel.++(replace_id_tombstones(output, selected))
      |> Enum.map(&semantic_tombstone/1)
      |> Enum.reject(&is_nil/1)

    {:ok, %{strategy: strategy, records: records, tombstones: tombstones}}
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_semantic_output(other, _selected),
    do: {:error, {:invalid_semantic_compact_output, other}}

  @spec write_semantic_plan(store(), map()) :: {:ok, map()} | {:error, term()}
  defp write_semantic_plan(store, plan) do
    compact_records = plan.records ++ plan.tombstones

    summary =
      Enum.reduce_while(compact_records, %{written: 0, tombstones: 0, skipped: 0}, fn record,
                                                                                      acc ->
        case write_store(store, record) do
          %{result: :ok} ->
            {:cont, semantic_write_summary(acc, record)}

          %{result: {:error, reason}} ->
            {:halt, {:error, reason}}
        end
      end)

    case summary do
      {:error, reason} -> {:error, reason}
      summary -> {:ok, summary}
    end
  end

  @spec semantic_write_summary(map(), Record.t()) :: map()
  defp semantic_write_summary(acc, %{family: :tombstones}),
    do: %{acc | written: acc.written + 1, tombstones: acc.tombstones + 1}

  defp semantic_write_summary(acc, _record), do: %{acc | written: acc.written + 1}

  @spec semantic_values(map(), atom()) :: [term()]
  defp semantic_values(output, key) do
    output
    |> Map.get(key, Map.get(output, Atom.to_string(key), []))
    |> List.wrap()
  end

  @spec semantic_record(term()) :: Record.t() | nil
  defp semantic_record(%Record{} = record), do: record

  defp semantic_record({family, payload}) when is_atom(family),
    do: build_record(family, :put, payload, metadata: %{semantic_compacted?: true})

  defp semantic_record(%{family: family, payload: payload}) when is_atom(family),
    do: semantic_record({family, payload})

  defp semantic_record(%{"family" => family, "payload" => payload}) when is_binary(family) do
    case Family.from_string(family) do
      {:ok, family} -> semantic_record({family, payload})
      :error -> nil
    end
  end

  @spec semantic_tombstone(term()) :: Record.t() | nil
  defp semantic_tombstone(%Record{} = record), do: record

  defp semantic_tombstone({family, id}) when is_atom(family) and is_binary(id) do
    build_record(:tombstones, :put, %{family: family, id: id, forgotten_at: DateTime.utc_now()},
      metadata: %{semantic_compacted?: true}
    )
  end

  defp semantic_tombstone(%{family: family, id: id}) when is_atom(family) and is_binary(id),
    do: semantic_tombstone({family, id})

  defp semantic_tombstone(%{"family" => family, "id" => id})
       when is_binary(family) and is_binary(id) do
    case Family.from_string(family) do
      {:ok, family} -> semantic_tombstone({family, id})
      :error -> nil
    end
  end

  defp semantic_tombstone(_other), do: nil

  @spec replace_id_tombstones(map(), [Record.t()]) :: [term()]
  defp replace_id_tombstones(output, selected) do
    selected_by_id = Map.new(selected, fn record -> {record.id, record} end)

    output
    |> semantic_values(:replace_ids)
    |> Enum.flat_map(fn id ->
      case Map.fetch(selected_by_id, id) do
        {:ok, record} -> [{record.family, payload_id(record.payload) || record.source_event_id}]
        :error -> []
      end
    end)
    |> Enum.reject(fn {_family, id} -> is_nil(id) end)
  end

  @spec semantic_families(config(), keyword()) :: [atom()]
  defp semantic_families(cfg, opts) do
    opts
    |> Keyword.get(:semantic_compact_families, Keyword.get(cfg, :semantic_compact_families, []))
    |> List.wrap()
  end

  @spec semantic_limit(config(), keyword()) :: non_neg_integer()
  defp semantic_limit(cfg, opts) do
    opts
    |> Keyword.get(:semantic_compact_limit, Keyword.get(cfg, :semantic_compact_limit, 1_000))
    |> max(0)
  end

  @spec record_priority(Record.t()) :: number()
  defp record_priority(%Record{payload: %{attention: attention}}) when is_number(attention),
    do: attention

  defp record_priority(%Record{payload: %{metadata: %{confidence: confidence}}})
       when is_number(confidence),
       do: confidence

  defp record_priority(_record), do: 0

  @spec sum_result([{term(), map() | tuple()}], atom()) :: non_neg_integer()
  defp sum_result(results, key) do
    Enum.reduce(results, 0, fn
      {_id, result}, acc when is_map(result) -> acc + Map.get(result, key, 0)
      _other, acc -> acc
    end)
  end

  @spec handles_family?(store(), atom()) :: boolean()
  defp handles_family?(%{families: :all}, _family), do: true
  defp handles_family?(%{families: families}, family), do: family in List.wrap(families)

  @spec write_store(store(), Record.t()) :: write_result()
  defp write_store(store, record) do
    started = System.monotonic_time()

    result =
      try do
        normalize_write_result(store.adapter.put(record, store.opts))
      rescue
        exception -> {:error, {exception.__struct__, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    duration = System.monotonic_time() - started
    emit_write_event(store, record, result, duration)
    %{store: store.id, role: store.role, result: result}
  end

  @spec normalize_write_result(term()) :: :ok | {:error, term()}
  defp normalize_write_result(:ok), do: :ok
  defp normalize_write_result({:ok, _value}), do: :ok
  defp normalize_write_result({:error, reason}), do: {:error, reason}
  defp normalize_write_result(other), do: {:error, {:unexpected_adapter_result, other}}

  @spec evaluate_results(config(), [store()], [write_result()]) :: :ok | {:error, term()}
  defp evaluate_results(config, stores, results) do
    failure_mode = Keyword.get(config, :failure_mode, :best_effort)

    primary_ids =
      stores |> Enum.filter(&(&1.role == :primary)) |> Enum.map(& &1.id) |> MapSet.new()

    failed =
      Enum.filter(results, fn %{result: result} ->
        match?({:error, _reason}, result)
      end)

    primary_failed =
      Enum.any?(failed, fn %{store: store_id} ->
        MapSet.member?(primary_ids, store_id)
      end)

    cond do
      failed == [] ->
        :ok

      failure_mode == :strict ->
        {:error, {:persistent_memory_failed, failed}}

      primary_failed ->
        {:error, {:primary_persistent_memory_failed, failed}}

      true ->
        Logger.warning("secondary persistent memory write failed: #{inspect(failed)}")
        :ok
    end
  end

  @spec replayable_stores(config()) :: [store()]
  defp replayable_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store ->
      replay_supported?(store, safe_capabilities(store))
    end)
  end

  @spec lookup_stores(config()) :: [store()]
  defp lookup_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store ->
      :lookup in safe_capabilities(store)
    end)
  end

  @spec searchable_stores(config()) :: [store()]
  defp searchable_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store ->
      capabilities = safe_capabilities(store)

      Enum.any?([:search, :vector_search, :fulltext_search], &(&1 in capabilities))
    end)
  end

  @spec find_record([store()], atom(), binary()) :: {:ok, term()} | {:error, :not_found}
  defp find_record([], _family, _id), do: {:error, :not_found}

  defp find_record([store | rest], family, id) do
    if function_exported?(store.adapter, :get, 3) do
      case store.adapter.get(family, id, store.opts) do
        {:ok, result} -> {:ok, result}
        {:error, :not_found} -> find_record(rest, family, id)
        {:error, _reason} -> find_record(rest, family, id)
      end
    else
      find_record(rest, family, id)
    end
  end

  @spec replay_supported?(store(), [SpectreMnemonic.Persistence.Store.Adapter.capability()]) ::
          boolean()
  defp replay_supported?(store, capabilities) do
    (:replay_fold in capabilities and function_exported?(store.adapter, :replay_fold, 3)) or
      (:replay in capabilities and function_exported?(store.adapter, :replay, 1))
  end

  @spec replay_records([store()]) :: [Record.t()]
  defp replay_records(stores) do
    stores
    |> Enum.reduce(replay_state(), &replay_store_into/2)
    |> replay_state_records()
    |> apply_tombstones()
  end

  @spec replay_state :: replay_state()
  defp replay_state, do: %{position: 0, records: %{}}

  @spec replay_store_into(store(), replay_state()) :: replay_state()
  defp replay_store_into(store, state) do
    capabilities = safe_capabilities(store)

    cond do
      replay_fold_supported?(store, capabilities) ->
        replay_store_fold(store, state)

      replay_list_supported?(store, capabilities) ->
        replay_store_list(store, state)

      true ->
        state
    end
  end

  @spec replay_fold_supported?(
          store(),
          [SpectreMnemonic.Persistence.Store.Adapter.capability()]
        ) :: boolean()
  defp replay_fold_supported?(store, capabilities) do
    :replay_fold in capabilities and function_exported?(store.adapter, :replay_fold, 3)
  end

  @spec replay_list_supported?(store(), [SpectreMnemonic.Persistence.Store.Adapter.capability()]) ::
          boolean()
  defp replay_list_supported?(store, capabilities) do
    :replay in capabilities and function_exported?(store.adapter, :replay, 1)
  end

  @spec replay_store_fold(store(), replay_state()) :: replay_state()
  defp replay_store_fold(store, state) do
    case store.adapter.replay_fold(store.opts, state, fn frame, acc ->
           {:cont, absorb_frame(frame, acc)}
         end) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  @spec replay_store_list(store(), replay_state()) :: replay_state()
  defp replay_store_list(store, state) do
    case store.adapter.replay(store.opts) do
      {:ok, frames} -> Enum.reduce(frames, state, &absorb_frame/2)
      {:error, _reason} -> state
    end
  end

  @spec absorb_frame(term(), replay_state()) :: replay_state()
  defp absorb_frame(frame, state) do
    case frame_record(frame) do
      %Record{} = record ->
        position = state.position + 1

        %{
          position: position,
          records: Map.put(state.records, record.dedupe_key, {position, record})
        }

      _other ->
        state
    end
  end

  @spec replay_state_records(replay_state()) :: [Record.t()]
  defp replay_state_records(state) do
    state.records
    |> Map.values()
    |> Enum.sort_by(fn {position, _record} -> position end)
    |> Enum.map(fn {_position, record} -> record end)
  end

  @spec search_store(store(), term()) :: [map()]
  defp search_store(store, cue) do
    if function_exported?(store.adapter, :search, 2) do
      case store.adapter.search(cue, store.opts) do
        {:ok, results} -> Enum.map(results, &tag_search_result(&1, store.id))
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @spec tag_search_result(term(), term()) :: map()
  defp tag_search_result(result, store_id) when is_map(result),
    do: Map.put_new(result, :store, store_id)

  defp tag_search_result(result, store_id), do: %{store: store_id, result: result}

  @spec frame_record(term()) :: Record.t() | term()
  defp frame_record({_seq, _timestamp, %Record{} = record}), do: record

  defp frame_record({_seq, _timestamp, {family, payload}}),
    do: build_record(family, :put, payload, [])

  defp frame_record(%Record{} = record), do: record
  defp frame_record(other), do: other

  @spec apply_tombstones([Record.t()]) :: [Record.t()]
  defp apply_tombstones(records) do
    forgotten =
      records
      |> Enum.filter(&(&1.family == :tombstones))
      |> Enum.flat_map(fn record ->
        case record.payload do
          %{family: family, id: id} -> [{family, id}]
          _other -> []
        end
      end)
      |> MapSet.new()

    Enum.reject(records, fn record ->
      payload_id = payload_id(record.payload)
      MapSet.member?(forgotten, {record.family, payload_id})
    end)
  end

  @spec safe_capabilities(store()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  defp safe_capabilities(store) do
    store.adapter.capabilities(store.opts)
  rescue
    _exception -> []
  end

  @spec emit_write_event(store(), Record.t(), term(), integer()) :: :ok | term()
  defp emit_write_event(store, record, result, duration) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute(
        [:spectre_mnemonic, :persistent_memory, :write],
        %{duration: duration},
        %{store: store.id, family: record.family, result: result}
      )
    end
  end

  @spec payload_id(term()) :: binary() | nil
  defp payload_id(%{id: id}) when is_binary(id), do: id
  defp payload_id(%{id: id}) when is_atom(id), do: Atom.to_string(id)
  defp payload_id(_payload), do: nil

  @spec id(binary()) :: binary()
  defp id(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
end
