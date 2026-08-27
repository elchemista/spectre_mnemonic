defmodule SpectreMnemonic.Persistence.Dedupe do
  @moduledoc false

  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Persistence.Config
  alias SpectreMnemonic.Persistence.RecordBuilder
  alias SpectreMnemonic.Persistence.Replay
  alias SpectreMnemonic.Persistence.Store.Record

  @type state :: %{
          dedupe: map(),
          replay_cache: %{optional(binary()) => true},
          cache: :ets.table()
        }

  @spec new() :: state()
  def new do
    cache =
      :ets.new(:durable_records, [
        :set,
        :private,
        :compressed,
        read_concurrency: true,
        write_concurrency: true
      ])

    %{dedupe: %{}, replay_cache: %{}, cache: cache}
  end

  @spec reset(state()) :: state()
  def reset(state) do
    :ets.delete_all_objects(state.cache)
    %{state | dedupe: %{}, replay_cache: %{}}
  end

  @spec invalidate(state()) :: state()
  def invalidate(state) do
    :ets.delete_all_objects(state.cache)
    %{state | replay_cache: %{}}
  end

  @spec invalidate_all(state()) :: state()
  def invalidate_all(state), do: %{invalidate(state) | dedupe: %{}}

  @spec key(Config.t(), binary()) :: binary()
  def key(config, namespace) do
    stores = Keyword.fetch!(config, :stores)

    {namespace, stores}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec cached_records(keyword(), state(), (Record.t() -> boolean())) ::
          {{:ok, [Record.t()]} | {:error, term()}, state()}
  def cached_records(opts, state, filter) do
    config = Config.effective(opts)
    namespace = Identity.namespace!(opts)
    cache_key = key(config, namespace)

    case ensure_replay_cache(cache_key, config, namespace, state) do
      {:ok, state} ->
        records =
          state
          |> cache_records(cache_key)
          |> Replay.committed_batches()
          |> Replay.hide_batch_markers()
          |> Enum.filter(filter)

        {{:ok, records}, state}

      {:error, failures} ->
        {{:error, {:persistent_memory_replay_failed, failures}}, state}
    end
  end

  @spec fetch(binary(), Config.t(), binary(), state()) ::
          {:ok, map(), state()} | {:error, list()}
  def fetch(cache_key, config, namespace, state) do
    case Map.fetch(state.dedupe, cache_key) do
      {:ok, dedupe} ->
        {:ok, dedupe, state}

      :error ->
        if Map.has_key?(state.replay_cache, cache_key) and cache_loaded?(state, cache_key) do
          dedupe = dedupe_from_records(cache_records(state, cache_key))
          {:ok, dedupe, put_in(state, [:dedupe, cache_key], dedupe)}
        else
          load(cache_key, config, namespace, state)
        end
    end
  end

  @spec lookup(state(), binary(), binary()) :: Record.t() | nil
  def lookup(state, cache_key, dedupe_key) do
    case :ets.lookup(state.cache, {cache_key, dedupe_key}) do
      [{{^cache_key, ^dedupe_key}, record}] -> record
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec remember(state(), binary(), Record.t(), binary(), map()) :: state()
  def remember(state, cache_key, record, digest, dedupe) do
    dedupe = Map.put(dedupe, record.dedupe_key, {digest, record.dedupe_key})
    state = put_in(state, [:dedupe, cache_key], dedupe)
    cache_record_if_loaded(state, cache_key, record)
  end

  defp ensure_replay_cache(cache_key, config, namespace, state) do
    if Map.has_key?(state.replay_cache, cache_key) and cache_loaded?(state, cache_key) do
      {:ok, state}
    else
      case config |> Config.replayable_stores() |> Replay.checked() do
        {:ok, records} ->
          visible = Enum.filter(records, &(&1.namespace in [nil, namespace]))
          cache_replace(state, cache_key, visible)
          {:ok, %{state | replay_cache: Map.put(state.replay_cache, cache_key, true)}}

        {:error, failures} ->
          {:error, failures}
      end
    end
  end

  defp cache_replace(state, cache_key, records) do
    :ets.match_delete(state.cache, {{cache_key, :_}, :_})
    :ets.insert(state.cache, {{cache_key, :__loaded__}, true})

    Enum.each(records, fn record ->
      :ets.insert(state.cache, {{cache_key, cache_record_key(record)}, record})
    end)

    :ok
  end

  defp cache_records(state, cache_key) do
    state.cache
    |> :ets.match_object({{cache_key, :_}, :_})
    |> Enum.flat_map(fn
      {_key, %Record{} = record} -> [record]
      _marker -> []
    end)
    |> Enum.sort_by(fn record ->
      {record_timestamp(record), record.id, record.dedupe_key || ""}
    end)
  rescue
    ArgumentError -> []
  end

  defp cache_loaded?(state, cache_key) do
    :ets.lookup(state.cache, {cache_key, :__loaded__}) == [{{cache_key, :__loaded__}, true}]
  rescue
    ArgumentError -> false
  end

  defp cache_record_key(record), do: record.dedupe_key || record.id

  defp record_timestamp(%Record{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp record_timestamp(_record), do: 0

  defp cache_record_if_loaded(state, cache_key, record) do
    if Map.has_key?(state.replay_cache, cache_key) do
      :ets.insert(state.cache, {{cache_key, cache_record_key(record)}, record})
      apply_cache_lifecycle(state, cache_key, record)
    end

    state
  end

  defp apply_cache_lifecycle(
         state,
         cache_key,
         %Record{family: :tombstones, payload: payload} = tombstone
       ) do
    case RecordBuilder.tombstone_target(payload) do
      {:ok, {family, id}} ->
        state
        |> cache_records(cache_key)
        |> Enum.each(&maybe_delete_tombstoned_cache(state, cache_key, &1, tombstone, family, id))

      :error ->
        :ok
    end

    :ok
  end

  defp apply_cache_lifecycle(state, cache_key, %Record{family: :erasure_markers}) do
    visible = state |> cache_records(cache_key) |> Replay.apply_erasure_markers()
    cache_replace(state, cache_key, visible)
  end

  defp apply_cache_lifecycle(_state, _cache_key, _record), do: :ok

  defp maybe_delete_tombstoned_cache(state, cache_key, record, tombstone, family, id) do
    if record.namespace == tombstone.namespace and record.scope == tombstone.scope and
         record.family == family and RecordBuilder.payload_id(record.payload) == id do
      :ets.delete(state.cache, {cache_key, cache_record_key(record)})
    else
      :ok
    end
  end

  defp load(cache_key, config, namespace, state) do
    case config |> Config.replayable_stores() |> Replay.checked() do
      {:ok, records} ->
        visible = Enum.filter(records, &(&1.namespace in [nil, namespace]))
        dedupe = dedupe_from_records(visible)
        cache_replace(state, cache_key, visible)

        state =
          state
          |> put_in([:dedupe, cache_key], dedupe)
          |> Map.update!(:replay_cache, &Map.put(&1, cache_key, true))

        {:ok, dedupe, state}

      {:error, failures} ->
        {:error, failures}
    end
  end

  defp dedupe_from_records(records) do
    Map.new(records, fn record ->
      {record.dedupe_key, {RecordBuilder.digest(record), record.dedupe_key}}
    end)
  end
end
