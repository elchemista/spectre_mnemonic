defmodule SpectreMnemonic.Embedding.ModelDownloader do
  @moduledoc """
  Downloads and caches embedding model artifacts.

  Downloads are opt-in. A provider can pass `download: true` with a `model_id`
  and this module will ensure the required files exist in a cache directory.
  The default remote source is Hugging Face's `resolve/main` endpoint; tests and
  deployments can use `source_dir` or `base_url` for mirrors.
  """

  @required_files ["config.json", "tokenizer.json", "model.safetensors"]

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
    files = Keyword.get(opts, :files, @required_files)

    with {:ok, dir} <- target_dir(opts),
         :ok <- ensure_or_download(dir, files, opts) do
      {:ok, dir}
    end
  end

  @doc "Downloads every requested model file into the target cache directory."
  @spec download_model(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def download_model(opts) do
    files = Keyword.get(opts, :files, @required_files)

    with {:ok, dir} <- target_dir(opts),
         :ok <- File.mkdir_p(dir) do
      download_files(files, dir, opts)
    end
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
    cond do
      complete?(dir, files, opts) ->
        :ok

      Keyword.get(opts, :download, false) ->
        case download_model(opts) do
          {:ok, ^dir} -> :ok
          {:ok, _other_dir} -> :ok
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, {:missing_model_files, dir, missing_files(dir, files)}}
    end
  end

  @spec complete?(Path.t(), [binary()], keyword()) :: boolean()
  defp complete?(dir, files, opts) do
    missing_files(dir, files) == [] and checksums_ok?(dir, opts)
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

      is_binary(Keyword.get(opts, :model_id)) and Keyword.get(opts, :model_id) != "" ->
        {:ok, cache_dir(Keyword.fetch!(opts, :model_id), opts)}

      true ->
        {:error, :model_dir_not_configured}
    end
  end

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
    cond do
      source_dir = Keyword.get(opts, :source_dir) ->
        File.read(Path.join(source_dir, file))

      base_url = Keyword.get(opts, :base_url) ->
        http_get(join_url(base_url, file), opts)

      model_id = Keyword.get(opts, :model_id) ->
        http_get(hugging_face_url(model_id, file, opts), opts)

      true ->
        {:error, :download_source_not_configured}
    end
  end

  @spec http_get(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp http_get(url, opts) do
    :inets.start()
    :ssl.start()

    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    request = {to_charlist(url), headers}
    http_opts = [autoredirect: true]
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

  @spec verify_checksum(binary(), binary(), keyword()) :: :ok | {:error, term()}
  defp verify_checksum(file, bytes, opts) do
    checksums = Keyword.get(opts, :checksums, %{})

    case Map.get(checksums, file) || checksum_for_atom_key(checksums, file) do
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

  @spec checksum_for_atom_key(map(), binary()) :: binary() | nil
  defp checksum_for_atom_key(checksums, file) do
    Enum.find_value(checksums, fn
      {key, checksum} when is_atom(key) ->
        if Atom.to_string(key) == file, do: checksum

      _other ->
        nil
    end)
  end

  @spec checksums_ok?(Path.t(), keyword()) :: boolean()
  defp checksums_ok?(dir, opts) do
    checksums = Keyword.get(opts, :checksums, %{})

    Enum.all?(checksums, fn {file, expected} ->
      path = Path.join(dir, to_string(file))

      File.regular?(path) and String.downcase(expected) == path |> File.read!() |> sha256()
    end)
  end

  @spec write_atomic(Path.t(), binary()) :: :ok | {:error, term()}
  defp write_atomic(destination, bytes) do
    tmp = destination <> ".download"

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.write(tmp, bytes),
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
    "https://huggingface.co/#{model_id}/resolve/#{revision}/#{file}"
  end

  @spec join_url(binary(), binary()) :: binary()
  defp join_url(base_url, file) do
    String.trim_trailing(base_url, "/") <> "/" <> URI.encode(file)
  end

  @spec sha256(binary()) :: binary()
  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end

  @spec safe_model_id(binary()) :: binary()
  defp safe_model_id(model_id) do
    model_id
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "--")
    |> String.trim("-")
  end

  @spec default_cache_root :: Path.t()
  defp default_cache_root do
    base =
      System.get_env("XDG_CACHE_HOME") ||
        Path.join(System.user_home!(), ".cache")

    Path.join([base, "spectre_mnemonic", "models"])
  end
end
