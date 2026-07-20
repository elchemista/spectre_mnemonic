defmodule SpectreMnemonic.Memory.Scope do
  @moduledoc false

  alias SpectreMnemonic.Identity

  @doc "Returns the scope option as-is so tuples, atoms, and binaries remain caller-owned."
  @spec from_opts(keyword()) :: term()
  def from_opts(opts), do: Keyword.get(opts, :scope)

  @doc "Extracts scope from a memory-like map."
  @spec scope(term()) :: term()
  def scope(memory) when is_map(memory) do
    case declared_value(memory, :scope) do
      {:ok, scope} -> scope
      :error -> metadata_value(memory, :scope)
    end
  end

  def scope(_memory), do: nil

  @doc "Extracts the mandatory namespace from a memory-like map."
  @spec namespace(term()) :: binary() | nil
  def namespace(memory), do: Identity.namespace(memory)

  @doc "Returns the namespace/scope partition key for a memory-like map."
  @spec partition(term()) :: {binary() | nil, term()}
  def partition(memory), do: {namespace(memory), scope(memory)}

  @doc "Returns true when memory belongs to the one requested namespace/scope partition."
  @spec match?(term(), keyword()) :: boolean()
  def match?(memory, opts) do
    case Identity.fetch_namespace(opts) do
      {:ok, namespace} ->
        requested_scope = from_opts(opts)

        validate_context(memory, namespace, requested_scope) == :ok and
          namespace(memory) == namespace and scope(memory) == requested_scope

      {:error, _reason} ->
        false
    end
  end

  @doc false
  @spec match_namespace?(term(), keyword()) :: boolean()
  def match_namespace?(memory, opts) do
    case Identity.fetch_namespace(opts) do
      {:ok, namespace} ->
        validate_context(memory, namespace, scope(memory)) == :ok and
          namespace(memory) == namespace

      {:error, _reason} ->
        false
    end
  end

  @doc false
  @spec scopes(keyword()) :: [term()]
  def scopes(opts), do: [from_opts(opts)]

  @doc false
  @spec consistent?(term()) :: boolean()
  def consistent?(memory) when is_map(memory) do
    consistent_values?(declared_values(memory, :namespace)) and
      consistent_values?(declared_values(memory, :scope))
  end

  def consistent?(_memory), do: false

  @doc false
  @spec validate_context(term(), binary(), term()) :: :ok | {:error, term()}
  def validate_context(memory, namespace, scope) when is_map(memory) do
    cond do
      not consistent?(memory) ->
        {:error, :inconsistent_memory_context}

      declared_mismatch?(memory, :namespace, namespace) ->
        {:error, {:namespace_mismatch, namespace, namespace(memory)}}

      declared_mismatch?(memory, :scope, scope) ->
        {:error, {:scope_mismatch, scope, scope(memory)}}

      true ->
        validate_nested_context(memory, namespace, scope)
    end
  end

  def validate_context(_memory, _namespace, _scope), do: :ok

  @doc false
  @spec validate_assignable_context(term(), binary(), term()) :: :ok | {:error, term()}
  def validate_assignable_context(memory, namespace, scope) when is_map(memory) do
    cond do
      not assignable_consistent?(memory, :namespace) or not assignable_consistent?(memory, :scope) ->
        {:error, :inconsistent_memory_context}

      assignable_mismatch?(memory, :namespace, namespace) ->
        {:error, {:namespace_mismatch, namespace, namespace(memory)}}

      assignable_mismatch?(memory, :scope, scope) ->
        {:error, {:scope_mismatch, scope, scope(memory)}}

      true ->
        validate_nested_assignment(memory, namespace, scope)
    end
  end

  def validate_assignable_context(_memory, _namespace, _scope), do: :ok

  @spec validate_nested_context(map(), binary(), term()) :: :ok | {:error, term()}
  defp validate_nested_context(memory, namespace, scope) do
    validate_nested(memory, &validate_context(&1, namespace, scope))
  end

  @spec validate_nested_assignment(map(), binary(), term()) :: :ok | {:error, term()}
  defp validate_nested_assignment(memory, namespace, scope) do
    validate_nested(memory, &validate_assignable_context(&1, namespace, scope))
  end

  @spec validate_nested(map(), (map() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  defp validate_nested(memory, validator) do
    Enum.reduce_while([:payload, :record], :ok, fn key, :ok ->
      memory
      |> direct_values(key)
      |> Enum.reduce_while(:ok, fn nested, :ok ->
        validate_nested_value({:ok, nested}, validator)
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_nested_value({:ok, term()} | :error, (map() -> :ok | {:error, term()})) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp validate_nested_value({:ok, nested}, validator) when is_map(nested),
    do: nested |> validator.() |> nested_validation_step()

  defp validate_nested_value(_missing_or_non_map, _validator), do: {:cont, :ok}

  @spec nested_validation_step(:ok | {:error, term()}) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp nested_validation_step(:ok), do: {:cont, :ok}
  defp nested_validation_step({:error, _reason} = error), do: {:halt, error}

  @spec assignable_consistent?(map(), atom()) :: boolean()
  defp assignable_consistent?(memory, key) do
    memory
    |> declared_values(key)
    |> Enum.reject(&is_nil/1)
    |> consistent_values?()
  end

  @spec assignable_mismatch?(map(), atom(), term()) :: boolean()
  defp assignable_mismatch?(memory, key, expected) do
    memory
    |> declared_values(key)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&(&1 != expected))
  end

  @spec declared_mismatch?(map(), atom(), term()) :: boolean()
  defp declared_mismatch?(memory, key, expected) do
    case declared_values(memory, key) do
      [] -> false
      values -> Enum.any?(values, &(&1 != expected))
    end
  end

  @spec consistent_values?([term()]) :: boolean()
  defp consistent_values?(values), do: values |> Enum.uniq() |> length() <= 1

  @spec declared_values(map(), atom()) :: [term()]
  defp declared_values(memory, key) do
    nested =
      memory
      |> direct_values(:metadata)
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&direct_values(&1, key))

    direct_values(memory, key) ++ nested
  end

  @spec direct_values(map(), atom()) :: [term()]
  defp direct_values(map, key) do
    string_key = Atom.to_string(key)

    []
    |> maybe_prepend(Map.has_key?(map, string_key), Map.get(map, string_key))
    |> maybe_prepend(Map.has_key?(map, key), Map.get(map, key))
  end

  @spec metadata_value(map(), atom()) :: term()
  defp metadata_value(memory, key) do
    memory
    |> direct_values(:metadata)
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&direct_values(&1, key))
    |> List.first()
  end

  @spec maybe_prepend([term()], boolean(), term()) :: [term()]
  defp maybe_prepend(values, true, value), do: [value | values]
  defp maybe_prepend(values, false, _value), do: values

  @spec declared_value(map(), atom()) :: {:ok, term()} | :error
  defp declared_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end
end
