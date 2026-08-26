defmodule SpectreMnemonic.Durable.Stats do
  @moduledoc false

  alias SpectreMnemonic.Durable.Documents

  @hidden_states [:forgotten, :contradicted]

  @spec ensure(map()) :: map()
  def ensure(%{dirty?: true} = state) do
    %{state | dirty?: false, stats_revision: state.revision}
    |> Documents.sync_metadata()
  end

  def ensure(state), do: state

  @spec latest_state(term(), :ets.tid() | map()) :: atom() | nil
  def latest_state(state_key, states) when is_map(states) do
    states
    |> Map.get(state_key, [])
    |> latest_state_from_values()
  end

  def latest_state(state_key, lifecycle) do
    lifecycle
    |> :ets.lookup(state_key)
    |> Enum.map(fn {^state_key, value} -> value end)
    |> latest_state_from_values()
  rescue
    ArgumentError -> nil
  end

  @spec hidden?(term(), :ets.tid() | map()) :: boolean()
  def hidden?(state_key, lifecycle), do: latest_state(state_key, lifecycle) in @hidden_states

  defp latest_state_from_values(values) do
    values
    |> Enum.max_by(&timestamp/1, fn -> nil end)
    |> case do
      nil -> nil
      %{state: state} -> state
      %{"state" => state} when is_atom(state) -> state
      _invalid -> nil
    end
  end

  defp timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp timestamp(%{"inserted_at" => %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp timestamp(_value), do: 0
end
