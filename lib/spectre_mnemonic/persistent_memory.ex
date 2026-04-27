defmodule SpectreMnemonic.PersistentMemory do
  @moduledoc """
  Multi-backend persistent memory manager.

  Focus keeps hot memory in ETS. This process normalizes durable writes into
  storage envelopes and fans them out to configured adapters according to the
  current persistence policy.
  """

  use GenServer

  require Logger

  alias SpectreMnemonic.Store.{FileStorage, Record}

  @default_store_id :local_file

  @doc "Starts the persistent memory manager."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Persists a family-tagged payload using the configured write policy."
  def append(family, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:append, family, payload, opts})
  end

  @doc "Persists an already-built storage record."
  def put(%Record{} = record, opts \\ []) do
    GenServer.call(__MODULE__, {:put, record, opts})
  end

  @doc "Replays and deduplicates records from stores that advertise replay."
  def replay(opts \\ []) do
    GenServer.call(__MODULE__, {:replay, opts})
  end

  @doc "Looks up one durable record from stores that advertise lookup."
  def get(family, id, opts \\ []) do
    GenServer.call(__MODULE__, {:get, family, id, opts})
  end

  @doc "Searches durable stores that advertise query capabilities."
  def search(cue, opts \\ []) do
    GenServer.call(__MODULE__, {:search, cue, opts})
  end

  @doc "Compacts replayable file stores."
  def compact(opts \\ []) do
    GenServer.call(__MODULE__, {:compact, opts})
  end

  @doc "Returns the active persistent-memory configuration."
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
  def init(_opts), do: {:ok, %{}}

  @impl true
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
      |> Enum.flat_map(&replay_store/1)
      |> dedupe_records()
      |> apply_tombstones()

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
    results =
      opts
      |> effective_config()
      |> replayable_stores()
      |> Enum.filter(&(&1.adapter == FileStorage))
      |> Enum.map(fn store -> {store.id, FileStorage.compact(store.opts)} end)

    {:reply, {:ok, results}, state}
  end

  defp persist(record, opts) do
    cfg = effective_config(opts)
    stores = selected_stores(cfg, record)
    results = Enum.map(stores, &write_store(&1, record))

    case evaluate_results(cfg, stores, results) do
      :ok -> {:ok, %{record: record, stores: results}}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp effective_config(opts) do
    override = Keyword.get(opts, :persistent_memory, [])

    config()
    |> Keyword.merge(override, fn
      :stores, _base, configured -> configured
      _key, _base, configured -> configured
    end)
    |> normalize_config()
  end

  defp defaults do
    [
      write_mode: :all,
      read_mode: :smart,
      failure_mode: :best_effort,
      stores: [
        [
          id: @default_store_id,
          adapter: FileStorage,
          role: :primary,
          duplicate: true,
          opts: [data_root: FileStorage.data_root()]
        ]
      ]
    ]
  end

  defp ensure_stores(config) do
    case Keyword.get(config, :stores, []) do
      [] -> Keyword.put(config, :stores, Keyword.fetch!(defaults(), :stores))
      _stores -> config
    end
  end

  defp normalize_config(config) do
    Keyword.update!(config, :stores, fn stores ->
      stores
      |> Enum.map(&normalize_store/1)
      |> ensure_primary_store()
    end)
  end

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

  defp ensure_primary_store([]), do: []

  defp ensure_primary_store(stores) do
    if Enum.any?(stores, &(&1.role == :primary)) do
      stores
    else
      [first | rest] = stores
      [%{first | role: :primary} | rest]
    end
  end

  defp selected_stores(config, record) do
    stores = Keyword.fetch!(config, :stores)

    config
    |> Keyword.get(:write_mode, :all)
    |> do_selected_stores(stores, record)
    |> Enum.uniq_by(& &1.id)
  end

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

  defp handles_family?(%{families: :all}, _family), do: true
  defp handles_family?(%{families: families}, family), do: family in List.wrap(families)

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

  defp normalize_write_result(:ok), do: :ok
  defp normalize_write_result({:ok, _value}), do: :ok
  defp normalize_write_result({:error, reason}), do: {:error, reason}
  defp normalize_write_result(other), do: {:error, {:unexpected_adapter_result, other}}

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

  defp replayable_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store ->
      :replay in safe_capabilities(store)
    end)
  end

  defp lookup_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store ->
      :lookup in safe_capabilities(store)
    end)
  end

  defp searchable_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store ->
      capabilities = safe_capabilities(store)

      Enum.any?([:search, :vector_search, :fulltext_search], &(&1 in capabilities))
    end)
  end

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

  defp replay_store(store) do
    if function_exported?(store.adapter, :replay, 1) do
      case store.adapter.replay(store.opts) do
        {:ok, frames} -> Enum.map(frames, &frame_record/1)
        {:error, reason} -> [%{store: store.id, error: reason}]
      end
    else
      []
    end
  end

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

  defp tag_search_result(result, store_id) when is_map(result),
    do: Map.put_new(result, :store, store_id)

  defp tag_search_result(result, store_id), do: %{store: store_id, result: result}

  defp frame_record({_seq, _timestamp, %Record{} = record}), do: record

  defp frame_record({_seq, _timestamp, {family, payload}}),
    do: build_record(family, :put, payload, [])

  defp frame_record(%Record{} = record), do: record
  defp frame_record(other), do: other

  defp dedupe_records(records) do
    records
    |> Enum.filter(&match?(%Record{}, &1))
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.dedupe_key)
    |> Enum.reverse()
  end

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

  defp safe_capabilities(store) do
    try do
      store.adapter.capabilities(store.opts)
    rescue
      _exception -> []
    end
  end

  defp emit_write_event(store, record, result, duration) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute(
        [:spectre_mnemonic, :persistent_memory, :write],
        %{duration: duration},
        %{store: store.id, family: record.family, result: result}
      )
    end
  end

  defp payload_id(%{id: id}) when is_binary(id), do: id
  defp payload_id(%{id: id}) when is_atom(id), do: Atom.to_string(id)
  defp payload_id(_payload), do: nil

  defp id(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
end
