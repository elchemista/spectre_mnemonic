defmodule SpectreMnemonic.Graph.Plasticity do
  @moduledoc """
  Append-only reinforcement and decay for active graph associations.

  Reweighting re-appends the association with the same id and a later
  `inserted_at`; the active ETS table is the materialized latest value.
  """

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Persistence.Manager

  @protected_relations [:attached_action, :member_of, :same_as]
  @default_stale_after_ms 30 * 24 * 60 * 60 * 1_000
  @default_persist_interval_ms 60_000

  @doc "Reinforces every association used by the supplied activation paths."
  @spec reinforce(map() | [map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reinforce(paths, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      ids =
        paths
        |> path_values()
        |> Enum.flat_map(&Map.get(&1, :hops, []))
        |> Enum.map(&Map.get(&1, :association_id))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      rate = bounded(opts, :reinforcement_rate, 0.08)
      reweight_ids(ids, opts, fn weight -> weight + rate * (1.0 - weight) end, true)
    end
  end

  @doc "Decays unused association weights toward a configured floor."
  @spec decay(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decay(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         {:ok, stale_before} <- stale_before(opts) do
      factor = bounded(opts, :decay_factor, 0.985)
      floor = bounded(opts, :weight_floor, 0.02)

      ids =
        opts
        |> Focus.associations()
        |> Enum.reject(&(&1.relation in @protected_relations))
        |> Enum.filter(&unused_before?(&1, stale_before))
        |> Enum.map(& &1.id)

      reweight_ids(ids, opts, fn weight -> floor + (weight - floor) * factor end, false)
    end
  end

  @doc false
  @spec decay_all(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decay_all(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      namespace = Identity.namespace!(opts)

      partitions =
        :mnemonic_associations_by_scope
        |> ETS.match({{namespace, :"$1"}, :_})
        |> Enum.map(fn [scope] -> {namespace, scope} end)
        |> Enum.uniq()

      decay_partitions(partitions, opts)
    end
  end

  @spec decay_partitions([tuple()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp decay_partitions(partitions, opts) do
    Enum.reduce_while(partitions, {:ok, 0}, fn {_namespace, scope}, {:ok, total} ->
      decay_partition(scope, total, opts)
    end)
  end

  @spec decay_partition(term(), non_neg_integer(), keyword()) ::
          {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp decay_partition(scope, total, opts) do
    case decay(Keyword.put(opts, :scope, scope)) do
      {:ok, count} -> {:cont, {:ok, total + count}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec reweight_ids([binary()], keyword(), (float() -> float()), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp reweight_ids(ids, opts, fun, activated?) do
    Enum.reduce_while(ids, {:ok, 0}, fn id, {:ok, count} ->
      reweight_id(id, count, opts, fun, activated?)
    end)
  end

  @spec reweight_id(binary(), non_neg_integer(), keyword(), (float() -> float()), boolean()) ::
          {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp reweight_id(id, count, opts, fun, activated?) do
    case ETS.lookup(:mnemonic_associations, id) do
      [{^id, %Association{} = association}]
      when activated? and association.relation in @protected_relations ->
        {:cont, {:ok, count}}

      [{^id, %Association{} = association}] ->
        persist_weight(association, update_association(association, fun, activated?), count, opts)

      [] ->
        {:cont, {:ok, count}}
    end
  end

  @spec persist_weight(Association.t(), Association.t(), non_neg_integer(), keyword()) ::
          {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp persist_weight(original, updated, count, opts) do
    cond do
      updated.weight == original.weight ->
        maybe_touch_hot(original, updated)
        {:cont, {:ok, count}}

      not persist_weight?(updated, opts) ->
        conditional_hot_update(updated, count)

      not persistence_due?(original, opts) ->
        conditional_hot_update(updated, count)

      true ->
        persist_changed_weight(updated, count, opts)
    end
  end

  @spec persist_changed_weight(Association.t(), non_neg_integer(), keyword()) ::
          {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp persist_changed_weight(updated, count, opts) do
    now = DateTime.utc_now()

    persisted = %{
      updated
      | inserted_at: now,
        metadata: Map.put(updated.metadata, :last_persisted_at, now)
    }

    case Manager.append(:associations, persisted, opts) do
      {:ok, _result} ->
        conditional_hot_update(persisted, count)

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @spec update_association(Association.t(), (float() -> float()), boolean()) :: Association.t()
  defp update_association(association, fun, activated?) do
    now = DateTime.utc_now()

    metadata =
      if activated?,
        do: Map.put(association.metadata, :last_activated_at, now),
        else: association.metadata

    %{
      association
      | weight: (association.weight * 1.0) |> fun.() |> max(0.0) |> min(1.0),
        metadata: metadata
    }
  end

  @spec maybe_touch_hot(Association.t(), Association.t()) :: :ok
  defp maybe_touch_hot(original, updated) do
    if original.metadata != updated.metadata,
      do: Focus.upsert_association_if_present(updated)

    :ok
  end

  @spec conditional_hot_update(Association.t(), non_neg_integer()) ::
          {:cont, {:ok, non_neg_integer()}}
  defp conditional_hot_update(updated, count) do
    case Focus.upsert_association_if_present(updated) do
      :ok -> {:cont, {:ok, count + 1}}
      :missing -> {:cont, {:ok, count}}
    end
  end

  @spec persist_weight?(Association.t(), keyword()) :: boolean()
  defp persist_weight?(association, opts) do
    Keyword.get(opts, :persist?, Map.get(association.metadata, :durable?, true)) == true
  end

  @spec persistence_due?(Association.t(), keyword()) :: boolean()
  defp persistence_due?(association, opts) do
    interval = non_negative_integer(opts, :reweight_min_interval_ms, @default_persist_interval_ms)

    case Map.get(association.metadata, :last_persisted_at) do
      %DateTime{} = last -> DateTime.diff(DateTime.utc_now(), last, :millisecond) >= interval
      _missing -> true
    end
  end

  @spec stale_before(keyword()) :: {:ok, DateTime.t()} | {:error, term()}
  defp stale_before(opts) do
    if Keyword.has_key?(opts, :used_before) do
      case Keyword.get(opts, :used_before) do
        %DateTime{} = before -> {:ok, before}
        invalid -> {:error, {:invalid_plasticity_option, :used_before, invalid}}
      end
    else
      stale_before_from_window(opts)
    end
  end

  @spec stale_before_from_window(keyword()) :: {:ok, DateTime.t()} | {:error, term()}
  defp stale_before_from_window(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_ms = Keyword.get(opts, :stale_after_ms, @default_stale_after_ms)

    cond do
      not match?(%DateTime{}, now) ->
        {:error, {:invalid_plasticity_option, :now, now}}

      not (is_integer(stale_after_ms) and stale_after_ms >= 0) ->
        {:error, {:invalid_plasticity_option, :stale_after_ms, stale_after_ms}}

      true ->
        {:ok, DateTime.add(now, -stale_after_ms, :millisecond)}
    end
  end

  @spec unused_before?(Association.t(), DateTime.t()) :: boolean()
  defp unused_before?(association, %DateTime{} = before) do
    case Map.get(association.metadata, :last_activated_at) do
      %DateTime{} = used ->
        DateTime.compare(used, before) == :lt

      _missing ->
        case association.inserted_at do
          %DateTime{} = inserted_at -> DateTime.compare(inserted_at, before) == :lt
          _missing -> false
        end
    end
  end

  @spec path_values(map() | [map()]) :: [map()]
  defp path_values(paths) when is_map(paths), do: Map.values(paths)
  defp path_values(paths) when is_list(paths), do: paths
  defp path_values(_paths), do: []

  @spec bounded(keyword(), atom(), float()) :: float()
  defp bounded(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_number(value) -> (value * 1.0) |> max(0.0) |> min(1.0)
      _invalid -> default
    end
  end

  @spec non_negative_integer(keyword(), atom(), non_neg_integer()) :: non_neg_integer()
  defp non_negative_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end
end
