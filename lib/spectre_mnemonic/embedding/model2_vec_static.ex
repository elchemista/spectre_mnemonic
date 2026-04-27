defmodule SpectreMnemonic.Embedding.Model2VecStatic do
  @moduledoc """
  Minimal local Model2Vec static embedder.

  It reads `tokenizer.json` and `model.safetensors` from a configured model
  directory, tokenizes text, mean-pools token vectors, normalizes the result,
  and returns the standard Spectre Mnemonic embedding shape.
  """

  alias SpectreMnemonic.Embedding.{BinaryQuantizer, Vector}

  @doc "Embeds input using local Model2Vec artifacts."
  def embed(input, opts \\ []) do
    with {:ok, model_dir} <- model_dir(opts),
         tokenizer_path <- Path.join(model_dir, "tokenizer.json"),
         {:ok, tokenizer} <- load_json(tokenizer_path),
         {:ok, model} <- load_safetensors(Path.join(model_dir, "model.safetensors")),
         token_ids when token_ids != [] <- tokenize(input, tokenizer, tokenizer_path),
         {:ok, vector} <- mean_pool(model, token_ids) do
      dimensions = Keyword.get(opts, :dimensions) || length(vector)
      signature_bits = Keyword.get(opts, :signature_bits, dimensions)
      dense = vector |> Vector.normalize() |> Vector.to_f32_binary()

      {:ok,
       %{
         vector: dense,
         binary_signature: BinaryQuantizer.quantize(dense, bits: signature_bits),
         metadata: %{
           format: :f32_binary,
           dimensions: dimensions,
           model: Keyword.get(opts, :model_id, Path.basename(model_dir)),
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
  end

  defp model_dir(opts) do
    case Keyword.get(opts, :model_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _missing -> {:error, :model_dir_not_configured}
    end
  end

  defp load_json(path) do
    with true <- File.exists?(path) || {:error, {:missing_model_file, path}},
         {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    end
  end

  defp load_safetensors(path) do
    with true <- File.exists?(path) || {:error, {:missing_model_file, path}},
         {:ok, <<header_size::little-unsigned-integer-64, rest::binary>>} <- File.read(path),
         <<header_json::binary-size(header_size), tensor_data::binary>> <- rest,
         {:ok, header} <- Jason.decode(header_json),
         {:ok, tensor_name, tensor} <- find_f32_matrix(header) do
      %{"data_offsets" => [start_offset, end_offset], "shape" => [rows, dimensions]} = tensor
      tensor_bytes = binary_part(tensor_data, start_offset, end_offset - start_offset)
      {:ok, %{name: tensor_name, rows: rows, dimensions: dimensions, data: tensor_bytes}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_safetensors_file}
    end
  end

  defp find_f32_matrix(header) do
    header
    |> Enum.reject(fn {name, _value} -> name == "__metadata__" end)
    |> Enum.find(fn {_name, value} ->
      Map.get(value, "dtype") == "F32" and
        match?([rows, dim] when rows > 0 and dim > 0, Map.get(value, "shape"))
    end)
    |> case do
      {name, tensor} -> {:ok, name, tensor}
      nil -> {:error, :missing_f32_matrix}
    end
  end

  defp tokenize(input, tokenizer, tokenizer_path) do
    text = if is_binary(input), do: input, else: inspect(input)

    case hf_token_ids(text, tokenizer_path) do
      {:ok, ids} when ids != [] ->
        Enum.uniq(ids)

      _fallback ->
        fallback_token_ids(text, tokenizer)
    end
  end

  defp hf_token_ids(text, tokenizer_path) do
    with true <- Code.ensure_loaded?(Tokenizers.Tokenizer),
         true <- Code.ensure_loaded?(Tokenizers.Encoding),
         {:ok, tokenizer} <- Tokenizers.Tokenizer.from_file(tokenizer_path),
         {:ok, encoding} <-
           Tokenizers.Tokenizer.encode(tokenizer, text, add_special_tokens: false) do
      {:ok, Tokenizers.Encoding.get_ids(encoding)}
    else
      _error -> :error
    end
  rescue
    _exception -> :error
  end

  defp fallback_token_ids(text, tokenizer) do
    text
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]_]+/u, trim: true)
    |> Enum.flat_map(&token_ids(&1, tokenizer))
    |> Enum.uniq()
  end

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
  end

  defp mean_pool(%{rows: rows, dimensions: dimensions, data: data}, token_ids) do
    vectors =
      token_ids
      |> Enum.filter(&(&1 >= 0 and &1 < rows))
      |> Enum.map(&read_row(data, &1, dimensions))

    if vectors == [] do
      {:error, :tokens_out_of_vocab}
    else
      mean =
        vectors
        |> Enum.zip()
        |> Enum.map(fn tuple ->
          tuple
          |> Tuple.to_list()
          |> Enum.sum()
          |> Kernel./(length(vectors))
        end)

      {:ok, mean}
    end
  end

  defp read_row(data, row, dimensions) do
    offset = row * dimensions * 4

    for <<value::little-float-32 <- binary_part(data, offset, dimensions * 4)>> do
      value
    end
  end
end
