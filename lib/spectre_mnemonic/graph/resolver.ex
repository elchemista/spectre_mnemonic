defmodule SpectreMnemonic.Graph.Resolver do
  @moduledoc """
  Deterministic, partition-local entity resolution.

  The registry maps normalized canonical names and aliases to one active entity
  moment. It never performs fuzzy matching and never looks outside the requested
  `{namespace, scope}` partition.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Record

  @doc "Normalizes an entity label for exact matching."
  @spec normalize(term()) :: binary()
  def normalize(value) do
    value
    |> to_string()
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  @doc "Resolves a canonical name or alias inside exactly one partition."
  @spec resolve(term(), [term()], keyword()) :: {:ok, Moment.t()} | :miss | {:error, term()}
  def resolve(canonical, aliases \\ [], opts) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      partition = {Identity.namespace!(opts), Scope.from_opts(opts)}
      keys = resolution_keys(canonical, aliases)

      id = registered_id(partition, keys) || seed_from_focus(partition, keys, opts)

      case resolve_id(id, partition, keys, opts) do
        {:ok, entity} -> learn_aliases(entity, keys, opts)
        :miss -> resolve_durable(keys, partition, opts)
      end
    end
  end

  @spec resolve_id(binary() | nil, tuple(), [binary()], keyword()) ::
          {:ok, Moment.t()} | :miss
  defp resolve_id(nil, _partition, _keys, _opts), do: :miss

  defp resolve_id(id, partition, keys, opts) do
    case lookup_entity(id, partition) do
      {:ok, entity} ->
        register_aliases(id, partition, keys)
        {:ok, entity}

      :miss ->
        case durable_entity(id, partition, opts) do
          {:ok, entity} ->
            hydrate_entity(entity, partition, keys, opts)

          :miss ->
            delete_stale_entries(partition, id)
            :miss
        end
    end
  end

  @doc "Registers an entity moment's canonical name and aliases."
  @spec register(Moment.t()) :: :ok | {:error, :not_an_entity}
  def register(%Moment{kind: :memory_entity} = entity) do
    partition = Scope.partition(entity)
    canonical = Map.get(entity.metadata, :canonical, entity.text)
    aliases = Map.get(entity.metadata, :aliases, [])
    register_aliases(entity.id, partition, resolution_keys(canonical, aliases))
    :ok
  end

  def register(_moment), do: {:error, :not_an_entity}

  @doc "Returns the signal already associated with a resolved entity."
  @spec signal_for(Moment.t()) :: term() | nil
  def signal_for(%Moment{signal_id: signal_id}) do
    case :ets.lookup(:mnemonic_signals, signal_id) do
      [{^signal_id, signal}] -> signal
      [] -> nil
    end
  end

  @doc "Adds a partition-local `:same_as` event and redirects registry aliases."
  @spec merge_entities(binary(), binary(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Association.t()} | {:error, term()}
  def merge_entities(winner_id, loser_id, opts) when winner_id != loser_id do
    with {:ok, opts} <- Identity.put_namespace(opts),
         partition <- {Identity.namespace!(opts), Scope.from_opts(opts)},
         {:ok, winner} <- lookup_entity(winner_id, partition),
         {:ok, loser} <- lookup_entity(loser_id, partition) do
      merge_entities_checked(winner, loser, partition, opts)
    else
      :miss -> {:error, :unknown_entity}
      {:error, _reason} = error -> error
    end
  end

  def merge_entities(id, id, _opts), do: {:error, :same_entity_id}

  @spec merge_entities_checked(Moment.t(), Moment.t(), tuple(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Association.t()} | {:error, term()}
  defp merge_entities_checked(winner, loser, partition, opts) do
    case merge_status(winner.id, loser.id, opts) do
      {:existing, association} -> {:ok, association}
      :merge -> create_entity_merge(winner, loser, partition, opts)
      {:error, _reason} = error -> error
    end
  end

  @spec create_entity_merge(Moment.t(), Moment.t(), tuple(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Association.t()} | {:error, term()}
  defp create_entity_merge(winner, loser, partition, opts) do
    loser_keys = entity_keys(loser)
    winner_aliases = Map.get(winner.metadata, :aliases, [])

    with {:ok, winner} <- learn_aliases(winner, loser_keys, opts),
         {:ok, association} <-
           Focus.link(
             winner.id,
             :same_as,
             loser.id,
             Keyword.put(opts, :metadata, %{
               absorbed_aliases: loser_keys,
               winner_aliases_before: winner_aliases
             })
           ) do
      redirect_registry(partition, loser.id, winner.id)
      register(winner)
      {:ok, association}
    end
  end

  @doc "Removes one active `:same_as` merge and restores the loser identity registry."
  @spec unmerge_entities(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def unmerge_entities(winner_id, loser_id, opts) when winner_id != loser_id do
    with {:ok, opts} <- Identity.put_namespace(opts),
         partition <- {Identity.namespace!(opts), Scope.from_opts(opts)},
         {:ok, winner} <- entity_by_id(winner_id, partition, opts),
         {:ok, loser} <- entity_by_id(loser_id, partition, opts),
         {:ok, association} <- same_as_association(winner_id, loser_id, opts),
         :ok <- tombstone_same_as(association, opts),
         {:ok, winner} <- restore_winner_aliases(winner, loser, association, opts),
         :ok <- Focus.drop_association(association) do
      register(winner)
      register(loser)
      :ok
    else
      :miss -> {:error, :unknown_entity}
      {:error, _reason} = error -> error
    end
  end

  def unmerge_entities(id, id, _opts), do: {:error, :same_entity_id}

  @spec entity_by_id(binary(), tuple(), keyword()) :: {:ok, Moment.t()} | :miss
  defp entity_by_id(id, partition, opts) do
    case lookup_entity(id, partition) do
      {:ok, entity} -> {:ok, entity}
      :miss -> durable_entity(id, partition, opts)
    end
  end

  @spec same_as_association(binary(), binary(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Association.t()} | {:error, :merge_not_found | term()}
  defp same_as_association(winner_id, loser_id, opts) do
    hot =
      Enum.find(Focus.associations(opts), fn association ->
        association.relation == :same_as and association.source_id == winner_id and
          association.target_id == loser_id
      end)

    case hot do
      nil -> durable_same_as_association(winner_id, loser_id, opts)
      association -> {:ok, association}
    end
  end

  @spec merge_status(binary(), binary(), keyword()) ::
          :merge | {:existing, SpectreMnemonic.Memory.Association.t()} | {:error, term()}
  defp merge_status(winner_id, loser_id, opts) do
    case same_as_association(winner_id, loser_id, opts) do
      {:ok, association} -> {:existing, association}
      {:error, :merge_not_found} -> validate_new_merge(winner_id, loser_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @spec validate_new_merge(binary(), binary(), keyword()) :: :merge | {:error, term()}
  defp validate_new_merge(winner_id, loser_id, opts) do
    redirects = all_entity_redirects(opts)
    winner_root = follow_redirect(winner_id, redirects, %{})
    loser_root = follow_redirect(loser_id, redirects, %{})

    cond do
      redirect_reaches?(winner_id, loser_id, redirects) ->
        {:error, :entity_merge_cycle}

      redirect_reaches?(loser_id, winner_id, redirects) or winner_root == loser_root ->
        {:error, :entities_already_merged}

      winner_root != winner_id ->
        {:error, {:entity_redirected, winner_id, winner_root}}

      loser_root != loser_id ->
        {:error, {:entity_redirected, loser_id, loser_root}}

      true ->
        :merge
    end
  end

  @spec all_entity_redirects(keyword()) :: map()
  defp all_entity_redirects(opts) do
    durable =
      case Manager.replay(opts) do
        {:ok, records} -> entity_redirects(records)
        {:error, _reason} -> %{}
      end

    Map.merge(durable, hot_entity_redirects(opts))
  end

  @spec redirect_reaches?(binary(), binary(), map()) :: boolean()
  defp redirect_reaches?(from, target, redirects) do
    redirect_reaches?(Map.get(redirects, from), target, redirects, MapSet.new([from]))
  end

  @spec redirect_reaches?(term(), binary(), map(), MapSet.t()) :: boolean()
  defp redirect_reaches?(target, target, _redirects, _seen), do: true
  defp redirect_reaches?(nil, _target, _redirects, _seen), do: false

  defp redirect_reaches?(current, target, redirects, seen) when is_binary(current) do
    if MapSet.member?(seen, current) do
      false
    else
      redirect_reaches?(
        Map.get(redirects, current),
        target,
        redirects,
        MapSet.put(seen, current)
      )
    end
  end

  defp redirect_reaches?(_current, _target, _redirects, _seen), do: false

  @spec durable_same_as_association(binary(), binary(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Association.t()} | {:error, :merge_not_found | term()}
  defp durable_same_as_association(winner_id, loser_id, opts) do
    case Manager.replay(opts) do
      {:ok, records} ->
        records
        |> Enum.find_value(fn
          %Record{
            family: :associations,
            payload:
              %{relation: :same_as, source_id: ^winner_id, target_id: ^loser_id} = association
          } ->
            {:ok, association}

          _record ->
            nil
        end)
        |> case do
          nil -> {:error, :merge_not_found}
          result -> result
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec tombstone_same_as(SpectreMnemonic.Memory.Association.t(), keyword()) ::
          :ok | {:error, term()}
  defp tombstone_same_as(association, opts) do
    payload = %{
      family: :associations,
      id: association.id,
      forgotten_at: DateTime.utc_now(),
      reason: :entity_unmerged
    }

    case Manager.append(:tombstones, payload, opts) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec restore_winner_aliases(
          Moment.t(),
          Moment.t(),
          SpectreMnemonic.Memory.Association.t(),
          keyword()
        ) :: {:ok, Moment.t()} | {:error, term()}
  defp restore_winner_aliases(winner, loser, association, opts) do
    restored_aliases =
      case Map.get(association.metadata, :winner_aliases_before) do
        aliases when is_list(aliases) -> aliases
        _legacy -> Map.get(winner.metadata, :aliases, []) -- entity_keys(loser)
      end

    updated = %{winner | metadata: Map.put(winner.metadata, :aliases, restored_aliases)}

    with :ok <- maybe_persist_aliases(winner, updated, opts),
         :ok <- Focus.hydrate_moment(updated, opts) do
      {:ok, updated}
    end
  end

  @spec resolution_keys(term(), [term()]) :: [binary()]
  defp resolution_keys(canonical, aliases) do
    [canonical | List.wrap(aliases)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @spec registered_id(tuple(), [binary()]) :: binary() | nil
  defp registered_id(partition, keys) do
    Enum.find_value(keys, fn key ->
      case :ets.lookup(:mnemonic_entity_registry, {partition, key}) do
        [{{^partition, ^key}, id}] -> id
        [] -> nil
      end
    end)
  end

  @spec seed_from_focus(tuple(), [binary()], keyword()) :: binary() | nil
  defp seed_from_focus(partition, keys, opts) do
    keys = MapSet.new(keys)
    redirects = hot_entity_redirects(opts)

    opts
    |> Focus.moments()
    |> Enum.filter(&(&1.kind == :memory_entity and Scope.partition(&1) == partition))
    |> Enum.sort_by(& &1.id)
    |> Enum.find_value(&matching_hot_entity_id(&1, keys, redirects, partition))
  end

  @spec matching_hot_entity_id(Moment.t(), MapSet.t(binary()), map(), tuple()) :: binary() | nil
  defp matching_hot_entity_id(entity, keys, redirects, partition) do
    requested? = Enum.any?(entity_keys(entity), &MapSet.member?(keys, &1))

    if requested? do
      winner_id = follow_redirect(entity.id, redirects, %{})
      register_hot_winner(winner_id, partition)
      winner_id
    end
  end

  @spec register_hot_winner(binary(), tuple()) :: :ok | {:error, :not_an_entity}
  defp register_hot_winner(winner_id, partition) do
    case lookup_entity(winner_id, partition) do
      {:ok, winner} -> register(winner)
      :miss -> :ok
    end
  end

  @spec hot_entity_redirects(keyword()) :: map()
  defp hot_entity_redirects(opts) do
    opts
    |> Focus.associations()
    |> Enum.flat_map(fn
      %{relation: :same_as, source_id: winner, target_id: loser}
      when is_binary(winner) and is_binary(loser) ->
        [{loser, winner}]

      _association ->
        []
    end)
    |> Map.new()
  end

  @spec resolve_durable([binary()], tuple(), keyword()) ::
          {:ok, Moment.t()} | :miss | {:error, term()}
  defp resolve_durable(keys, partition, opts) do
    case Manager.replay(opts) do
      {:ok, records} ->
        redirects = entity_redirects(records)

        entity =
          records
          |> durable_entities(partition)
          |> Enum.filter(&entity_matches?(&1, keys))
          |> Enum.sort_by(&entity_order/1)
          |> List.first()
          |> redirected_entity(redirects, records, partition)

        resolve_durable_entity(entity, partition, keys, opts)

      {:error, _reason} = error ->
        error
    end
  end

  @spec resolve_durable_entity(Moment.t() | nil, tuple(), [binary()], keyword()) ::
          {:ok, Moment.t()} | :miss | {:error, term()}
  defp resolve_durable_entity(%Moment{} = entity, partition, keys, opts) do
    with {:ok, entity} <- hydrate_entity(entity, partition, keys, opts) do
      learn_aliases(entity, keys, opts)
    end
  end

  defp resolve_durable_entity(nil, _partition, _keys, _opts), do: :miss

  @spec durable_entity(binary(), tuple(), keyword()) :: {:ok, Moment.t()} | :miss
  defp durable_entity(id, partition, opts) do
    case Manager.replay(opts) do
      {:ok, records} ->
        case Enum.find(durable_entities(records, partition), &(&1.id == id)) do
          %Moment{} = entity -> {:ok, entity}
          nil -> :miss
        end

      {:error, _reason} ->
        :miss
    end
  end

  @spec durable_entities([Record.t()], tuple()) :: [Moment.t()]
  defp durable_entities(records, partition) do
    Enum.flat_map(records, fn
      %Record{family: :moments, payload: %Moment{kind: :memory_entity} = entity} ->
        if Scope.partition(entity) == partition, do: [entity], else: []

      _record ->
        []
    end)
  end

  @spec hydrate_entity(Moment.t(), tuple(), [binary()], keyword()) ::
          {:ok, Moment.t()} | {:error, term()}
  defp hydrate_entity(entity, partition, keys, opts) do
    with :ok <- Focus.hydrate_moment(entity, opts) do
      register_aliases(entity.id, partition, entity_keys(entity) ++ keys)
      {:ok, entity}
    end
  end

  @spec learn_aliases(Moment.t(), [binary()], keyword()) ::
          {:ok, Moment.t()} | {:error, term()}
  defp learn_aliases(entity, keys, opts) do
    canonical = normalize(Map.get(entity.metadata, :canonical, entity.text))
    existing = entity.metadata |> Map.get(:aliases, []) |> Enum.map(&normalize/1)
    aliases = (existing ++ Enum.reject(keys, &(&1 == canonical))) |> Enum.uniq() |> Enum.sort()
    updated = %{entity | metadata: Map.put(entity.metadata, :aliases, aliases)}

    if updated == entity do
      register_aliases(entity.id, Scope.partition(entity), [canonical | aliases])
      {:ok, entity}
    else
      with :ok <- maybe_persist_aliases(entity, updated, opts),
           :ok <- Focus.hydrate_moment(updated, opts) do
        register_aliases(updated.id, Scope.partition(updated), [canonical | aliases])
        {:ok, updated}
      end
    end
  end

  @spec maybe_persist_aliases(Moment.t(), Moment.t(), keyword()) :: :ok | {:error, term()}
  defp maybe_persist_aliases(entity, entity, _opts), do: :ok

  defp maybe_persist_aliases(_entity, updated, opts) do
    if Map.get(updated.metadata, :durable?, false) and Keyword.get(opts, :persist?, true) do
      case Manager.append(:moments, updated, opts) do
        {:ok, _result} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  @spec entity_keys(Moment.t()) :: [binary()]
  defp entity_keys(entity) do
    resolution_keys(
      Map.get(entity.metadata, :canonical, entity.text),
      Map.get(entity.metadata, :aliases, [])
    )
  end

  @spec entity_matches?(Moment.t(), [binary()]) :: boolean()
  defp entity_matches?(entity, keys) do
    requested = MapSet.new(keys)
    Enum.any?(entity_keys(entity), &MapSet.member?(requested, &1))
  end

  @spec entity_order(Moment.t()) :: {integer(), binary()}
  defp entity_order(%Moment{inserted_at: %DateTime{} = inserted_at, id: id}),
    do: {DateTime.to_unix(inserted_at, :microsecond), id}

  defp entity_order(%Moment{id: id}), do: {0, id}

  @spec entity_redirects([Record.t()]) :: map()
  defp entity_redirects(records) do
    records
    |> Enum.flat_map(fn
      %Record{
        family: :associations,
        payload: %{relation: :same_as, source_id: winner, target_id: loser}
      }
      when is_binary(winner) and is_binary(loser) ->
        [{loser, winner}]

      _record ->
        []
    end)
    |> Map.new()
  end

  @spec redirected_entity(Moment.t() | nil, map(), [Record.t()], tuple()) :: Moment.t() | nil
  defp redirected_entity(nil, _redirects, _records, _partition), do: nil

  defp redirected_entity(entity, redirects, records, partition) do
    winner_id = follow_redirect(entity.id, redirects, %{})
    Enum.find(durable_entities(records, partition), &(&1.id == winner_id)) || entity
  end

  @spec follow_redirect(binary(), map(), map()) :: binary()
  defp follow_redirect(id, redirects, seen) do
    case Map.get(redirects, id) do
      next when is_binary(next) ->
        if Map.has_key?(seen, next),
          do: id,
          else: follow_redirect(next, redirects, Map.put(seen, id, true))

      _missing ->
        id
    end
  end

  @spec lookup_entity(binary(), tuple()) :: {:ok, Moment.t()} | :miss
  defp lookup_entity(id, partition) do
    case :ets.lookup(:mnemonic_moments, id) do
      [{^id, %Moment{kind: :memory_entity} = entity}] ->
        if Scope.partition(entity) == partition, do: {:ok, entity}, else: :miss

      _missing ->
        :miss
    end
  end

  @spec register_aliases(binary(), tuple(), [binary()]) :: :ok
  defp register_aliases(id, partition, keys) do
    Enum.each(keys, fn key ->
      :ets.insert(:mnemonic_entity_registry, {{partition, key}, id})
    end)

    :ok
  end

  @spec delete_stale_entries(tuple(), binary()) :: :ok
  defp delete_stale_entries(partition, id) do
    :ets.match_delete(:mnemonic_entity_registry, {{partition, :_}, id})
    :ok
  end

  @spec redirect_registry(tuple(), binary(), binary()) :: :ok
  defp redirect_registry(partition, loser_id, winner_id) do
    :mnemonic_entity_registry
    |> :ets.match_object({{partition, :_}, loser_id})
    |> Enum.each(fn {{^partition, key}, ^loser_id} ->
      :ets.insert(:mnemonic_entity_registry, {{partition, key}, winner_id})
    end)

    :ok
  end
end
