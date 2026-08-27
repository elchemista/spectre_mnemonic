defmodule SpectreMnemonic.Embedding.ModelCache do
  @moduledoc false

  use GenServer

  @table_key {__MODULE__, :table}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  @spec get(term()) :: term() | nil
  def get(key) do
    case table() do
      nil ->
        nil

      table ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> value
          [] -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec reset :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(:ok) do
    table =
      :ets.new(:model_cache, [
        :set,
        :protected,
        :compressed,
        read_concurrency: true
      ])

    :persistent_term.put(@table_key, table)
    {:ok, table}
  end

  @impl GenServer
  def handle_call({:put, key, value}, _from, table) do
    :ets.insert(table, {key, value})
    {:reply, :ok, table}
  end

  def handle_call(:reset, _from, table) do
    :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end

  @impl GenServer
  def terminate(_reason, _table) do
    :persistent_term.erase(@table_key)
    :ok
  end

  @spec table :: :ets.tid() | nil
  defp table, do: :persistent_term.get(@table_key, nil)
end
