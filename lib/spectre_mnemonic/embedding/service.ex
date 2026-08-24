defmodule SpectreMnemonic.Embedding.Service do
  @moduledoc """
  Small wrapper around configured embedding providers.

  No provider is required. When none is configured, or when it fails, signals
  are still ingested and recall falls back to text, hamming, and graph matching.
  Legacy `:embedding_adapter` remains a compatibility override.

  The service normalizes provider output into one internal shape:

      %{
        vector: <<_::binary>> | nil,
        binary_signature: <<_::binary>> | nil,
        metadata: map(),
        error: term() | nil
      }

  Callers and providers may supply a raw list vector or a map with vector
  metadata. This module converts vectors to normalized `:f32` binaries and
  builds a compact binary signature for hamming-based recall.
  """

  alias SpectreMnemonic.Embedding.BinaryQuantizer
  alias SpectreMnemonic.Embedding.Vector

  @doc """
  Normalizes a caller embedding or embeds input through a configured provider.

  `embed/2` never raises provider errors to callers. A failed or unavailable
  provider returns an embedding map with `vector: nil` and an `:error` value so
  ingestion can continue.

  Resolution order:

    1. Per-call `:embedding` or `:vector`.
    2. `:embedding_adapter` application config.
    3. Fast local provider config under `:embedding`.
    4. Empty embedding fallback.

  ## Examples

      iex> SpectreMnemonic.Embedding.Service.embed("hello", [])
      %{vector: nil, binary_signature: nil, metadata: %{}, error: nil}

      iex> SpectreMnemonic.Embedding.Service.embed("hello", signature_bits: 16)
      %{vector: _vector_or_nil, binary_signature: _signature_or_nil, metadata: _metadata, error: _error}
  """
  @spec embed(input :: term(), opts :: keyword()) :: map()
  def embed(input, opts) do
    do_embed(input, opts)
  rescue
    exception -> failed(exception)
  catch
    kind, reason -> failed({kind, reason})
  end

  @spec do_embed(term(), keyword()) :: map()
  defp do_embed(input, opts) do
    # Embeddings improve recall, but ingestion must not depend on them. Models,
    # files, and NIFs fail in creative ways. Text still gets remembered.
    case direct_embedding(opts) do
      {:ok, embedding} ->
        normalize_direct_result(embedding, opts)

      {:error, reason} ->
        failed(reason)

      :missing ->
        embed_with_configured_provider(input, opts)
    end
  end

  @spec direct_embedding(keyword()) :: {:ok, term()} | {:error, term()} | :missing
  defp direct_embedding(opts) do
    cond do
      Keyword.has_key?(opts, :embedding) -> normalize_direct_embedding(opts[:embedding])
      Keyword.has_key?(opts, :vector) -> normalize_direct_embedding(%{vector: opts[:vector]})
      true -> :missing
    end
  end

  @spec normalize_direct_embedding(term()) :: {:ok, term()} | {:error, :invalid_embedding}
  defp normalize_direct_embedding(vector) when is_list(vector) or is_binary(vector),
    do: {:ok, %{vector: vector, metadata: %{provider: :caller}}}

  defp normalize_direct_embedding(%{} = embedding), do: {:ok, embedding}
  defp normalize_direct_embedding(_embedding), do: {:error, :invalid_embedding}

  @spec normalize_direct_result(term(), keyword()) :: map()
  defp normalize_direct_result(embedding, opts) do
    case normalize_result(embedding, opts) do
      %{vector: vector, metadata: metadata} = normalized
      when is_binary(vector) and byte_size(vector) > 0 ->
        %{normalized | metadata: Map.put_new(metadata, :provider, :caller)}

      _invalid ->
        failed(:invalid_embedding)
    end
  end

  @spec embed_with_configured_provider(term(), keyword()) :: map()
  defp embed_with_configured_provider(input, opts) do
    adapter = Application.get_env(:spectre_mnemonic, :embedding_adapter)

    cond do
      not is_nil(adapter) -> embed_with_adapter(adapter, input, opts)
      fast_enabled?() -> embed_with_fast_provider(input, opts)
      true -> empty()
    end
  end

  @spec embed_with_adapter(module(), term(), keyword()) :: map()
  defp embed_with_adapter(adapter, input, opts) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :embed, 2) do
      call_adapter(adapter, input, opts)
    else
      failed(:adapter_not_available)
    end
  end

  @spec embed_with_fast_provider(term(), keyword()) :: map()
  defp embed_with_fast_provider(input, opts) do
    provider = Keyword.get(fast_config(), :provider, SpectreMnemonic.Embedding.Model2VecStatic)
    provider_opts = Keyword.merge(fast_config(), opts)

    if provider_available?(provider),
      do: call_fast_provider(provider, input, provider_opts),
      else: failed(:provider_not_available)
  rescue
    exception -> failed(exception)
  catch
    kind, reason -> failed({kind, reason})
  end

  @spec call_fast_provider(module(), term(), keyword()) :: map()
  defp call_fast_provider(provider, input, provider_opts) do
    # Providers are allowed to fail without breaking ingestion. The recall
    # engine still has text, metadata, fingerprint, and graph signals.
    case provider.embed(input, provider_opts) do
      {:ok, result} -> normalize_result(result, provider_opts)
      {:error, :model_dir_not_configured} -> empty()
      {:error, reason} -> failed(reason)
      result when is_map(result) -> normalize_result(result, provider_opts)
      other -> failed({:unexpected_provider_result, other})
    end
  end

  @spec provider_available?(term()) :: boolean()
  defp provider_available?(provider) do
    is_atom(provider) and Code.ensure_loaded?(provider) and
      function_exported?(provider, :embed, 2)
  end

  @spec call_adapter(module(), term(), keyword()) :: map()
  defp call_adapter(adapter, input, opts) do
    case adapter.embed(input, opts) do
      {:ok, vector} when is_list(vector) ->
        normalize_result(%{vector: vector, metadata: %{provider: adapter}}, opts)

      {:ok, result} when is_map(result) ->
        normalize_result(result, opts)

      {:error, reason} ->
        failed(reason)
    end
  rescue
    exception -> failed(exception)
  catch
    kind, reason -> failed({kind, reason})
  end

  @spec normalize_result(term(), keyword()) :: map()
  defp normalize_result(result, opts) when is_map(result) do
    # Provider output is where little format differences go to breed. Normalize
    # once here so the rest of the code can stay boring and mildly hydrated.
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

  @spec metadata(map(), non_neg_integer(), non_neg_integer() | nil, keyword()) :: map()
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

    result_metadata = normalize_metadata(fetch_key(result, :metadata))

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

  @spec fast_enabled? :: boolean()
  defp fast_enabled? do
    fast_config()
    |> Keyword.get(:enabled, false)
    |> Kernel.==(true)
  end

  @spec fast_config :: keyword()
  defp fast_config do
    :spectre_mnemonic
    |> Application.get_env(:embedding, [])
    |> normalize_config()
    |> Keyword.get(:fast, [])
    |> normalize_config()
  end

  @spec normalize_config(term()) :: keyword()
  defp normalize_config(config) when is_map(config), do: Map.to_list(config)

  defp normalize_config(config) when is_list(config) do
    if Keyword.keyword?(config), do: config, else: []
  end

  defp normalize_config(_config), do: []

  @spec normalize_metadata(term()) :: map()
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  @spec empty :: map()
  defp empty, do: %{vector: nil, binary_signature: nil, metadata: %{}, error: nil}

  @spec failed(term()) :: map()
  defp failed(reason),
    do: %{vector: nil, binary_signature: nil, metadata: %{}, error: reason}

  @spec fetch_key(map(), atom()) :: term()
  defp fetch_key(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
