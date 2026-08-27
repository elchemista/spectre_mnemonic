defmodule SpectreMnemonic.Active.Status do
  @moduledoc false

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Active.Repository
  alias SpectreMnemonic.Memory.Scope

  @doc false
  @spec lookup(tuple(), term()) :: {:ok, map()} | {:error, :not_found}
  def lookup(partition, stream_or_task_id) do
    [
      {partition, {:task, stream_or_task_id}},
      {partition, {:stream, stream_or_task_id}}
    ]
    |> Enum.find_value(fn key ->
      case ETS.lookup(:mnemonic_status, key) do
        [{^key, status}] -> {:ok, status}
        [] -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      result -> result
    end
  end

  @doc false
  @spec put(map(), DateTime.t()) :: true | nil
  def put(signal, now) do
    status = %{
      namespace: signal.namespace,
      scope: signal.scope,
      stream: signal.stream,
      task_id: signal.task_id,
      kind: signal.kind,
      status: :active,
      last_input: signal.input,
      updated_at: now
    }

    partition = {signal.namespace, signal.scope}
    ETS.insert(:mnemonic_status, {{partition, {:stream, signal.stream}}, status})

    if signal.task_id,
      do: ETS.insert(:mnemonic_status, {{partition, {:task, signal.task_id}}, status})
  end

  @doc false
  @spec refresh(map()) :: :ok
  def refresh(moment) do
    partition = Scope.partition(moment)
    refresh_key(partition, :stream, moment.stream, :mnemonic_moments_by_stream)

    if moment.task_id do
      refresh_key(partition, :task, moment.task_id, :mnemonic_moments_by_task)
    end

    :ok
  end

  @spec refresh_key(tuple(), :stream | :task, term(), atom()) :: :ok
  defp refresh_key(partition, type, key, index_table) do
    status_key = {partition, {type, key}}
    ETS.delete(:mnemonic_status, status_key)
    {namespace, scope} = partition
    opts = [namespace: namespace, scope: scope]

    index_table
    |> Repository.indexed_ids({partition, key})
    |> Enum.uniq()
    |> Enum.flat_map(&Repository.lookup(:mnemonic_moments, &1))
    |> Enum.filter(&Scope.match?(&1, opts))
    |> Enum.max_by(&DateTime.to_unix(&1.inserted_at, :microsecond), fn -> nil end)
    |> put_latest(status_key, namespace, scope)
  end

  @spec put_latest(map() | nil, tuple(), binary(), term()) :: :ok
  defp put_latest(nil, _status_key, _namespace, _scope), do: :ok

  defp put_latest(latest, status_key, namespace, scope) do
    status = %{
      namespace: namespace,
      scope: scope,
      stream: latest.stream,
      task_id: latest.task_id,
      kind: latest.kind,
      status: :active,
      last_input: latest.input,
      updated_at: latest.inserted_at
    }

    ETS.insert(:mnemonic_status, {status_key, status})
    :ok
  end
end
