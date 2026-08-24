defmodule Spectre.Mnemonic do
  @moduledoc """
  Stack-installable definition for Spectre Mnemonic.

  The installation compiles memory-store and isolation declarations into
  immutable data. Selecting it activates the Spectre memory adapter while
  leaving ownership of the Mnemonic application, named processes, and ETS
  tables with the host.
  """

  alias Spectre.Stack.DSL

  @isolation_dimensions [:agent, :subject, :conversation, :flow, :task]

  use Spectre.Stack.Installable,
    id: :mnemonic,
    version: "0.4.0",
    contract: 1,
    spectre: "~> 0.3.3",
    provides: [{:service, :memory}],
    requires: [],
    conflicts: [],
    operations: [],
    actions: [],
    resources: [],
    agent_extensions: [Spectre.Mnemonic.Extension],
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

  defmacro __using__(opts) do
    quote do
      Spectre.Extension.register!(
        __MODULE__,
        Spectre.Mnemonic.Extension,
        unquote(opts)
      )
    end
  end

  @doc """
  Returns the immutable Mnemonic installation bound to an Agent.
  """
  @spec config(module()) :: {:ok, map()} | {:error, term()}
  def config(agent) when is_atom(agent) do
    with {:ok, mount} <- Spectre.Extension.fetch(agent, :mnemonic),
         config when is_map(config) <- mount.compiled do
      {:ok, config}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_mnemonic_configuration}
    end
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
