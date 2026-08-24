defmodule SpectreMnemonic.Graph.Plasticity do
  @moduledoc """
  Append-only reinforcement and decay for active graph associations.

  Reweighting re-appends the association with the same id and a later
  `inserted_at`; the active ETS table is the materialized latest value.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Persistence.Manager

  @protected_relations [:attached_action, :member_of, :same_as]

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
    with {:ok, opts} <- Identity.put_namespace(opts) do
      factor = bounded(opts, :decay_factor, 0.985)
      floor = bounded(opts, :weight_floor, 0.02)
      now = DateTime.utc_now()
      stale_before = Keyword.get(opts, :used_before, now)

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
        |> :ets.tab2list()
        |> Enum.map(fn {{record_namespace, scope}, _id} -> {record_namespace, scope} end)
        |> Enum.filter(fn {record_namespace, _scope} -> record_namespace == namespace end)
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
    case :ets.lookup(:mnemonic_associations, id) do
      [{^id, %Association{} = association}] ->
        association |> update_association(fun, activated?) |> persist_weight(count, opts)

      [] ->
        {:cont, {:ok, count}}
    end
  end

  @spec persist_weight(Association.t(), non_neg_integer(), keyword()) ::
          {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp persist_weight(updated, count, opts) do
    case Manager.append(:associations, updated, opts) do
      {:ok, _result} ->
        Focus.upsert_association(updated)
        {:cont, {:ok, count + 1}}

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
        metadata: metadata,
        inserted_at: now
    }
  end

  @spec unused_before?(Association.t(), DateTime.t()) :: boolean()
  defp unused_before?(association, %DateTime{} = before) do
    case Map.get(association.metadata, :last_activated_at) do
      %DateTime{} = used -> DateTime.compare(used, before) == :lt
      _missing -> true
    end
  end

  defp unused_before?(_association, _before), do: true

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
end
