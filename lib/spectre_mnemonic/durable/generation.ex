defmodule SpectreMnemonic.Durable.Generation do
  @moduledoc false

  alias SpectreMnemonic.Persistence.Store.Record

  @spec begin(map(), pid()) :: {{:ok, reference()} | {:error, :rebuild_in_progress}, map()}
  def begin(%{rebuild: nil} = state, caller) do
    ref = make_ref()
    monitor = Process.monitor(caller)

    {{:ok, ref}, %{state | rebuild: %{ref: ref, pending: [], monitor: monitor, transferred: %{}}}}
  end

  def begin(state, _caller), do: {{:error, :rebuild_in_progress}, state}

  @spec track(map(), Record.t()) :: map()
  def track(%{rebuild: %{pending: pending} = rebuild} = state, record),
    do: %{state | rebuild: %{rebuild | pending: [record | pending]}}

  def track(state, _record), do: state

  @spec track_transfer(map(), reference(), atom(), :ets.tid()) :: map()
  def track_transfer(
        %{rebuild: %{ref: ref, transferred: transferred} = rebuild} = state,
        ref,
        name,
        table
      ) do
    %{state | rebuild: %{rebuild | transferred: Map.put(transferred, name, table)}}
  end

  def track_transfer(state, _ref, _name, _table), do: state

  @spec complete(map(), reference()) :: {:ok, [Record.t()], map()} | {:error, :stale_rebuild}
  def complete(%{rebuild: %{ref: ref, pending: pending, monitor: monitor}} = state, ref) do
    Process.demonitor(monitor, [:flush])
    {:ok, Enum.reverse(pending), %{state | rebuild: nil}}
  end

  def complete(_state, _ref), do: {:error, :stale_rebuild}

  @spec fail(map(), reference()) :: {:ok, map()} | {:error, :stale_rebuild}
  def fail(%{rebuild: %{ref: ref, monitor: monitor}} = state, ref) do
    Process.demonitor(monitor, [:flush])
    {:ok, %{state | rebuild: nil}}
  end

  def fail(_state, _ref), do: {:error, :stale_rebuild}

  @spec owner_down(map(), reference()) :: map()
  def owner_down(%{rebuild: %{monitor: monitor, transferred: transferred}} = state, monitor) do
    Enum.each(transferred, fn {_name, table} -> delete_if_owned(table) end)
    %{state | rebuild: nil}
  end

  def owner_down(state, _monitor), do: state

  defp delete_if_owned(table) do
    if :ets.info(table, :owner) == self(), do: :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
