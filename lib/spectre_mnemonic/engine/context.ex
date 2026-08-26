defmodule SpectreMnemonic.Engine.Context do
  @moduledoc false

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Runtime

  @context_key {__MODULE__, :runtime}
  @locked_call_keys [
    :namespace,
    :data_root,
    :persistent_memory,
    :stores,
    :embedding_config,
    :embedding_space,
    :embedding_adapter,
    :secret_key,
    :secret_key_fun,
    :secret_crypto_adapter,
    :crypto_adapter,
    :key_id,
    :key_version,
    :crypto_version,
    :aad_version,
    :scheduler
  ]

  @doc false
  @spec current :: Runtime.t() | nil
  def current, do: Process.get(@context_key)

  @doc false
  @spec with(keyword(), (keyword() -> result)) :: result | {:error, term()} when result: term()
  def with(opts, fun) when is_list(opts) and is_function(fun, 1) do
    if Keyword.keyword?(opts) do
      case current() do
        %Runtime{} = runtime -> fun.(operation_opts(runtime, opts))
        nil -> resolve_and_run(opts, fun)
      end
    else
      fun.(opts)
    end
  end

  def with(opts, fun) when is_function(fun, 1), do: fun.(opts)

  @spec resolve_and_run(keyword(), (keyword() -> result)) :: result | {:error, term()}
        when result: term()
  defp resolve_and_run(opts, fun) do
    with {:ok, runtime} <- resolve_runtime(opts) do
      previous = Process.put(@context_key, runtime)
      internal_call? = internal_call?(opts)

      try do
        result = runtime |> operation_opts(opts) |> fun.()
        if internal_call?, do: result, else: externalize(result, runtime)
      after
        restore(previous)
      end
    end
  end

  @spec internal_call?(keyword()) :: boolean()
  defp internal_call?(opts) do
    Keyword.get(opts, :engine_internal?, false) == true or
      Keyword.has_key?(opts, :engine_ref) or
      (not Keyword.has_key?(opts, :engine) and
         Engine.internal_namespace?(Keyword.get(opts, :namespace)))
  end

  @spec resolve_runtime(keyword()) :: {:ok, Runtime.t()} | {:error, term()}
  defp resolve_runtime(opts) do
    case Keyword.get(opts, :engine) || Keyword.get(opts, :engine_ref) do
      nil -> resolve_runtime_from_namespace(opts)
      reference -> Engine.resolve(reference)
    end
  end

  @spec resolve_runtime_from_namespace(keyword()) :: {:ok, Runtime.t()} | {:error, term()}
  defp resolve_runtime_from_namespace(opts) do
    case Keyword.get(opts, :namespace) do
      namespace when is_binary(namespace) ->
        case Engine.resolve_internal_namespace(namespace) do
          {:ok, _runtime} = found -> found
          {:error, _reason} -> Engine.resolve(SpectreMnemonic.DefaultEngine)
        end

      _missing ->
        Engine.resolve(SpectreMnemonic.DefaultEngine)
    end
  end

  @doc false
  @spec operation_opts(Runtime.t(), keyword()) :: keyword()
  def operation_opts(%Runtime{config: %{legacy?: true} = config}, opts) do
    opts
    |> Keyword.delete(:engine)
    |> Keyword.put(:engine_ref, config.ref)
    |> Keyword.put(:engine_internal?, true)
    |> Keyword.put(:storage_id, config.storage_id)
    |> Keyword.put(:engine_namespace, config.internal_namespace)
    |> Keyword.put_new(:namespace, config.internal_namespace)
    |> Keyword.put_new(:data_root, config.data_root)
    |> Keyword.put(:engine_limits, config.limits)
    |> put_limit_options(config.limits)
  end

  def operation_opts(%Runtime{config: config}, opts) do
    opts
    |> Keyword.drop(@locked_call_keys)
    |> Keyword.delete(:engine)
    |> Keyword.put(:engine_ref, config.ref)
    |> Keyword.put(:engine_internal?, true)
    |> Keyword.put(:storage_id, config.storage_id)
    |> Keyword.put(:engine_namespace, config.internal_namespace)
    |> Keyword.put(:namespace, config.internal_namespace)
    |> Keyword.put(:data_root, config.data_root)
    |> Keyword.put(:persistent_memory, config.persistent_memory)
    |> Keyword.put(:engine_limits, config.limits)
    |> put_if_present(:embedding_config, config.embedding)
    |> Keyword.put(:embedding_space, config.embedding_space)
    |> put_secret_crypto(config.secret_crypto)
    |> put_limit_options(config.limits)
  end

  @spec put_limit_options(keyword(), map()) :: keyword()
  defp put_limit_options(opts, limits) do
    Enum.reduce(limits, opts, fn {key, maximum}, acc ->
      put_limit_option(acc, key, maximum)
    end)
  end

  @spec put_limit_option(keyword(), atom(), pos_integer()) :: keyword()
  defp put_limit_option(opts, key, maximum) do
    case Keyword.fetch(opts, key) do
      {:ok, requested} when is_integer(requested) and requested > 0 ->
        Keyword.put(opts, key, min(requested, maximum))

      {:ok, _invalid} ->
        opts

      :error ->
        Keyword.put(opts, key, maximum)
    end
  end

  @spec put_if_present(keyword(), atom(), term()) :: keyword()
  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  @spec put_secret_crypto(keyword(), term()) :: keyword()
  defp put_secret_crypto(opts, nil), do: opts

  defp put_secret_crypto(opts, adapter) when is_atom(adapter) and not is_nil(adapter),
    do: Keyword.put(opts, :crypto_adapter, adapter)

  defp put_secret_crypto(opts, config) when is_map(config),
    do: put_secret_crypto(opts, Map.to_list(config))

  defp put_secret_crypto(opts, config) when is_list(config) do
    if Keyword.keyword?(config) do
      aliases = %{
        adapter: :crypto_adapter,
        key: :secret_key,
        key_fun: :secret_key_fun
      }

      Enum.reduce(config, opts, fn {key, value}, current ->
        Keyword.put(current, Map.get(aliases, key, key), value)
      end)
    else
      opts
    end
  end

  defp put_secret_crypto(opts, _invalid), do: opts

  @spec externalize(term(), Runtime.t()) :: term()
  defp externalize({tag, value}, runtime) when tag in [:ok, :error],
    do: {tag, externalize(value, runtime)}

  defp externalize(value, %Runtime{config: config})
       when value == config.internal_namespace,
       do: config.namespace

  defp externalize(%DateTime{} = value, _runtime), do: value
  defp externalize(%Date{} = value, _runtime), do: value
  defp externalize(%Time{} = value, _runtime), do: value
  defp externalize(%NaiveDateTime{} = value, _runtime), do: value

  defp externalize(%module{} = value, runtime) do
    fields =
      value
      |> Map.from_struct()
      |> Map.new(fn {key, item} -> {key, externalize(item, runtime)} end)

    struct(module, fields)
  rescue
    _exception -> value
  end

  defp externalize(value, runtime) when is_map(value),
    do:
      Map.new(value, fn {key, item} -> {externalize(key, runtime), externalize(item, runtime)} end)

  defp externalize(value, runtime) when is_list(value),
    do: Enum.map(value, &externalize(&1, runtime))

  defp externalize(value, runtime) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&externalize(&1, runtime)) |> List.to_tuple()

  defp externalize(value, _runtime), do: value

  @spec restore(term()) :: term()
  defp restore(nil), do: Process.delete(@context_key)
  defp restore(previous), do: Process.put(@context_key, previous)
end
