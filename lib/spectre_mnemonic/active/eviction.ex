defmodule SpectreMnemonic.Active.Eviction do
  @moduledoc false

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope

  @doc false
  @spec validate_size(map(), keyword()) :: :ok | {:error, term()}
  def validate_size(moment, opts) do
    size = :erlang.external_size(moment)
    scope_limit = Keyword.get(opts, :max_hot_bytes_per_scope, 64 * 1024 * 1024)
    engine_limit = Keyword.get(opts, :max_hot_bytes_per_engine, 512 * 1024 * 1024)
    pinned_limit = Keyword.get(opts, :max_pinned_bytes, 128 * 1024 * 1024)
    namespace = Identity.namespace(moment)
    requested_state = Keyword.get(opts, :memory_state, Keyword.get(opts, :state))

    cond do
      size > scope_limit ->
        {:error, {:mnemonic_limit_exceeded, :max_hot_bytes_per_scope}}

      size > engine_limit ->
        {:error, {:mnemonic_limit_exceeded, :max_hot_bytes_per_engine}}

      requested_state == :pinned and hot_bytes({:pinned, namespace}) + size > pinned_limit ->
        {:error, {:mnemonic_limit_exceeded, :max_pinned_bytes}}

      true ->
        :ok
    end
  end

  @doc false
  @spec replace_bytes([map()], map(), boolean()) :: :ok
  def replace_bytes([old], moment, pinned?) do
    delete_bytes(old.id)
    put_bytes(moment, pinned?)
  end

  def replace_bytes([], moment, pinned?), do: put_bytes(moment, pinned?)

  @doc false
  @spec put_bytes(map(), boolean()) :: :ok
  def put_bytes(moment, pinned?) do
    size = :erlang.external_size(moment)
    partition = Scope.partition(moment)
    namespace = Identity.namespace(moment)
    ETS.insert(:mnemonic_moment_sizes, {moment.id, size, partition, namespace, pinned?})
    adjust_bytes({:scope, partition}, size)
    adjust_bytes({:namespace, namespace}, size)
    if pinned?, do: adjust_bytes({:pinned, namespace}, size)
    :ok
  end

  @doc false
  @spec delete_bytes(binary()) :: :ok
  def delete_bytes(id) do
    case ETS.lookup(:mnemonic_moment_sizes, id) do
      [{^id, size, partition, namespace, pinned?}] ->
        adjust_bytes({:scope, partition}, -size)
        adjust_bytes({:namespace, namespace}, -size)
        if pinned?, do: adjust_bytes({:pinned, namespace}, -size)
        ETS.delete(:mnemonic_moment_sizes, id)

      [{^id, size, partition, namespace}] ->
        adjust_bytes({:scope, partition}, -size)
        adjust_bytes({:namespace, namespace}, -size)
        ETS.delete(:mnemonic_moment_sizes, id)

      [] ->
        :ok
    end

    :ok
  end

  @doc false
  @spec adjust_bytes(tuple(), integer()) :: :ok
  def adjust_bytes(key, delta) do
    ETS.update_counter(:mnemonic_hot_bytes, key, {2, delta, 0, 0}, {key, 0})
    :ok
  end

  @doc false
  @spec increment_count(map()) :: :ok
  def increment_count(moment), do: update_count(moment, 1)

  @doc false
  @spec decrement_count(map()) :: :ok
  def decrement_count(moment), do: update_count(moment, -1)

  @doc false
  @spec count(term()) :: non_neg_integer()
  def count(key) do
    case ETS.lookup(:mnemonic_moment_counts, key) do
      [{^key, count}] when is_integer(count) and count >= 0 -> count
      _missing -> 0
    end
  end

  @doc false
  @spec hot_bytes(tuple()) :: non_neg_integer()
  def hot_bytes(key) do
    case ETS.lookup(:mnemonic_hot_bytes, key) do
      [{^key, bytes}] when is_integer(bytes) and bytes >= 0 -> bytes
      _missing -> 0
    end
  end

  @doc false
  @spec put_index(map(), boolean(), number()) :: true
  def put_index(moment, pinned?, attention) do
    delete_index(moment.id)
    inserted_at = DateTime.to_unix(moment.inserted_at, :microsecond)
    pinned_rank = if pinned?, do: 1, else: 0

    keys = [
      {{:scope, Scope.partition(moment)}, pinned_rank, attention, inserted_at, moment.id},
      {{:namespace, moment.namespace}, pinned_rank, attention, inserted_at, moment.id}
    ]

    Enum.each(keys, &ETS.insert(:mnemonic_moment_eviction, {&1, moment.id}))
    ETS.insert(:mnemonic_moment_eviction_keys, {moment.id, keys})
  end

  @doc false
  @spec delete_index(binary() | map()) :: true
  def delete_index(%{id: id}), do: delete_index(id)

  def delete_index(id) when is_binary(id) do
    case ETS.lookup(:mnemonic_moment_eviction_keys, id) do
      [{^id, keys}] -> Enum.each(keys, &ETS.delete(:mnemonic_moment_eviction, &1))
      [] -> :ok
    end

    ETS.delete(:mnemonic_moment_eviction_keys, id)
  end

  @spec update_count(map(), 1 | -1) :: :ok
  defp update_count(moment, delta) do
    partition = Scope.partition(moment)
    threshold = if delta < 0, do: {2, delta, 0, 0}, else: {2, delta}

    ETS.update_counter(
      :mnemonic_moment_counts,
      {:scope, partition},
      threshold,
      {{:scope, partition}, 0}
    )

    ETS.update_counter(
      :mnemonic_moment_counts,
      {:namespace, moment.namespace},
      threshold,
      {{:namespace, moment.namespace}, 0}
    )

    :ok
  end
end
