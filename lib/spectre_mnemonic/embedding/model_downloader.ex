defmodule SpectreMnemonic.Embedding.ModelDownloader do
  @moduledoc """
  Downloads and caches embedding model artifacts.

  Downloads are opt-in. A provider can pass `download: true` with a `model_id`
  and this module will ensure the required files exist in a cache directory.
  The default remote source is Hugging Face's `resolve/main` endpoint; tests and
  deployments can use `source_dir` or `base_url` for mirrors.
  """

  @required_files ["config.json", "tokenizer.json", "model.safetensors"]
  @default_timeout 30_000
  @sha256_pattern ~r/\A[0-9a-fA-F]{64}\z/

  @doc "Returns the required Model2Vec artifact names."
  @spec required_files :: [binary()]
  def required_files, do: @required_files

  @doc """
  Ensures model artifacts exist locally and returns `{:ok, model_dir}`.

  If `:model_dir` already has all required files, no download occurs. Otherwise
  `download: true` is required, and artifacts are written to `:model_dir` or to
  the computed cache path for `:model_id`.
  """
  @spec ensure_model(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_model(opts) do
    with {:ok, files} <- requested_files(opts),
         :ok <- validate_checksums(opts, files),
         {:ok, dir} <- target_dir(opts),
         :ok <- ensure_or_download(dir, files, opts) do
      {:ok, dir}
    end
  rescue
    exception -> {:error, {:invalid_model_options, Exception.message(exception)}}
  end

  @doc "Downloads every requested model file into the target cache directory."
  @spec download_model(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def download_model(opts) do
    with {:ok, files} <- requested_files(opts),
         :ok <- validate_checksums(opts, files),
         {:ok, dir} <- target_dir(opts),
         :ok <- File.mkdir_p(dir) do
      download_files(files, dir, opts)
    end
  rescue
    exception -> {:error, {:invalid_model_options, Exception.message(exception)}}
  end

  @doc "Returns the cache directory for a model id."
  @spec cache_dir(binary(), keyword()) :: Path.t()
  def cache_dir(model_id, opts \\ []) do
    root =
      Keyword.get(opts, :cache_dir) ||
        Application.get_env(:spectre_mnemonic, :model_cache_dir) ||
        default_cache_root()

    Path.join(root, safe_model_id(model_id))
  end

  @spec ensure_or_download(Path.t(), [binary()], keyword()) :: :ok | {:error, term()}
  defp ensure_or_download(dir, files, opts) do
    missing = missing_files(dir, files)

    cond do
      missing == [] and checksums_ok?(dir, opts) ->
        :ok

      Keyword.get(opts, :download, false) ->
        case download_model(opts) do
          {:ok, ^dir} -> :ok
          {:ok, _other_dir} -> :ok
          {:error, reason} -> {:error, reason}
        end

      missing != [] ->
        {:error, {:missing_model_files, dir, missing}}

      true ->
        {:error, {:model_checksum_verification_failed, dir}}
    end
  end

  @spec missing_files(Path.t(), [binary()]) :: [binary()]
  defp missing_files(dir, files) do
    Enum.reject(files, &File.regular?(Path.join(dir, &1)))
  end

  @spec target_dir(keyword()) :: {:ok, Path.t()} | {:error, :model_dir_not_configured}
  defp target_dir(opts) do
    cond do
      is_binary(Keyword.get(opts, :model_dir)) and Keyword.get(opts, :model_dir) != "" ->
        {:ok, Keyword.fetch!(opts, :model_dir)}

      valid_model_id?(Keyword.get(opts, :model_id)) ->
        {:ok, cache_dir(Keyword.fetch!(opts, :model_id), opts)}

      not is_nil(Keyword.get(opts, :model_id)) ->
        {:error, {:invalid_model_id, Keyword.get(opts, :model_id)}}

      true ->
        {:error, :model_dir_not_configured}
    end
  end

  @spec requested_files(keyword()) :: {:ok, [binary()]} | {:error, term()}
  defp requested_files(opts) do
    files = Keyword.get(opts, :files, @required_files)

    cond do
      not is_list(files) or files == [] ->
        {:error, :model_files_required}

      invalid = Enum.find(files, &(not safe_relative_file?(&1))) ->
        {:error, {:invalid_model_file, invalid}}

      true ->
        {:ok, files}
    end
  end

  @spec safe_relative_file?(term()) :: boolean()
  defp safe_relative_file?(file) when is_binary(file) and file != "" do
    Path.type(file) == :relative and
      Enum.all?(Path.split(file), &(&1 not in [".", ".."]))
  end

  defp safe_relative_file?(_file), do: false

  @spec download_file(binary(), Path.t(), keyword()) :: :ok | {:error, term()}
  defp download_file(file, dir, opts) do
    destination = Path.join(dir, file)

    with {:ok, bytes} <- fetch_file(file, opts),
         :ok <- verify_checksum(file, bytes, opts) do
      write_atomic(destination, bytes)
    end
  end

  @spec download_files([binary()], Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  defp download_files(files, dir, opts) do
    Enum.reduce_while(files, {:ok, dir}, fn file, {:ok, _dir} ->
      case download_file(file, dir, opts) do
        :ok -> {:cont, {:ok, dir}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec fetch_file(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp fetch_file(file, opts) do
    case configured_source(opts, :source_dir) do
      {:ok, source_dir} -> File.read(Path.join(source_dir, file))
      :missing -> fetch_remote_file(file, opts)
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_remote_file(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp fetch_remote_file(file, opts) do
    case configured_source(opts, :base_url) do
      {:ok, base_url} -> http_get(join_url(base_url, file), opts)
      :missing -> fetch_hugging_face_file(file, opts)
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_hugging_face_file(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp fetch_hugging_face_file(file, opts) do
    case Keyword.fetch(opts, :model_id) do
      {:ok, model_id} ->
        if valid_model_id?(model_id),
          do: http_get(hugging_face_url(model_id, file, opts), opts),
          else: {:error, {:invalid_model_id, model_id}}

      :error ->
        {:error, :download_source_not_configured}
    end
  end

  @spec configured_source(keyword(), :source_dir | :base_url) ::
          {:ok, binary()} | :missing | {:error, term()}
  defp configured_source(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, source} when is_binary(source) and source != "" -> {:ok, source}
      {:ok, _invalid} -> {:error, {:invalid_model_source, key}}
      :error -> :missing
    end
  end

  @spec http_get(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp http_get(url, opts) do
    with :ok <- validate_http_url(url),
         {:ok, headers} <- request_headers(Keyword.get(opts, :headers, [])),
         {:ok, timeout} <- request_timeout(Keyword.get(opts, :timeout, @default_timeout)) do
      :inets.start()
      :ssl.start()

      request = {to_charlist(url), headers}
      http_opts = [autoredirect: true, connect_timeout: timeout, timeout: timeout]
      options = [body_format: :binary]

      case :httpc.request(:get, request, http_opts, options) do
        {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
          {:ok, body}

        {:ok, {{_version, status, reason}, _headers, body}} ->
          {:error, {:download_failed, url, status, to_string(reason), body}}

        {:error, reason} ->
          {:error, {:download_failed, url, reason}}
      end
    end
  rescue
    exception -> {:error, {:download_failed, url, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:download_failed, url, {kind, reason}}}
  end

  @spec verify_checksum(binary(), binary(), keyword()) :: :ok | {:error, term()}
  defp verify_checksum(file, bytes, opts) do
    checksums = Keyword.get(opts, :checksums, %{})

    case expected_checksum(checksums, file) do
      nil ->
        :ok

      expected ->
        actual = sha256(bytes)

        if String.downcase(expected) == actual do
          :ok
        else
          {:error, {:checksum_mismatch, file, expected, actual}}
        end
    end
  end

  @spec expected_checksum(map(), binary()) :: binary() | nil
  defp expected_checksum(checksums, file) do
    Enum.find_value(checksums, fn
      {key, checksum} when is_atom(key) or is_binary(key) ->
        if to_string(key) == file, do: checksum

      _other ->
        nil
    end)
  end

  @spec checksums_ok?(Path.t(), keyword()) :: boolean()
  defp checksums_ok?(dir, opts) do
    checksums = Keyword.get(opts, :checksums, %{})

    Enum.all?(checksums, fn {file, expected} ->
      path = Path.join(dir, to_string(file))

      case File.read(path) do
        {:ok, bytes} -> String.downcase(expected) == sha256(bytes)
        {:error, _reason} -> false
      end
    end)
  end

  @spec write_atomic(Path.t(), binary()) :: :ok | {:error, term()}
  defp write_atomic(destination, bytes) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    tmp = destination <> ".download-" <> suffix

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.write(tmp, bytes, [:binary, :exclusive]),
         :ok <- File.rename(tmp, destination) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write_failed, destination, reason}}
    end
  end

  @spec hugging_face_url(binary(), binary(), keyword()) :: binary()
  defp hugging_face_url(model_id, file, opts) do
    revision = Keyword.get(opts, :revision, "main")

    "https://huggingface.co/#{encode_path(model_id)}/resolve/#{encode_path(revision)}/#{encode_path(file)}"
  end

  @spec join_url(binary(), binary()) :: binary()
  defp join_url(base_url, file) do
    String.trim_trailing(base_url, "/") <> "/" <> encode_path(file)
  end

  @spec sha256(binary()) :: binary()
  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end

  @spec safe_model_id(binary()) :: binary()
  defp safe_model_id(model_id) do
    sanitized =
      model_id
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "--")
      |> String.trim("-")

    if sanitized == "" do
      digest = model_id |> sha256() |> binary_part(0, 12)
      "model-#{digest}"
    else
      digest = model_id |> sha256() |> binary_part(0, 12)
      "#{sanitized}-#{digest}"
    end
  end

  @spec validate_checksums(keyword(), [binary()]) :: :ok | {:error, term()}
  defp validate_checksums(opts, files) do
    case Keyword.get(opts, :checksums, %{}) do
      checksums when is_map(checksums) ->
        validate_checksum_map(checksums, files)

      invalid ->
        {:error, {:invalid_model_checksums, invalid}}
    end
  end

  @spec validate_checksum_map(map(), [binary()]) :: :ok | {:error, term()}
  defp validate_checksum_map(checksums, files) do
    Enum.reduce_while(checksums, :ok, fn {file, checksum}, :ok ->
      case validate_checksum(file, checksum, files) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_checksum(term(), term(), [binary()]) :: :ok | {:error, term()}
  defp validate_checksum(file, checksum, files) do
    normalized_file = if is_atom(file) or is_binary(file), do: to_string(file)

    cond do
      not safe_relative_file?(normalized_file) ->
        {:error, {:invalid_model_checksum_file, file}}

      normalized_file not in files ->
        {:error, {:unexpected_model_checksum_file, file}}

      not is_binary(checksum) or not Regex.match?(@sha256_pattern, checksum) ->
        {:error, {:invalid_model_checksum, file}}

      true ->
        :ok
    end
  end

  @spec request_headers(term()) :: {:ok, [{charlist(), charlist()}]} | {:error, term()}
  defp request_headers(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, [{to_charlist(key), to_charlist(value)} | acc]}}

      invalid, _acc ->
        {:halt, {:error, {:invalid_download_header, invalid}}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp request_headers(invalid), do: {:error, {:invalid_download_headers, invalid}}

  @spec request_timeout(term()) :: {:ok, pos_integer()} | {:error, term()}
  defp request_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  defp request_timeout(timeout), do: {:error, {:invalid_download_timeout, timeout}}

  @spec validate_http_url(binary()) :: :ok | {:error, term()}
  defp validate_http_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _invalid ->
        {:error, {:invalid_download_url, url}}
    end
  end

  @spec valid_model_id?(term()) :: boolean()
  defp valid_model_id?(model_id) when is_binary(model_id) and model_id != "" do
    model_id
    |> String.split("/", trim: false)
    |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp valid_model_id?(_model_id), do: false

  @spec encode_path(binary()) :: binary()
  defp encode_path(path) do
    path
    |> String.split("/", trim: false)
    |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))
  end

  @spec default_cache_root :: Path.t()
  defp default_cache_root do
    base =
      System.get_env("XDG_CACHE_HOME") ||
        Path.join(System.user_home!(), ".cache")

    Path.join([base, "spectre_mnemonic", "models"])
  end
end
