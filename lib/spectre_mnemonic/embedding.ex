defmodule SpectreMnemonic.Embedding.Adapter do
  @moduledoc """
  Behaviour for user-provided embedding adapters.

  Configure with:

      config :spectre_mnemonic, embedding_adapter: MyApp.EmbeddingAdapter
  """

  @callback embed(input :: term(), opts :: keyword()) ::
              {:ok, vector :: list(number())}
              | {:ok, embedding_result :: map()}
              | {:error, reason :: term()}
end

defmodule SpectreMnemonic.Embedding do
  @moduledoc """
  Small wrapper around configured embedding providers.

  No provider is required. When none is configured, or when it fails, signals
  are still ingested and recall falls back to text, hamming, and graph matching.
  Legacy `:embedding_adapter` remains a compatibility override.
  """

  alias SpectreMnemonic.Embedding.{BinaryQuantizer, Vector}

  @doc "Embeds input when an adapter is configured, otherwise returns an empty embedding."
  def embed(input, opts) do
    adapter = Application.get_env(:spectre_mnemonic, :embedding_adapter)

    cond do
      not is_nil(adapter) ->
        embed_with_adapter(adapter, input, opts)

      fast_enabled?() ->
        embed_with_fast_provider(input, opts)

      true ->
        empty()
    end
  end

  defp embed_with_adapter(adapter, input, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :embed, 2) do
      call_adapter(adapter, input, opts)
    else
      %{vector: nil, binary_signature: nil, metadata: %{}, error: :adapter_not_available}
    end
  end

  defp embed_with_fast_provider(input, opts) do
    provider = Keyword.get(fast_config(), :provider, SpectreMnemonic.Embedding.Model2VecStatic)
    provider_opts = Keyword.merge(fast_config(), opts)

    cond do
      not Code.ensure_loaded?(provider) ->
        %{vector: nil, binary_signature: nil, metadata: %{}, error: :provider_not_available}

      function_exported?(provider, :embed, 2) ->
        case provider.embed(input, provider_opts) do
          {:ok, result} ->
            normalize_result(result, provider_opts)

          {:error, :model_dir_not_configured} ->
            empty()

          {:error, reason} ->
            %{vector: nil, binary_signature: nil, metadata: %{}, error: reason}

          result when is_map(result) ->
            normalize_result(result, provider_opts)

          other ->
            %{
              vector: nil,
              binary_signature: nil,
              metadata: %{},
              error: {:unexpected_provider_result, other}
            }
        end

      true ->
        %{vector: nil, binary_signature: nil, metadata: %{}, error: :provider_not_available}
    end
  end

  defp call_adapter(adapter, input, opts) do
    case adapter.embed(input, opts) do
      {:ok, vector} when is_list(vector) ->
        normalize_result(%{vector: vector, metadata: %{provider: adapter}}, opts)

      {:ok, result} when is_map(result) ->
        normalize_result(result, opts)

      {:error, reason} ->
        %{vector: nil, binary_signature: nil, metadata: %{}, error: reason}
    end
  rescue
    exception -> %{vector: nil, binary_signature: nil, metadata: %{}, error: exception}
  end

  defp normalize_result(result, opts) when is_map(result) do
    vector = fetch_key(result, :vector)
    normalized = Vector.normalize_to_f32_binary(vector)
    dimensions = fetch_key(result, :dimensions) || Vector.dimensions(normalized)

    signature_bits =
      fetch_key(result, :signature_bits) || Keyword.get(opts, :signature_bits, dimensions)

    signature =
      fetch_key(result, :binary_signature) ||
        BinaryQuantizer.quantize(normalized, bits: signature_bits)

    metadata = metadata(result, dimensions, signature_bits, opts)

    %{
      vector: normalized,
      binary_signature: signature,
      metadata: metadata,
      error: fetch_key(result, :error)
    }
  end

  defp normalize_result(vector, opts) when is_list(vector) do
    normalize_result(%{vector: vector}, opts)
  end

  defp normalize_result(_result, _opts), do: empty()

  defp metadata(result, dimensions, signature_bits, opts) do
    inline_metadata =
      result
      |> Enum.reject(fn {key, _value} ->
        key in [
          :vector,
          "vector",
          :binary_signature,
          "binary_signature",
          :metadata,
          "metadata",
          :error,
          "error"
        ]
      end)
      |> Map.new()

    result_metadata = fetch_key(result, :metadata) || %{}

    %{
      format: :f32_binary,
      dimensions: dimensions,
      model: fetch_key(result, :model) || Keyword.get(opts, :model_id),
      normalized: true,
      signature_bits: signature_bits
    }
    |> Map.merge(inline_metadata)
    |> Map.merge(result_metadata)
  end

  defp fast_enabled? do
    fast_config()
    |> Keyword.get(:enabled, false)
  end

  defp fast_config do
    :spectre_mnemonic
    |> Application.get_env(:embedding, [])
    |> Keyword.get(:fast, [])
  end

  defp empty, do: %{vector: nil, binary_signature: nil, metadata: %{}, error: nil}

  defp fetch_key(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

defmodule SpectreMnemonic.Summarizer.Adapter do
  @moduledoc "Optional behaviour for applications that want LLM or local summarization."

  @callback summarize(input :: term(), opts :: keyword()) ::
              {:ok, gist :: term()} | {:error, reason :: term()}
end
