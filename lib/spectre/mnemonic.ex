defmodule Spectre.Mnemonic do
  @moduledoc """
  Stack-installable definition for Spectre Mnemonic.

  The installation compiles memory-store and isolation declarations into
  immutable data. It does not claim ownership of the legacy Mnemonic
  application, named processes, or ETS tables.
  """

  alias Spectre.Stack.DSL

  @isolation_dimensions [:agent, :subject, :conversation, :flow, :task]

  use Spectre.Stack.Installable,
    id: :mnemonic,
    version: "0.1.2",
    contract: 1,
    spectre: "~> 0.1.2",
    provides: [{:service, :memory}],
    requires: [],
    conflicts: [],
    operations: [],
    actions: [],
    resources: [],
    dsl: __MODULE__,
    metadata: %{application: :spectre_mnemonic, role: :memory}

  @impl Spectre.Stack.Installable
  def compile(opts, block, caller) do
    declarations =
      DSL.compile!(block, caller,
        store: 1,
        isolate_by: 1
      )

    compile_declarations(declarations, default_config(opts))
  end

  @spec compile_declarations([{atom(), [term()]}], map()) :: {:ok, map()} | {:error, term()}
  defp compile_declarations(declarations, config) do
    Enum.reduce_while(declarations, {:ok, config}, fn declaration, {:ok, current} ->
      case compile_declaration(declaration, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec compile_declaration({atom(), [term()]}, map()) :: {:ok, map()} | {:error, term()}
  defp compile_declaration({:store, [store]}, %{store: nil} = config) do
    if valid_module?(store),
      do: {:ok, %{config | store: store}},
      else: {:error, {:invalid_store, store}}
  end

  defp compile_declaration({:store, [_store]}, _config),
    do: {:error, {:duplicate_declaration, :store}}

  defp compile_declaration({:isolate_by, [dimensions]}, %{isolate_by: []} = config) do
    with :ok <- validate_isolation_dimensions(dimensions) do
      {:ok, %{config | isolate_by: dimensions}}
    end
  end

  defp compile_declaration({:isolate_by, [_dimensions]}, _config),
    do: {:error, {:duplicate_declaration, :isolate_by}}

  @spec default_config(keyword()) :: map()
  defp default_config(opts) do
    %{
      options: opts,
      store: nil,
      isolate_by: []
    }
  end

  @spec validate_isolation_dimensions(term()) :: :ok | {:error, term()}
  defp validate_isolation_dimensions(dimensions) when is_list(dimensions) do
    cond do
      dimensions == [] ->
        {:error, {:invalid_isolate_by, :empty}}

      Enum.any?(dimensions, &(&1 not in @isolation_dimensions)) ->
        {:error, {:invalid_isolate_by, dimensions}}

      length(Enum.uniq(dimensions)) != length(dimensions) ->
        {:error, {:duplicate_isolation_dimension, dimensions}}

      true ->
        :ok
    end
  end

  defp validate_isolation_dimensions(dimensions),
    do: {:error, {:invalid_isolate_by, dimensions}}

  @spec valid_module?(term()) :: boolean()
  defp valid_module?(module), do: is_atom(module) and not is_nil(module)
end
