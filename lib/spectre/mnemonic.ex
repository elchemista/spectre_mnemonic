if Code.ensure_loaded?(Spectre.Stack.Installable) do
  defmodule Spectre.Mnemonic do
    @moduledoc """
    Stack-installable definition for Spectre Mnemonic.

    The installation compiles memory-store and isolation declarations into
    immutable data. Selecting it activates the Spectre memory adapter while
    leaving ownership of the Mnemonic application, named processes, and ETS
    tables with the host.
    """

    alias Spectre.Instance.Ref, as: InstanceRef
    alias Spectre.Mnemonic.Memory, as: MnemonicMemory
    alias Spectre.Stack.DSL
    alias SpectreMnemonic.Engine.Context, as: EngineContext
    alias SpectreMnemonic.Erasure.Report, as: ErasureReport
    alias SpectreMnemonic.Persistence.Manager

    @isolation_dimensions [:agent, :subject, :conversation, :flow, :task, :instance]

    use Spectre.Stack.Installable,
      id: :mnemonic,
      version: "0.2.0",
      contract: 1,
      spectre: "~> 0.3.3",
      provides: [{:service, :memory}],
      requires: [],
      conflicts: [],
      operations: [],
      actions: [],
      resources: [:engine],
      agent_extensions: [Spectre.Mnemonic.Extension],
      dsl: __MODULE__,
      metadata: %{application: :spectre_mnemonic, role: :memory}

    @package_data_available Code.ensure_loaded?(Spectre.Stack.PackageData)

    if @package_data_available do
      @behaviour Spectre.Stack.PackageData
    end

    @impl Spectre.Stack.Installable
    def compile(opts, block, caller) do
      declarations =
        DSL.compile!(block, caller,
          store: 1,
          isolate_by: 1
        )

      case compile_declarations(declarations, default_config(opts, caller)) do
        {:ok, config} ->
          warn_shared_scope(config, caller)
          {:ok, config}

        {:error, _reason} = error ->
          error
      end
    end

    @impl Spectre.Stack.Installable
    def child_specs(installation, runtime_opts) when is_list(runtime_opts) do
      config = Map.new(installation.config)
      compiled_opts = config |> Map.get(:options, []) |> normalize_keyword()
      owner = Map.get(config, :stack_owner)

      storage_id =
        Keyword.get(runtime_opts, :storage_id) || stack_storage_id(owner, installation.id)

      namespace =
        runtime_opts
        |> Keyword.get(:namespace, Keyword.get(compiled_opts, :namespace, storage_id))
        |> normalize_namespace(storage_id)

      engine_opts =
        runtime_opts
        |> Keyword.take([
          :data_root,
          :persistent_memory,
          :stores,
          :embedding,
          :limits,
          :secret_crypto,
          :scheduler,
          :projection_shards,
          :brute_force_threshold
        ])
        |> Keyword.put(:ref, storage_id)
        |> Keyword.put(:storage_id, storage_id)
        |> Keyword.put(:namespace, namespace)
        |> configure_engine_store(Map.get(config, :store), runtime_opts)

      [{:engine, Supervisor.child_spec({SpectreMnemonic.Engine, engine_opts}, [])}]
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

    @doc "Builds a content-free erasure plan for one Spectre Instance partition."
    @spec erasure_plan(InstanceRef.t(), keyword()) ::
            {:ok, map()} | {:error, term()}
    if @package_data_available, do: @impl(Spectre.Stack.PackageData)
    def erasure_plan(instance_ref, opts \\ [])

    def erasure_plan(%InstanceRef{} = instance_ref, opts) do
      with {:ok, memory_opts} <- erasure_options(instance_ref, opts),
           :ok <-
             EngineContext.with(
               memory_opts,
               &Manager.ensure_erasure_supported/1
             ),
           {:ok, runtime} <- resolve_erasure_engine(memory_opts) do
        {:ok,
         %{
           engine: runtime.config.ref,
           storage_id: runtime.config.storage_id,
           scope: Keyword.fetch!(memory_opts, :scope),
           supported?: true,
           sealed?: true
         }}
      end
    end

    def erasure_plan(instance_ref, _opts),
      do: {:error, {:invalid_mnemonic_instance_ref, instance_ref}}

    @doc "Physically erases and seals one Spectre Instance memory partition."
    @spec erase_instance(InstanceRef.t(), keyword()) ::
            {:ok, ErasureReport.t()} | {:error, term()}
    if @package_data_available, do: @impl(Spectre.Stack.PackageData)
    def erase_instance(instance_ref, opts \\ [])

    def erase_instance(%InstanceRef{} = instance_ref, opts) do
      with {:ok, memory_opts} <- erasure_options(instance_ref, opts) do
        memory_opts
        |> Keyword.put(:sealed, true)
        |> SpectreMnemonic.erase_partition()
      end
    end

    def erase_instance(instance_ref, _opts),
      do: {:error, {:invalid_mnemonic_instance_ref, instance_ref}}

    @spec compile_declarations([{atom(), [term()]}], map()) :: {:ok, map()} | {:error, term()}
    defp compile_declarations(declarations, config) do
      Enum.reduce_while(declarations, {:ok, config}, fn declaration, {:ok, current} ->
        case compile_declaration(declaration, current) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    @spec erasure_options(InstanceRef.t(), keyword()) ::
            {:ok, keyword()} | {:error, term()}
    defp erasure_options(instance_ref, opts) when is_list(opts) do
      if Keyword.keyword?(opts) do
        agent = instance_ref.agent_ref.definition

        metadata =
          opts
          |> Keyword.get(:run_metadata, %{})
          |> normalize_map()
          |> Map.put(:instance_ref, instance_ref)

        runtime_opts =
          opts
          |> Keyword.put(:agent, agent)
          |> Keyword.put(:agent_ref, instance_ref.agent_ref)
          |> Keyword.put(:subject, instance_ref.subject)
          |> Keyword.put(:run_metadata, metadata)
          |> Keyword.put(:mnemonic_operation_kind, :erasure)

        MnemonicMemory.options(agent, runtime_opts)
      else
        {:error, :invalid_mnemonic_erasure_options}
      end
    end

    defp erasure_options(_instance_ref, _opts),
      do: {:error, :invalid_mnemonic_erasure_options}

    @spec resolve_erasure_engine(keyword()) ::
            {:ok, SpectreMnemonic.Engine.Runtime.t()} | {:error, term()}
    defp resolve_erasure_engine(opts) do
      SpectreMnemonic.Engine.resolve(Keyword.get(opts, :engine, SpectreMnemonic.DefaultEngine))
    end

    @spec normalize_map(term()) :: map()
    defp normalize_map(value) when is_map(value), do: value
    defp normalize_map(_value), do: %{}

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

    @spec default_config(keyword(), Macro.Env.t()) :: map()
    defp default_config(opts, caller) do
      %{
        options: opts,
        store: nil,
        isolate_by: [],
        stack_owner: caller.module
      }
    end

    @spec configure_engine_store(keyword(), module() | nil, keyword()) :: keyword()
    defp configure_engine_store(opts, nil, _runtime_opts), do: opts

    defp configure_engine_store(opts, store, runtime_opts) do
      store_opts = runtime_opts |> Keyword.get(:store_opts, []) |> normalize_keyword()
      configured = Keyword.get(opts, :persistent_memory, []) |> normalize_keyword()

      persistent =
        Keyword.put(configured, :stores, [
          [id: :spectre_stack, adapter: store, role: :primary, opts: store_opts]
        ])

      Keyword.put(opts, :persistent_memory, persistent)
    end

    @spec stack_storage_id(module() | nil, term()) :: binary()
    defp stack_storage_id(owner, installation_id) do
      digest =
        {owner, installation_id}
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      "spectre-" <> binary_part(digest, 0, 32)
    end

    @spec normalize_namespace(term(), binary()) :: binary()
    defp normalize_namespace(namespace, _fallback) when is_binary(namespace) and namespace != "",
      do: namespace

    defp normalize_namespace(namespace, _fallback)
         when is_atom(namespace) and not is_nil(namespace),
         do: Atom.to_string(namespace)

    defp normalize_namespace(_namespace, fallback), do: fallback

    @spec normalize_keyword(term()) :: keyword()
    defp normalize_keyword(value) when is_list(value) do
      if Keyword.keyword?(value), do: value, else: []
    end

    defp normalize_keyword(value) when is_map(value), do: Map.to_list(value)
    defp normalize_keyword(_value), do: []

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

    @spec warn_shared_scope(map(), Macro.Env.t()) :: :ok
    defp warn_shared_scope(%{isolate_by: []}, caller) do
      IO.warn(
        "Spectre.Mnemonic isolate_by: [] keeps the historical shared memory scope; " <>
          "use isolate_by: [:instance] for new isolated installations",
        Macro.Env.stacktrace(caller)
      )

      :ok
    end

    defp warn_shared_scope(_config, _caller), do: :ok
  end
end
