defmodule SpectreMnemonic.Active.Command do
  @moduledoc false

  alias SpectreMnemonic.Engine.PartitionExecutor

  @doc false
  @spec run(keyword(), (-> result)) :: result | {:error, term()} when result: term()
  def run(opts, fun) when is_list(opts) and is_function(fun, 0) do
    PartitionExecutor.trans(PartitionExecutor.key(opts), fn -> safely(fun) end, opts)
  end

  @doc false
  @spec run_for_record(map(), (-> result)) :: result | {:error, term()} when result: term()
  def run_for_record(record, fun) when is_map(record) and is_function(fun, 0) do
    PartitionExecutor.trans(PartitionExecutor.key(record), fn -> safely(fun) end)
  end

  @spec safely((-> result)) :: result | {:error, term()} when result: term()
  defp safely(fun) do
    fun.()
  rescue
    exception ->
      {:error, {:active_focus_failed, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:active_focus_failed, kind, reason}}
  end
end
