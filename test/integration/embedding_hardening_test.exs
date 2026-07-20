defmodule SpectreMnemonic.Integration.EmbeddingHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Embedding.EmbeddingGemma
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

  test "vector normalization and hamming helpers reject malformed inputs safely" do
    assert Vector.normalize_to_f32_binary(nil) == nil
    assert Vector.normalize_to_f32_binary([]) == nil
    assert Vector.normalize_to_f32_binary(<<>>) == nil
    assert Vector.normalize_to_f32_binary(<<1, 2, 3>>) == nil
    assert Vector.normalize_to_f32_binary(:invalid) == nil

    assert Vector.hamming_distance(<<0>>, <<1, 2>>) == :infinity
    assert Vector.hamming_distance(:invalid, nil) == :infinity
    assert Vector.hamming_similarity(:invalid, nil) == 0.0
    assert Vector.hamming_similarity(<<>>, <<>>) == 0.0
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

    refute File.exists?(Path.join(root, "escape.bin"))
  end

  test "model ids that sanitize to empty still receive an isolated cache directory" do
    cache_root = Path.join(System.tmp_dir!(), "model-cache-hardening")
    path = ModelDownloader.cache_dir("///", cache_dir: cache_root)

    assert Path.dirname(path) == cache_root
    assert Path.basename(path) =~ ~r/^model-[0-9a-f]{12}$/
    assert Path.basename(ModelDownloader.cache_dir("fixture/default")) == "fixture--default"
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
