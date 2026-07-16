defmodule SpectreMnemonic.Memory.Scope do
  @moduledoc false

  alias SpectreMnemonic.Identity

  @doc "Returns the scope option as-is so tuples, atoms, and binaries remain caller-owned."
  @spec from_opts(keyword()) :: term()
  def from_opts(opts), do: Keyword.get(opts, :scope)

  @doc "Extracts scope from a memory-like map."
  @spec scope(term()) :: term()
  def scope(%{scope: scope}), do: scope

  def scope(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :scope) || Map.get(metadata, "scope")
  end

  def scope(_memory), do: nil

  @doc "Extracts the mandatory namespace from a memory-like map."
  @spec namespace(term()) :: binary() | nil
  def namespace(memory), do: Identity.namespace(memory)

  @doc "Returns the namespace/scope partition key for a memory-like map."
  @spec partition(term()) :: {binary() | nil, term()}
  def partition(memory), do: {namespace(memory), scope(memory)}

  @doc "Returns true when memory matches the requested scope filters."
  @spec match?(term(), keyword()) :: boolean()
  def match?(memory, opts) do
    with {:ok, namespace} <- Identity.fetch_namespace(opts) do
      namespace_match?(memory, namespace, opts) and scope_match?(memory, opts)
    else
      {:error, _reason} -> false
    end
  end

  @spec scopes(keyword()) :: :all | [term()]
  def scopes(opts) do
    cond do
      Keyword.has_key?(opts, :scopes) ->
        case Keyword.get(opts, :scopes) do
          :all -> :all
          scopes -> List.wrap(scopes)
        end

      Keyword.has_key?(opts, :scope) ->
        [Keyword.get(opts, :scope)]

      true ->
        [nil]
    end
  end

  @spec namespace_match?(term(), binary(), keyword()) :: boolean()
  defp namespace_match?(memory, namespace, opts) do
    case Identity.namespace(memory) do
      ^namespace -> true
      nil -> Keyword.get(opts, :allow_legacy_namespace?, false)
      _other -> false
    end
  end

  @spec scope_match?(term(), keyword()) :: boolean()
  defp scope_match?(memory, opts) do
    requested = scopes(opts)
    requested == :all or scope(memory) in requested
  end
end
