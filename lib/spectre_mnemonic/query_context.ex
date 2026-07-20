defmodule SpectreMnemonic.QueryContext do
  @moduledoc """
  Immutable, namespaced context shared by every stage of one search.

  Building a context performs the query embedding exactly once. Active recall,
  durable search, observations, and mental models reuse the same vector and
  normalized text instead of independently calling an embedding provider.
  """

  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Recall.Fingerprint

  @type t :: %__MODULE__{
          input: term(),
          text: binary(),
          namespace: binary(),
          scope: term(),
          scopes: [term()],
          keywords: [binary()],
          entities: [binary()],
          vector: binary() | [number()] | nil,
          binary_signature: binary() | nil,
          embedding: map() | nil,
          fingerprint: non_neg_integer() | nil,
          opts: keyword()
        }

  defstruct [
    :input,
    :text,
    :namespace,
    :scope,
    :vector,
    :binary_signature,
    :embedding,
    :fingerprint,
    scopes: [nil],
    keywords: [],
    entities: [],
    opts: []
  ]

  @doc "Builds a query context and computes its embedding once."
  @spec new(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(input, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      text = if is_binary(input), do: input, else: inspect(input)
      embedding = Service.embed(input, opts)

      {:ok,
       %__MODULE__{
         input: input,
         text: text,
         namespace: Identity.namespace!(opts),
         scope: Keyword.get(opts, :scope),
         scopes: requested_scopes(opts),
         keywords: keywords(text),
         entities: entities(text),
         vector: Map.get(embedding, :vector),
         binary_signature: Map.get(embedding, :binary_signature),
         embedding: embedding,
         fingerprint: Fingerprint.build(text),
         opts: opts
       }}
    end
  end

  @doc "Returns an existing compatible context or builds a new one."
  @spec ensure(t() | term(), keyword()) :: {:ok, t()} | {:error, term()}
  def ensure(%__MODULE__{} = context, opts) do
    with {:ok, opts} <- Identity.put_namespace(Keyword.merge(context.opts, opts)),
         :ok <- validate_namespace(context, opts),
         :ok <- validate_partition(context, opts) do
      {:ok, %{context | opts: opts}}
    end
  end

  def ensure(input, opts), do: new(input, opts)

  @doc "Returns the normalized query text."
  @spec text(t() | term()) :: binary()
  def text(%__MODULE__{text: text}), do: text
  def text(input) when is_binary(input), do: input
  def text(input), do: inspect(input)

  @spec requested_scopes(keyword()) :: [term()]
  defp requested_scopes(opts), do: [Keyword.get(opts, :scope)]

  @spec validate_namespace(t(), keyword()) :: :ok | {:error, term()}
  defp validate_namespace(context, opts) do
    requested = Identity.namespace!(opts)

    if context.namespace == requested,
      do: :ok,
      else: {:error, {:query_context_namespace_mismatch, context.namespace, requested}}
  end

  @spec validate_partition(t(), keyword()) :: :ok | {:error, term()}
  defp validate_partition(context, opts) do
    requested = requested_scopes(opts)
    requested_scope = Keyword.get(opts, :scope)

    cond do
      context.scope != requested_scope ->
        {:error, {:query_context_scope_mismatch, [context.scope], requested}}

      context.scopes != requested ->
        {:error, {:query_context_scope_mismatch, context.scopes, requested}}

      true ->
        :ok
    end
  end

  @spec keywords(binary()) :: [binary()]
  defp keywords(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b\p{Lu}[\p{L}\p{N}_]+\b/u, text)
    |> List.flatten()
    |> Enum.uniq()
  end
end
