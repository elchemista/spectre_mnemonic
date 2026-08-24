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
      resolve_id(id, partition, keys)
    end
  end

  @spec resolve_id(binary() | nil, tuple(), [binary()]) :: {:ok, Moment.t()} | :miss
  defp resolve_id(nil, _partition, _keys), do: :miss

  defp resolve_id(id, partition, keys) do
    case lookup_entity(id, partition) do
      {:ok, entity} ->
        register_aliases(id, partition, keys)
        {:ok, entity}

      :miss ->
        delete_stale_entries(partition, id)
        :miss
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
         {:ok, _loser} <- lookup_entity(loser_id, partition),
         {:ok, association} <- Focus.link(winner_id, :same_as, loser_id, opts) do
      redirect_registry(partition, loser_id, winner.id)
      register(winner)
      {:ok, association}
    else
      :miss -> {:error, :unknown_entity}
      {:error, _reason} = error -> error
    end
  end

  def merge_entities(id, id, _opts), do: {:error, :same_entity_id}

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

    opts
    |> Focus.moments()
    |> Enum.filter(&(&1.kind == :memory_entity and Scope.partition(&1) == partition))
    |> Enum.sort_by(& &1.id)
    |> Enum.find_value(fn entity ->
      entity_keys =
        resolution_keys(
          Map.get(entity.metadata, :canonical, entity.text),
          Map.get(entity.metadata, :aliases, [])
        )

      if Enum.any?(entity_keys, &MapSet.member?(keys, &1)) do
        register(entity)
        entity.id
      end
    end)
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
