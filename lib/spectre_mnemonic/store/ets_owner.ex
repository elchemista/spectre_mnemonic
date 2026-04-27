defmodule SpectreMnemonic.Store.ETSOwner do
  @moduledoc """
  Owns the named ETS tables used by the live focus.

  Keeping a tiny owner process alive is the simplest way to keep named ETS
  tables available to the rest of the supervision tree.
  """

  use GenServer

  @tables [
    :mnemonic_signals,
    :mnemonic_streams,
    :mnemonic_moments,
    :mnemonic_status,
    :mnemonic_associations,
    :mnemonic_attention,
    :mnemonic_artifacts
  ]

  @doc "Starts the ETS owner process."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Returns true when a key exists in a named mnemonic ETS table."
  def member?(table, key) do
    :ets.member(table, key)
  rescue
    ArgumentError -> false
  end

  @impl true
  def init(state) do
    Enum.each(@tables, &create_table/1)
    {:ok, state}
  end

  defp create_table(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end
  end
end
