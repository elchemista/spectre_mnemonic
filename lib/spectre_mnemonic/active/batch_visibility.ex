defmodule SpectreMnemonic.Active.BatchVisibility do
  @moduledoc false

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope

  @table :mnemonic_batch_commits
  @context_key {__MODULE__, :batch_id}

  @doc false
  @spec with_batch(binary(), (-> result)) :: result when result: term()
  def with_batch(batch_id, fun) when is_binary(batch_id) and is_function(fun, 0) do
    previous = Process.put(@context_key, batch_id)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc false
  @spec publish(keyword()) :: :ok | {:error, term()}
  def publish(opts) when is_list(opts) do
    case Keyword.get(opts, :batch_id) do
      batch_id when is_binary(batch_id) and batch_id != "" ->
        key = {Identity.namespace!(opts), Scope.from_opts(opts), batch_id}
        true = ETS.insert(@table, {key, true})
        :ok

      _missing ->
        {:error, :mnemonic_batch_id_required}
    end
  rescue
    ArgumentError -> {:error, :mnemonic_batch_visibility_unavailable}
  end

  @doc false
  @spec publish_record(map()) :: :ok
  def publish_record(record) when is_map(record) do
    case batch_id(record) do
      batch_id when is_binary(batch_id) and batch_id != "" ->
        {namespace, scope} = Scope.partition(record)
        true = ETS.insert(@table, {{namespace, scope, batch_id}, true})
        :ok

      _legacy_or_unbatched ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec visible?(term()) :: boolean()
  def visible?(%SpectreMnemonic.Persistence.Store.Record{}), do: true

  def visible?(record) when is_map(record) do
    case batch_id(record) do
      nil ->
        true

      batch_id ->
        Process.get(@context_key) == batch_id or committed?(record, batch_id)
    end
  end

  def visible?(_record), do: true

  @spec committed?(map(), binary()) :: boolean()
  defp committed?(record, batch_id) do
    {namespace, scope} = Scope.partition(record)
    ETS.member(@table, {namespace, scope, batch_id})
  rescue
    ArgumentError -> false
  end

  @spec batch_id(map()) :: binary() | nil
  defp batch_id(record) do
    case Map.get(record, :metadata) || Map.get(record, "metadata") do
      metadata when is_map(metadata) ->
        Map.get(metadata, :batch_id) || Map.get(metadata, "batch_id")

      _missing ->
        nil
    end
  end

  @spec restore(term()) :: term()
  defp restore(nil), do: Process.delete(@context_key)
  defp restore(previous), do: Process.put(@context_key, previous)
end
