defmodule SpectreMnemonic.Embedding.Model2VecStatic do
  @moduledoc """
  Minimal local Model2Vec static embedder.

  It reads `tokenizer.json` and `model.safetensors` from a configured model
  directory, tokenizes text, mean-pools its little-endian f32 table through
  Vettore, normalizes the result, and returns the standard Spectre Mnemonic
  embedding shape.
  """

  alias SpectreMnemonic.Embedding.BinaryQuantizer
  alias SpectreMnemonic.Embedding.ModelCache
  alias SpectreMnemonic.Embedding.ModelDownloader
  alias SpectreMnemonic.Embedding.Vector

  @tokenizer_module Module.concat(["Tokenizers", "Tokenizer"])
  @encoding_module Module.concat(["Tokenizers", "Encoding"])
  @model_files ["config.json", "tokenizer.json", "model.safetensors"]
  @model_option_keys [
    :model_dir,
    :model_id,
    :cache_dir,
    :files,
    :checksums,
    :download,
    :source_dir,
    :base_url,
    :revision
  ]

  @doc "Embeds input using local Model2Vec artifacts."
  @spec embed(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def embed(input, opts \\ []) do
    # Local embeddings are nice because no request leaves the machine. They are
    # also fussy little file creatures, so every step returns shape errors
    # instead of turning intake into a bonfire.
    with {:ok, artifacts} <- artifacts(opts),
         token_ids when token_ids != [] <-
           tokenize(input, artifacts.tokenizer, artifacts.native_tokenizer),
         {:ok, vector} <- mean_pool(artifacts.model, token_ids) do
      dimensions = Keyword.get(opts, :dimensions) || Vector.dimensions(vector)
      signature_bits = Keyword.get(opts, :signature_bits, dimensions)
      dense = Vector.normalize_to_f32_binary(vector)

      {:ok,
       %{
         vector: dense,
         binary_signature: BinaryQuantizer.quantize(dense, bits: signature_bits),
         metadata: %{
           format: :f32_binary,
           dimensions: dimensions,
           model: Keyword.get(opts, :model_id, Path.basename(artifacts.model_dir)),
           normalized: true,
           signature_bits: signature_bits,
           provider: __MODULE__
         },
         error: nil
       }}
    else
      [] -> {:error, :no_tokens}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_model2vec_result, other}}
    end
  rescue
    _exception -> {:error, :invalid_model_artifacts}
  catch
    _kind, _reason -> {:error, :invalid_model_artifacts}
  end

  @doc "Clears cached model artifacts so the next embedding reloads them from disk."
  @spec reset_cache :: :ok
  def reset_cache, do: ModelCache.reset()

  @spec artifacts(keyword()) :: {:ok, map()} | {:error, term()}
  defp artifacts(opts) do
    with {:ok, model_dir} <- model_dir(opts),
         {:ok, signature} <- artifact_signature(model_dir) do
      cache_key = {:artifacts, Path.expand(model_dir)}

      case cache_lookup(cache_key) do
        %{signature: ^signature} = cached ->
          {:ok, cached}

        _missing_or_changed ->
          load_artifacts(model_dir, signature, cache_key)
      end
    end
  end

  @spec load_artifacts(Path.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  defp load_artifacts(model_dir, signature, cache_key) do
    tokenizer_path = Path.join(model_dir, "tokenizer.json")

    with {:ok, tokenizer} <- load_json(tokenizer_path),
         {:ok, model} <- load_safetensors(Path.join(model_dir, "model.safetensors")) do
      artifacts = %{
        model_dir: model_dir,
        signature: signature,
        tokenizer: tokenizer,
        native_tokenizer: load_native_tokenizer(tokenizer_path),
        model: model
      }

      cache_put(cache_key, artifacts)
      {:ok, artifacts}
    end
  end

  @spec model_dir(keyword()) :: {:ok, Path.t()} | {:error, term()}
  defp model_dir(opts) do
    cache_key = {:model_dir, model_options_digest(opts)}

    case cache_lookup(cache_key) do
      %{model_dir: model_dir, signature: signature} ->
        case artifact_signature(model_dir) do
          {:ok, ^signature} -> {:ok, model_dir}
          _changed -> ensure_and_cache_model_dir(opts, cache_key)
        end

      _missing ->
        ensure_and_cache_model_dir(opts, cache_key)
    end
  end

  @spec ensure_and_cache_model_dir(keyword(), term()) :: {:ok, Path.t()} | {:error, term()}
  defp ensure_and_cache_model_dir(opts, cache_key) do
    with {:ok, model_dir} <- ModelDownloader.ensure_model(opts),
         {:ok, signature} <- artifact_signature(model_dir) do
      cache_put(cache_key, %{model_dir: model_dir, signature: signature})
      {:ok, model_dir}
    end
  end

  @spec model_options_digest(keyword()) :: binary()
  defp model_options_digest(opts) do
    opts
    |> Keyword.take(@model_option_keys)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec artifact_signature(Path.t()) :: {:ok, list()} | {:error, term()}
  defp artifact_signature(model_dir) do
    Enum.reduce_while(@model_files, {:ok, []}, fn file, {:ok, acc} ->
      path = Path.join(model_dir, file)

      case File.stat(path, time: :posix) do
        {:ok, stat} ->
          fingerprint = {file, stat.size, stat.mtime, stat.ctime, stat.inode}
          {:cont, {:ok, [fingerprint | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:missing_model_file, path, reason}}}
      end
    end)
    |> case do
      {:ok, signature} -> {:ok, Enum.reverse(signature)}
      {:error, _reason} = error -> error
    end
  end

  @spec cache_lookup(term()) :: term() | nil
  defp cache_lookup(key), do: ModelCache.get(key)

  @spec cache_put(term(), term()) :: :ok
  defp cache_put(key, value), do: ModelCache.put(key, value)

  @spec load_json(Path.t()) :: {:ok, map()} | {:error, term()}
  defp load_json(path) do
    with :ok <- ensure_file(path),
         {:ok, body} <- File.read(path) do
      SpectreMnemonic.JSON.decode(body)
    end
  end

  @spec load_safetensors(Path.t()) :: {:ok, map()} | {:error, term()}
  defp load_safetensors(path) do
    with :ok <- ensure_file(path),
         {:ok, <<header_size::little-unsigned-integer-64, rest::binary>>} <- File.read(path),
         <<header_json::binary-size(^header_size), tensor_data::binary>> <- rest,
         {:ok, header} <- SpectreMnemonic.JSON.decode(header_json),
         {:ok, tensor_name, tensor} <- find_f32_matrix(header),
         {:ok, start_offset, end_offset, rows, dimensions} <-
           tensor_layout(tensor, byte_size(tensor_data)) do
      tensor_bytes = binary_part(tensor_data, start_offset, end_offset - start_offset)

      {:ok,
       %{
         name: tensor_name,
         rows: rows,
         dimensions: dimensions,
         data: tensor_bytes
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_safetensors_file}
    end
  end

  @spec ensure_file(Path.t()) :: :ok | {:error, {:missing_model_file, Path.t()}}
  defp ensure_file(path) do
    if File.exists?(path), do: :ok, else: {:error, {:missing_model_file, path}}
  end

  @spec find_f32_matrix(map()) :: {:ok, binary(), map()} | {:error, :missing_f32_matrix}
  defp find_f32_matrix(header) when is_map(header) do
    header
    |> Enum.reject(fn {name, _value} -> name == "__metadata__" end)
    |> Enum.find(fn {_name, value} ->
      is_map(value) and Map.get(value, "dtype") == "F32" and
        match?([rows, dim] when rows > 0 and dim > 0, Map.get(value, "shape"))
    end)
    |> case do
      {name, tensor} -> {:ok, name, tensor}
      nil -> {:error, :missing_f32_matrix}
    end
  end

  defp find_f32_matrix(_header), do: {:error, :missing_f32_matrix}

  @spec tensor_layout(map(), non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
          | {:error, :invalid_safetensors_file}
  defp tensor_layout(
         %{"data_offsets" => [start_offset, end_offset], "shape" => [rows, dimensions]},
         data_size
       ) do
    if valid_offsets?(start_offset, end_offset, data_size) and
         valid_shape?(rows, dimensions, end_offset - start_offset) do
      {:ok, start_offset, end_offset, rows, dimensions}
    else
      {:error, :invalid_safetensors_file}
    end
  end

  defp tensor_layout(_tensor, _data_size), do: {:error, :invalid_safetensors_file}

  @spec valid_offsets?(term(), term(), non_neg_integer()) :: boolean()
  defp valid_offsets?(start_offset, end_offset, data_size) do
    is_integer(start_offset) and is_integer(end_offset) and start_offset >= 0 and
      end_offset >= start_offset and end_offset <= data_size
  end

  @spec valid_shape?(term(), term(), non_neg_integer()) :: boolean()
  defp valid_shape?(rows, dimensions, byte_size) do
    is_integer(rows) and is_integer(dimensions) and rows > 0 and dimensions > 0 and
      byte_size == rows * dimensions * 4
  end

  @spec tokenize(term(), map(), term()) :: [integer()]
  defp tokenize(input, tokenizer, native_tokenizer) do
    text = if is_binary(input), do: input, else: inspect(input)

    case hf_token_ids(text, native_tokenizer) do
      {:ok, ids} when ids != [] ->
        ids

      _fallback ->
        fallback_token_ids(text, tokenizer)
    end
  end

  @spec load_native_tokenizer(Path.t()) :: term() | nil
  defp load_native_tokenizer(tokenizer_path) do
    case optional_call(@tokenizer_module, :from_file, [tokenizer_path]) do
      {:ok, tokenizer} -> tokenizer
      _unavailable -> nil
    end
  end

  @spec hf_token_ids(binary(), term()) :: {:ok, [integer()]} | :error
  defp hf_token_ids(_text, nil), do: :error

  defp hf_token_ids(text, tokenizer) do
    with {:ok, encoding} <-
           optional_call(@tokenizer_module, :encode, [
             tokenizer,
             text,
             [add_special_tokens: false]
           ]),
         ids when is_list(ids) <- optional_call(@encoding_module, :get_ids, [encoding]) do
      {:ok, ids}
    else
      _error -> :error
    end
  rescue
    _exception -> :error
  end

  @spec optional_call(module(), atom(), [term()]) :: term()
  defp optional_call(module, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      # Optional dependencies require runtime dispatch so downstream projects
      # can compile without the Tokenizers modules being present.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(module, function, args)
    else
      :unavailable
    end
  rescue
    _exception -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  @spec fallback_token_ids(binary(), map()) :: [integer()]
  defp fallback_token_ids(text, tokenizer) do
    # Tokenizers NIF unavailable? Fine. The fallback is dumber, but dumber and
    # working beats clever and unavailable on a Tuesday afternoon.
    text
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]_]+/u, trim: true)
    |> Enum.flat_map(&token_ids(&1, tokenizer))
  end

  @spec token_ids(binary(), map()) :: [integer()]
  defp token_ids(token, tokenizer) do
    vocab = tokenizer["model"]["vocab"] || tokenizer["vocab"] || %{}

    candidates = [
      token,
      " " <> token,
      "Ġ" <> token,
      "▁" <> token,
      String.capitalize(token)
    ]

    candidates
    |> Enum.flat_map(fn candidate ->
      case Map.get(vocab, candidate) do
        id when is_integer(id) -> [id]
        [id, _score] when is_integer(id) -> [id]
        _missing -> []
      end
    end)
    |> Enum.uniq()
  end

  @spec mean_pool(map(), [integer()]) :: {:ok, term()} | {:error, term()}
  defp mean_pool(%{rows: rows, dimensions: dimensions, data: data}, token_ids) do
    token_ids = Enum.filter(token_ids, &(&1 >= 0 and &1 < rows))

    if token_ids == [] do
      {:error, :tokens_out_of_vocab}
    else
      Vettore.Vector.mean_pool_f32(data, dimensions, token_ids, as: :list)
    end
  end
end
