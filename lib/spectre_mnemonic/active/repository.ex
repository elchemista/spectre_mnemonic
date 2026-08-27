defmodule SpectreMnemonic.Active.Repository do
  @moduledoc false

  alias SpectreMnemonic.Active.ETS

  @doc false
  @spec lookup(atom(), term()) :: [term()]
  def lookup(table, id) do
    case ETS.lookup(table, id) do
      [{^id, value}] -> [value]
      [] -> []
    end
  end

  @doc false
  @spec indexed_ids(atom(), term()) :: [binary()]
  def indexed_ids(table, key) do
    table
    |> ETS.lookup(key)
    |> Enum.map(fn {_key, id} -> id end)
  end
end
