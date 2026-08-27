defmodule SpectreMnemonic.Engine.Config do
  @moduledoc """
  Normalized, Engine-owned runtime configuration.

  Applications normally provide keyword options to `SpectreMnemonic.Engine`
  instead of constructing this struct. Store, path, embedding, secret, and
  maximum-limit fields are fixed for the Engine lifetime and cannot be
  replaced by a single operation.
  """

  alias SpectreMnemonic.Embedding.Space
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Persistence.Store.File, as: FileStore

  @default_limits %{
    max_input_bytes: 4 * 1024 * 1024,
    max_metadata_bytes: 256 * 1024,
    max_metadata_depth: 16,
    max_chunks_per_intake: 256,
    max_extracted_nodes: 64,
    max_associations_per_intake: 1_024,
    max_vector_dimensions: 16_384,
    max_hot_bytes_per_scope: 64 * 1024 * 1024,
    max_hot_bytes_per_engine: 512 * 1024 * 1024,
    max_pinned_bytes: 128 * 1024 * 1024,
    max_candidates: 1_000,
    max_graph_nodes: 500,
    max_partition_queue: 128,
    max_store_queue: 256
  }

  @enforce_keys [
    :ref,
    :storage_id,
    :namespace,
    :internal_namespace,
    :data_root,
    :persistent_memory,
    :embedding_space,
    :limits,
    :projection_shards,
    :brute_force_threshold
  ]
  defstruct [
    :ref,
    :storage_id,
    :namespace,
    :internal_namespace,
    :data_root,
    :persistent_memory,
    :embedding,
    :embedding_space,
    :secret_crypto,
    :scheduler,
    :name,
    :legacy?,
    :projection_shards,
    :brute_force_threshold,
    limits: @default_limits
  ]

  @type t :: %__MODULE__{
          ref: Ref.t(),
          storage_id: binary(),
          namespace: binary(),
          internal_namespace: binary(),
          data_root: Path.t(),
          persistent_memory: keyword(),
          embedding: term(),
          embedding_space: Space.t(),
          secret_crypto: term(),
          scheduler: term(),
          name: GenServer.name() | nil,
          legacy?: boolean(),
          projection_shards: pos_integer(),
          brute_force_threshold: non_neg_integer(),
          limits: map()
        }

  @doc false
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, namespace} <- normalize_binary(Keyword.get(opts, :namespace), :namespace),
         {:ok, storage_id} <- storage_id(opts),
         {:ok, ref} <- engine_ref(opts, storage_id),
         :ok <- validate_name(Keyword.get(opts, :name)) do
      legacy? = Keyword.get(opts, :legacy?, false) == true
      data_root = data_root(opts, storage_id, legacy?)
      persistent_memory = persistent_memory(opts, data_root)

      embedding = Keyword.get(opts, :embedding)

      {:ok,
       %__MODULE__{
         ref: ref,
         storage_id: storage_id,
         namespace: namespace,
         internal_namespace: internal_namespace(namespace, storage_id, legacy?),
         data_root: data_root,
         persistent_memory: persistent_memory,
         embedding: embedding,
         embedding_space: Space.new(embedding),
         secret_crypto: Keyword.get(opts, :secret_crypto),
         scheduler: Keyword.get(opts, :scheduler, []),
         name: Keyword.get(opts, :name),
         legacy?: legacy?,
         projection_shards:
           positive_integer(Keyword.get(opts, :projection_shards), default_projection_shards()),
         brute_force_threshold:
           non_negative_integer(Keyword.get(opts, :brute_force_threshold), 250),
         limits: limits(Keyword.get(opts, :limits, []))
       }}
    end
  end

  def new(_opts), do: {:error, :invalid_engine_options}

  @doc false
  @spec default_engine_opts :: keyword() | nil
  def default_engine_opts do
    case Application.get_env(:spectre_mnemonic, :namespace) do
      namespace when is_binary(namespace) and namespace != "" ->
        [
          name: SpectreMnemonic.DefaultEngine,
          ref: Ref.new("default"),
          storage_id: namespace,
          namespace: namespace,
          data_root: Application.get_env(:spectre_mnemonic, :data_root, "mnemonic_data"),
          persistent_memory: Application.get_env(:spectre_mnemonic, :persistent_memory, []),
          embedding: Application.get_env(:spectre_mnemonic, :embedding, []),
          scheduler: Application.get_env(:spectre_mnemonic, :consolidation_scheduler, []),
          legacy?: true
        ]

      _missing ->
        nil
    end
  end

  @spec storage_id(keyword()) :: {:ok, binary()} | {:error, term()}
  defp storage_id(opts) do
    candidate = Keyword.get(opts, :storage_id) || ref_id(Keyword.get(opts, :ref)) || name_id(opts)
    normalize_binary(candidate, :storage_id)
  end

  @spec engine_ref(keyword(), binary()) :: {:ok, Ref.t()} | {:error, term()}
  defp engine_ref(opts, storage_id) do
    {:ok, Ref.new(Keyword.get(opts, :ref, storage_id))}
  rescue
    ArgumentError -> {:error, :invalid_engine_ref}
  end

  @spec ref_id(term()) :: binary() | nil
  defp ref_id(%Ref{id: id}), do: id
  defp ref_id(id) when is_binary(id), do: id
  defp ref_id(_ref), do: nil

  @spec name_id(keyword()) :: binary() | nil
  defp name_id(opts) do
    case Keyword.get(opts, :name) do
      name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
      _other -> nil
    end
  end

  @spec validate_name(term()) :: :ok | {:error, :invalid_engine_name}
  defp validate_name(nil), do: :ok
  defp validate_name(name) when is_atom(name) and not is_nil(name), do: :ok
  defp validate_name({:via, module, _term}) when is_atom(module), do: :ok
  defp validate_name(_name), do: {:error, :invalid_engine_name}

  @spec data_root(keyword(), binary(), boolean()) :: Path.t()
  defp data_root(opts, storage_id, legacy?) do
    base = Keyword.get(opts, :data_root, "mnemonic_data") |> Path.expand()

    if legacy? do
      base
    else
      Path.join(base, storage_key(storage_id))
    end
  end

  @spec storage_key(binary()) :: binary()
  defp storage_key(storage_id) do
    digest = :crypto.hash(:sha256, storage_id) |> Base.encode16(case: :lower)
    "engine-" <> binary_part(digest, 0, 24)
  end

  @spec internal_namespace(binary(), binary(), boolean()) :: binary()
  defp internal_namespace(namespace, _storage_id, true), do: namespace

  defp internal_namespace(namespace, storage_id, false) do
    digest = :crypto.hash(:sha256, storage_id) |> Base.encode16(case: :lower)
    namespace <> "~engine-" <> binary_part(digest, 0, 16)
  end

  @spec persistent_memory(keyword(), Path.t()) :: keyword()
  defp persistent_memory(opts, data_root) do
    configured =
      opts
      |> Keyword.get(
        :persistent_memory,
        Application.get_env(:spectre_mnemonic, :persistent_memory, [])
      )
      |> normalize_keyword()

    stores =
      Keyword.get(opts, :stores) ||
        Keyword.get(configured, :stores) ||
        [[id: :local_file, adapter: FileStore, role: :primary, opts: []]]

    stores = Enum.map(stores, &put_store_root(&1, data_root))
    configured |> Keyword.put(:stores, stores) |> Keyword.put_new(:failure_mode, :strict)
  end

  @spec put_store_root(keyword() | map(), Path.t()) :: keyword() | map()
  defp put_store_root(store, data_root) when is_list(store) do
    adapter = Keyword.get(store, :adapter)

    if adapter == FileStore do
      Keyword.update(store, :opts, [data_root: data_root], fn store_opts ->
        store_opts |> normalize_keyword() |> Keyword.put(:data_root, data_root)
      end)
    else
      store
    end
  end

  defp put_store_root(store, data_root) when is_map(store) do
    store |> Map.to_list() |> put_store_root(data_root)
  end

  @spec limits(term()) :: map()
  defp limits(configured) do
    configured =
      if is_map(configured), do: configured, else: Map.new(normalize_keyword(configured))

    Map.merge(@default_limits, configured, fn _key, default, value ->
      if is_integer(value) and value > 0, do: value, else: default
    end)
  end

  @spec default_projection_shards :: pos_integer()
  defp default_projection_shards, do: System.schedulers_online() |> min(8) |> max(1)

  @spec positive_integer(term(), pos_integer()) :: pos_integer()
  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  @spec non_negative_integer(term(), non_neg_integer()) :: non_neg_integer()
  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  @spec normalize_keyword(term()) :: keyword()
  defp normalize_keyword(value) when is_list(value),
    do: if(Keyword.keyword?(value), do: value, else: [])

  defp normalize_keyword(value) when is_map(value), do: Map.to_list(value)
  defp normalize_keyword(_value), do: []

  @spec normalize_binary(term(), atom()) :: {:ok, binary()} | {:error, term()}
  defp normalize_binary(value, field) when is_atom(value) and not is_nil(value),
    do: normalize_binary(Atom.to_string(value), field)

  defp normalize_binary(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {field, :required}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_binary(_value, field), do: {:error, {field, :required}}
end
