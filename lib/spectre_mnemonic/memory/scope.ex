defmodule SpectreMnemonic.Memory.Scope do
  @moduledoc false

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

  @doc "Returns true when memory matches the requested scope filters."
  @spec match?(term(), keyword()) :: boolean()
  def match?(memory, opts) do
    scopes = scopes(opts)

    scopes == :all or scope(memory) in scopes
  end

  @spec scopes(keyword()) :: :all | [term()]
  def scopes(opts) do
    cond do
      Keyword.has_key?(opts, :scopes) ->
        opts |> Keyword.get(:scopes) |> List.wrap()

      Keyword.has_key?(opts, :scope) ->
        [Keyword.get(opts, :scope)]

      true ->
        :all
    end
  end
end
