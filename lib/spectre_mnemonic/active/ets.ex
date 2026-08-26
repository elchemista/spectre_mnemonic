defmodule SpectreMnemonic.Active.ETS do
  @moduledoc false

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Context
  alias SpectreMnemonic.Engine.HotStore
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Engine.Runtime

  @context_key {__MODULE__, :tables}

  @doc false
  @spec with_engine(term(), (-> result)) :: result when result: term()
  def with_engine(reference, fun) when is_function(fun, 0) do
    case resolve_tables(reference) do
      {:ok, tables} ->
        previous = Process.put(@context_key, tables)

        try do
          fun.()
        after
          restore(previous)
        end

      {:error, _reason} ->
        fun.()
    end
  end

  @doc false
  @spec attach(term()) :: :ok | {:error, term()}
  def attach(reference) do
    case resolve_tables(reference) do
      {:ok, tables} ->
        Process.put(@context_key, tables)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec tables :: HotStore.tables()
  def tables do
    case Process.get(@context_key) do
      tables when is_map(tables) -> tables
      _missing -> current_tables!()
    end
  end

  @doc false
  @spec table(atom() | :ets.tid()) :: :ets.tid()
  def table(logical_name) when is_atom(logical_name) do
    case Map.fetch(tables(), logical_name) do
      {:ok, table} -> table
      :error -> raise ArgumentError, "unknown mnemonic ETS table #{inspect(logical_name)}"
    end
  end

  def table(table), do: table

  @doc false
  @spec table(term(), atom()) :: :ets.tid()
  def table(reference, logical_name) when is_atom(logical_name) do
    case resolve_tables(reference) do
      {:ok, tables} ->
        Map.fetch!(tables, logical_name)

      {:error, reason} ->
        raise ArgumentError, "mnemonic ETS table unavailable: #{inspect(reason)}"
    end
  end

  @spec lookup(atom() | :ets.tid(), term()) :: [term()]
  def lookup(table, key), do: :ets.lookup(table(table), key)

  @spec member(atom() | :ets.tid(), term()) :: boolean()
  def member(table, key), do: :ets.member(table(table), key)

  @spec insert(atom() | :ets.tid(), term()) :: true
  def insert(table, object), do: write(table, {:insert, object})

  @spec delete(atom() | :ets.tid(), term()) :: true
  def delete(table, key), do: write(table, {:delete, key})

  @spec delete_object(atom() | :ets.tid(), tuple()) :: true
  def delete_object(table, object), do: write(table, {:delete_object, object})

  @spec delete_all_objects(atom() | :ets.tid()) :: true
  def delete_all_objects(table), do: write(table, :delete_all_objects)

  @spec match_delete(atom() | :ets.tid(), tuple()) :: true
  def match_delete(table, pattern), do: write(table, {:match_delete, pattern})

  @spec match(atom() | :ets.tid(), tuple()) :: [term()]
  def match(table, pattern), do: :ets.match(table(table), pattern)

  @spec match_object(atom() | :ets.tid(), tuple()) :: [term()]
  def match_object(table, pattern), do: :ets.match_object(table(table), pattern)

  @spec tab2list(atom() | :ets.tid()) :: [term()]
  def tab2list(table), do: :ets.tab2list(table(table))

  @spec foldl((term(), term() -> term()), term(), atom() | :ets.tid()) :: term()
  def foldl(fun, acc, table), do: :ets.foldl(fun, acc, table(table))

  @spec next(atom() | :ets.tid(), term()) :: term()
  def next(table, key), do: :ets.next(table(table), key)

  @spec update_counter(atom() | :ets.tid(), term(), term()) :: integer() | [integer()]
  def update_counter(table, key, update), do: write(table, {:update_counter, key, update})

  @spec update_counter(atom() | :ets.tid(), term(), term(), tuple()) :: integer() | [integer()]
  def update_counter(table, key, update, default),
    do: write(table, {:update_counter, key, update, default})

  @spec select(atom() | :ets.tid(), list()) :: [term()]
  def select(table, match_spec), do: :ets.select(table(table), match_spec)

  @spec info(atom() | :ets.tid(), atom()) :: term()
  def info(table, item), do: :ets.info(table(table), item)

  @spec whereis(atom()) :: :ets.tid() | :undefined
  def whereis(logical_name) when is_atom(logical_name) do
    table(logical_name)
  rescue
    ArgumentError -> :undefined
  end

  @spec current_tables! :: HotStore.tables()
  defp current_tables! do
    with nil <- Context.current(),
         {:ok, runtime} <- Engine.resolve(SpectreMnemonic.DefaultEngine),
         {:ok, tables} <- HotStore.tables(runtime.config.ref) do
      tables
    else
      %Runtime{config: %{ref: ref}} ->
        case HotStore.tables(ref) do
          {:ok, tables} ->
            tables

          {:error, reason} ->
            raise ArgumentError, "mnemonic hot store unavailable: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise ArgumentError, "mnemonic hot store unavailable: #{inspect(reason)}"
    end
  end

  @spec resolve_tables(term()) :: {:ok, HotStore.tables()} | {:error, term()}
  defp resolve_tables(%Ref{} = ref), do: HotStore.tables(ref)
  defp resolve_tables(%Runtime{config: %{ref: ref}}), do: HotStore.tables(ref)

  defp resolve_tables(reference) do
    with {:ok, runtime} <- Engine.resolve(reference) do
      HotStore.tables(runtime.config.ref)
    end
  end

  @spec write(atom() | :ets.tid(), tuple() | atom()) :: term()
  defp write(table_or_name, operation) do
    table = table(table_or_name)

    case :ets.info(table, :owner) do
      owner when owner == self() ->
        apply_local_write(table, operation)

      owner when is_pid(owner) ->
        case GenServer.call(owner, {:ets_write, table, operation}, :infinity) do
          {:error, reason} ->
            raise ArgumentError, "mnemonic hot-store write rejected: #{inspect(reason)}"

          result ->
            result
        end

      :undefined ->
        raise ArgumentError, "mnemonic ETS table is no longer available"
    end
  end

  @spec apply_local_write(:ets.tid(), tuple() | atom()) :: term()
  defp apply_local_write(table, {:insert, object}), do: :ets.insert(table, object)
  defp apply_local_write(table, {:delete, key}), do: :ets.delete(table, key)
  defp apply_local_write(table, {:delete_object, object}), do: :ets.delete_object(table, object)
  defp apply_local_write(table, :delete_all_objects), do: :ets.delete_all_objects(table)
  defp apply_local_write(table, {:match_delete, pattern}), do: :ets.match_delete(table, pattern)

  defp apply_local_write(table, {:update_counter, key, update}),
    do: :ets.update_counter(table, key, update)

  defp apply_local_write(table, {:update_counter, key, update, default}),
    do: :ets.update_counter(table, key, update, default)

  @spec restore(term()) :: term()
  defp restore(nil), do: Process.delete(@context_key)
  defp restore(previous), do: Process.put(@context_key, previous)
end
