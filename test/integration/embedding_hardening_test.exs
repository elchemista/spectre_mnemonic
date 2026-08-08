defmodule SpectreMnemonic.Integration.EmbeddingHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Embedding.EmbeddingGemma
  alias SpectreMnemonic.Embedding.Model2VecStatic
  alias SpectreMnemonic.Embedding.ModelDownloader
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Embedding.Vector

  test "embedding service contains legacy adapter exceptions and throws" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.RaisingAdapter)
    raising = Service.embed("safe ingestion", [])
    assert raising.vector == nil
    assert %RuntimeError{} = raising.error

    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.ThrowingAdapter)
    throwing = Service.embed("safe ingestion", [])
    assert throwing.vector == nil
    assert throwing.error == {:throw, :adapter_failure}

    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.UnexpectedAdapter)
    unexpected = Service.embed("safe ingestion", [])
    assert unexpected.vector == nil
    assert %CaseClauseError{} = unexpected.error

    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.MissingAdapter)
    assert Service.embed("safe ingestion", []).error == :adapter_not_available
  end

  test "fast embedding providers always degrade to a structured fallback" do
    Application.put_env(:spectre_mnemonic, :embedding,
      fast: [enabled: true, provider: __MODULE__.FastProvider]
    )

    assert %{vector: nil, error: nil} =
             Service.embed("missing model", provider_mode: :model_not_configured)

    assert %{vector: nil, error: :provider_error} =
             Service.embed("provider error", provider_mode: :error)

    assert %{vector: nil, error: {:unexpected_provider_result, :unexpected}} =
             Service.embed("unexpected", provider_mode: :unexpected)

    assert %{vector: nil, error: %RuntimeError{}} =
             Service.embed("raising", provider_mode: :raise)

    assert %{vector: nil, error: {:throw, :fast_provider_failure}} =
             Service.embed("throwing", provider_mode: :throw)

    assert %{vector: vector, binary_signature: signature, metadata: metadata} =
             Service.embed("vector", provider_mode: :vector)

    assert is_binary(vector)
    assert is_binary(signature)
    assert metadata.dimensions == 2

    assert %{vector: direct_vector, metadata: %{provider_name: "fixture"}} =
             Service.embed("direct map", provider_mode: :direct_map)

    assert is_binary(direct_vector)
  end

  test "invalid fast provider modules do not break embedding" do
    Application.put_env(:spectre_mnemonic, :embedding,
      fast: [enabled: true, provider: __MODULE__.MissingProvider]
    )

    assert Service.embed("missing provider", []).error == :provider_not_available
  end

  test "malformed embedding configuration remains a structured fallback" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, "not-a-module")
    assert Service.embed("invalid adapter", []).error == :adapter_not_available

    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
    Application.put_env(:spectre_mnemonic, :embedding, %{fast: :invalid})
    assert %{vector: nil, error: nil} = Service.embed("invalid fast config", [])

    Application.put_env(:spectre_mnemonic, :embedding,
      fast: [enabled: true, provider: "not-a-module"]
    )

    assert Service.embed("invalid provider", []).error == :provider_not_available

    assert %{vector: nil, error: %FunctionClauseError{}} =
             Service.embed("invalid options", :invalid)
  end

  test "vector normalization and hamming helpers reject malformed inputs safely" do
    assert Vector.normalize_to_f32_binary(nil) == nil
    assert Vector.normalize_to_f32_binary([]) == nil
    assert Vector.normalize_to_f32_binary(<<>>) == nil
    assert Vector.normalize_to_f32_binary(<<1, 2, 3>>) == nil
    assert Vector.normalize_to_f32_binary(:invalid) == nil
    assert Vector.normalize_to_f32_binary([:invalid]) == nil
    assert Vector.to_f32_binary(<<1, 2, 3>>) == nil
    assert Vector.to_f32_binary([:invalid]) == nil
    assert Vector.to_f32_binary([1.0]) == <<1.0::little-float-32>>
    assert Vector.to_f32_binary(<<1.0::little-float-32>>) == <<1.0::little-float-32>>
    assert Vector.to_list([:invalid]) == []
    assert Vector.to_list(nil) == []
    assert Vector.to_list(<<>>) == []
    assert Vector.dimensions([:invalid]) == 0
    assert Vector.normalize([:invalid]) == []
    assert Vector.dot([:invalid], [1.0]) == 0.0
    assert Vector.dot(:invalid, [1.0]) == 0.0
    assert Vector.cosine([:invalid], [1.0]) == 0.0
    assert Vector.to_tensor(:invalid) == {:error, :invalid_vector}

    assert Vector.hamming_distance(<<0>>, <<1, 2>>) == :infinity
    assert Vector.hamming_distance(:invalid, nil) == :infinity
    assert Vector.hamming_similarity(:invalid, nil) == 0.0
    assert Vector.hamming_similarity(<<>>, <<>>) == 0.0
    assert Vector.hamming_similarity(<<0>>, <<0>>, :invalid) == 0.0
    assert Vector.popcount(0) == 0
    assert Vector.popcount(255) == 8
    assert Vector.cosine(<<1>>, <<1>>) == 0.0
  end

  test "deep embedding placeholder stays explicitly disabled" do
    assert {:error, :deep_embedding_disabled} = EmbeddingGemma.embed("text", [])
  end

  test "model downloads reject path traversal and invalid file lists" do
    root =
      Path.join(System.tmp_dir!(), "model-path-hardening-#{System.unique_integer([:positive])}")

    source = Path.join(root, "source")
    target = Path.join(root, "target")
    File.mkdir_p!(source)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:invalid_model_file, "../escape.bin"}} =
             ModelDownloader.download_model(
               model_dir: target,
               source_dir: source,
               files: ["../escape.bin"]
             )

    assert {:error, :model_files_required} =
             ModelDownloader.ensure_model(model_dir: target, files: [])

    assert {:error, :model_files_required} =
             ModelDownloader.ensure_model(model_dir: target, files: :invalid)

    assert {:error, {:invalid_model_id, "../escape"}} =
             ModelDownloader.ensure_model(model_id: "../escape")

    refute File.exists?(Path.join(root, "escape.bin"))
  end

  test "model downloads validate checksum, source, header, and timeout options" do
    root = Path.join(System.tmp_dir!(), "model-options-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:invalid_model_checksums, :invalid}} =
             ModelDownloader.download_model(model_dir: root, checksums: :invalid)

    assert {:error, {:invalid_model_checksum_file, "../outside"}} =
             ModelDownloader.download_model(
               model_dir: root,
               checksums: %{"../outside" => String.duplicate("0", 64)}
             )

    assert {:error, {:invalid_model_checksum, "config.json"}} =
             ModelDownloader.download_model(
               model_dir: root,
               checksums: %{"config.json" => "short"}
             )

    assert {:error, {:unexpected_model_checksum_file, "unused.bin"}} =
             ModelDownloader.download_model(
               model_dir: root,
               checksums: %{"unused.bin" => String.duplicate("0", 64)}
             )

    assert {:error, {:invalid_model_source, :source_dir}} =
             ModelDownloader.download_model(
               model_dir: root,
               files: ["config.json"],
               source_dir: :invalid
             )

    assert {:error, {:invalid_download_headers, :invalid}} =
             ModelDownloader.download_model(
               model_dir: root,
               files: ["config.json"],
               base_url: "http://127.0.0.1",
               headers: :invalid
             )

    assert {:error, {:invalid_download_timeout, 0}} =
             ModelDownloader.download_model(
               model_dir: root,
               files: ["config.json"],
               base_url: "http://127.0.0.1",
               timeout: 0
             )

    assert {:error, {:invalid_download_header, :invalid}} =
             ModelDownloader.download_model(
               model_dir: root,
               files: ["config.json"],
               base_url: "http://127.0.0.1",
               headers: [:invalid]
             )

    assert {:error, {:invalid_download_url, "not-a-url/config.json"}} =
             ModelDownloader.download_model(
               model_dir: root,
               files: ["config.json"],
               base_url: "not-a-url"
             )

    assert {:error, :download_source_not_configured} =
             ModelDownloader.download_model(model_dir: root, files: ["config.json"])

    assert {:error, {:invalid_model_options, _message}} =
             ModelDownloader.ensure_model(:invalid)

    assert {:error, {:invalid_model_options, _message}} =
             ModelDownloader.download_model(:invalid)
  end

  test "malformed safetensors offsets return an error instead of raising" do
    root = Path.join(System.tmp_dir!(), "model-corrupt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "config.json"), Jason.encode!(%{}))

    File.write!(
      Path.join(root, "tokenizer.json"),
      Jason.encode!(%{"model" => %{"vocab" => %{"query" => 0}}})
    )

    header =
      Jason.encode!(%{
        "embeddings" => %{
          "dtype" => "F32",
          "shape" => [2, 2],
          "data_offsets" => [0, 16]
        }
      })

    File.write!(
      Path.join(root, "model.safetensors"),
      <<byte_size(header)::little-unsigned-integer-64, header::binary, 0::32>>
    )

    assert {:error, :invalid_safetensors_file} =
             Model2VecStatic.embed("query", model_dir: root)
  end

  test "model ids that sanitize to empty still receive an isolated cache directory" do
    cache_root = Path.join(System.tmp_dir!(), "model-cache-hardening")
    path = ModelDownloader.cache_dir("///", cache_dir: cache_root)

    assert Path.dirname(path) == cache_root
    assert Path.basename(path) =~ ~r/^model-[0-9a-f]{12}$/

    assert Path.basename(ModelDownloader.cache_dir("fixture/default")) =~
             ~r/^fixture--default-[0-9a-f]{12}$/

    refute ModelDownloader.cache_dir("fixture/default", cache_dir: cache_root) ==
             ModelDownloader.cache_dir("fixture--default", cache_dir: cache_root)
  end

  defmodule RaisingAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    @impl SpectreMnemonic.Embedding.Adapter
    def embed(_input, _opts), do: raise("adapter failure")
  end

  defmodule ThrowingAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    @impl SpectreMnemonic.Embedding.Adapter
    def embed(_input, _opts), do: throw(:adapter_failure)
  end

  defmodule UnexpectedAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    @impl SpectreMnemonic.Embedding.Adapter
    def embed(_input, _opts), do: :unexpected
  end

  defmodule MissingAdapter do
  end

  defmodule FastProvider do
    def embed(_input, opts) do
      case Keyword.fetch!(opts, :provider_mode) do
        :model_not_configured -> {:error, :model_dir_not_configured}
        :error -> {:error, :provider_error}
        :unexpected -> :unexpected
        :raise -> raise("fast provider failure")
        :throw -> throw(:fast_provider_failure)
        :vector -> {:ok, [1.0, 0.0]}
        :direct_map -> %{"vector" => [0.0, 1.0], "metadata" => %{provider_name: "fixture"}}
      end
    end
  end

  defmodule MissingProvider do
  end
end
