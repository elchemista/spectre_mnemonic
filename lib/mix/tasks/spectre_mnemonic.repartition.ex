defmodule Mix.Tasks.SpectreMnemonic.Repartition do
  @moduledoc """
  Copies legacy durable memory through a host-owned assignment module.

      mix spectre_mnemonic.repartition MyApp.MemoryRepartition

  The module implements `SpectreMnemonic.Migration.Assigner`. The task never
  erases the source partition automatically.
  """

  use Mix.Task

  @shortdoc "Idempotently repartitions durable Mnemonic records"

  @impl Mix.Task
  def run([module_name]) do
    Mix.Task.run("app.start")

    with {:ok, module} <- existing_module(module_name),
         :ok <- validate_module(module),
         {:ok, report} <-
           SpectreMnemonic.Migration.repartition(
             module.source_options(),
             module.destination_options(),
             module
           ) do
      Mix.shell().info(
        "repartition complete: scanned=#{report.scanned} migrated=#{report.migrated} " <>
          "idempotent=#{report.idempotent} skipped=#{report.skipped} source_erased=false"
      )
    else
      {:error, reason} -> Mix.raise("repartition failed: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("usage: mix spectre_mnemonic.repartition MyApp.MemoryRepartition")
  end

  @spec existing_module(binary()) :: {:ok, module()} | {:error, term()}
  defp existing_module(module_name) do
    {:ok, Module.safe_concat(String.split(module_name, "."))}
  rescue
    ArgumentError -> {:error, {:repartition_module_not_loaded, module_name}}
  end

  @spec validate_module(module()) :: :ok | {:error, term()}
  defp validate_module(module) do
    required = [source_options: 0, destination_options: 0, assign: 1]

    if Code.ensure_loaded?(module) and
         Enum.all?(required, fn {function, arity} ->
           function_exported?(module, function, arity)
         end) do
      :ok
    else
      {:error, {:invalid_repartition_module, module}}
    end
  end
end
