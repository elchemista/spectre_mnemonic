defmodule SpectreMnemonicTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Embedding.{BinaryQuantizer, Model2VecStatic, Vector}

  test "records a signal without an embedding adapter" do
    assert {:ok, %{signal: signal, moment: moment}} =
             SpectreMnemonic.signal("research found Elixir ETS details",
               stream: :research,
               task_id: "task-a"
             )

    assert signal.stream == :research
    assert moment.vector == nil
    assert "elixir" in moment.keywords
    assert {:ok, status} = SpectreMnemonic.status("task-a")
    assert status.stream == :research
  end

  test "recalls matching active moments and status" do
    {:ok, %{moment: research}} =
      SpectreMnemonic.signal("Website findings say ETS is fast for active focus",
        stream: :research,
        task_id: "task-a"
      )

    {:ok, %{moment: code}} =
      SpectreMnemonic.signal("Code insight: GenServer owns the write path",
        stream: :code_learning,
        task_id: "task-a"
      )

    assert {:ok, _assoc} = SpectreMnemonic.link(research.id, :supports, code.id)

    assert {:ok, packet} = SpectreMnemonic.recall("how is it going with ETS?")
    assert Enum.any?(packet.moments, &(&1.id == research.id))
    assert Enum.any?(packet.moments, &(&1.id == code.id))
    assert Enum.any?(packet.active_status, &(&1.task_id == "task-a"))
  end

  test "uses hamming fingerprints as the default when no vectors exist" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("append only segment frame replay recovery", stream: :research)

    assert moment.vector == nil
    assert is_integer(moment.fingerprint)

    assert {:ok, packet} = SpectreMnemonic.recall("segment frame replay")
    assert packet.cue.vector == nil
    assert is_integer(packet.cue.fingerprint)
    assert Enum.any?(packet.moments, &(&1.id == moment.id))
  end

  test "stores artifact refs and validates associations" do
    {:ok, artifact} = SpectreMnemonic.artifact("/tmp/report.pdf", content_type: "application/pdf")
    {:ok, %{moment: moment}} = SpectreMnemonic.signal("artifact is related", stream: :chat)

    assert {:ok, assoc} = SpectreMnemonic.link(moment.id, :mentions, artifact.id)
    assert assoc.target_id == artifact.id
    assert {:error, :unknown_memory_id} = SpectreMnemonic.link("missing", :mentions, artifact.id)
  end

  test "forgets selected active moments" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("temporary low value tool event", stream: :tool)

    assert {:ok, 1} = SpectreMnemonic.forget(moment.id)
    assert {:ok, packet} = SpectreMnemonic.recall("temporary tool event")
    refute Enum.any?(packet.moments, &(&1.id == moment.id))
  end

  test "embedding adapter vector list is accepted" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.VectorAdapter)

    assert {:ok, %{moment: moment}} = SpectreMnemonic.signal("vectorized text")
    assert is_binary(moment.vector)
    assert Vector.to_list(moment.vector) == [1.0, 0.0, 0.0]
    assert is_binary(moment.binary_signature)
    assert moment.embedding.metadata.dimensions == 3
  after
    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
  end

  test "embedding adapter failure does not break ingestion" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.FailingAdapter)

    assert {:ok, %{moment: moment}} = SpectreMnemonic.signal("still stored")
    assert moment.vector == nil
    assert moment.binary_signature == nil
    assert moment.embedding.error == :boom
  after
    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
  end

  test "vector helpers store f32 binaries and compare dense and binary distances" do
    vector = Vector.normalize_to_f32_binary([3.0, 4.0])

    assert is_binary(vector)
    assert Vector.dimensions(vector) == 2
    assert_in_delta Vector.cosine(vector, [0.6, 0.8]), 1.0, 0.0001

    left = BinaryQuantizer.quantize([1.0, -1.0, 1.0, -1.0], bits: 4)
    right = BinaryQuantizer.quantize([1.0, -1.0, -1.0, -1.0], bits: 4)

    assert Vector.hamming_distance(left, right) == 1
    assert_in_delta Vector.hamming_similarity(left, right, 4), 0.75, 0.0001
  end

  test "recall index brute-force fallback ranks indexed embeddings" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.TwoVectorAdapter)

    {:ok, %{moment: match}} = SpectreMnemonic.signal("vector apple memory")
    {:ok, %{moment: miss}} = SpectreMnemonic.signal("vector orange memory")

    embedding = SpectreMnemonic.Embedding.embed("apple query", [])
    cue = %{vector: embedding.vector, binary_signature: embedding.binary_signature}

    assert {:ok, [first | rest]} = SpectreMnemonic.Recall.Index.query(cue, overfetch: 2)
    assert first.id == match.id
    assert Enum.any?(rest, &(&1.id == miss.id))
  after
    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
  end

  test "model2vec static fixture returns normalized binary embedding" do
    model_dir =
      Path.join(System.tmp_dir!(), "spectre-model2vec-#{System.unique_integer([:positive])}")

    File.mkdir_p!(model_dir)
    write_model2vec_fixture(model_dir)

    assert {:ok, embedding} =
             Model2VecStatic.embed("apple query",
               model_dir: model_dir,
               model_id: "fixture/model",
               dimensions: 2,
               signature_bits: 8
             )

    assert is_binary(embedding.vector)
    assert Vector.dimensions(embedding.vector) == 2
    assert is_binary(embedding.binary_signature)
    assert embedding.metadata.model == "fixture/model"
  after
    if model_dir = Process.get(:model_dir), do: File.rm_rf!(model_dir)
  end

  test "search merges active recall and durable store results" do
    Application.put_env(:spectre_mnemonic, :persistent_memory,
      stores: [
        [
          id: :searchable,
          adapter: __MODULE__.SearchAdapter,
          role: :primary,
          duplicate: true,
          opts: [
            send_to: self(),
            search_results: [%{id: "durable_1", score: 0.9}]
          ]
        ]
      ]
    )

    {:ok, %{moment: moment}} = SpectreMnemonic.signal("database search active memory")

    assert {:ok, results} = SpectreMnemonic.search("database search")
    assert Enum.any?(results, &(&1.source == :active and &1.id == moment.id))
    assert Enum.any?(results, &(&1.source == :persistent and &1.id == "durable_1"))
  end

  test "consolidates active moments to disk records" do
    {:ok, %{moment: moment}} =
      SpectreMnemonic.signal("important task result", task_id: "task-consolidate", attention: 2.0)

    assert {:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: 2.0)
    assert Enum.any?(knowledge, &(&1.source_id == moment.id))
  end

  defmodule VectorAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    def embed(_input, _opts), do: {:ok, [1.0, 0.0, 0.0]}
  end

  defmodule FailingAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    def embed(_input, _opts), do: {:error, :boom}
  end

  defmodule TwoVectorAdapter do
    @behaviour SpectreMnemonic.Embedding.Adapter

    def embed(input, _opts) do
      text = if is_binary(input), do: input, else: inspect(input)

      if String.contains?(text, "apple") do
        {:ok, [1.0, 0.0]}
      else
        {:ok, [0.0, 1.0]}
      end
    end
  end

  defmodule SearchAdapter do
    @behaviour SpectreMnemonic.Store.Adapter

    @impl true
    def capabilities(_opts), do: [:append, :search]

    @impl true
    def put(record, opts) do
      send(Keyword.fetch!(opts, :send_to), {:search_adapter_put, record})
      :ok
    end

    @impl true
    def search(_cue, opts), do: {:ok, Keyword.get(opts, :search_results, [])}
  end

  defp write_model2vec_fixture(model_dir) do
    Process.put(:model_dir, model_dir)

    File.write!(
      Path.join(model_dir, "tokenizer.json"),
      Jason.encode!(%{"model" => %{"vocab" => %{"apple" => 0, "orange" => 1, "query" => 2}}})
    )

    tensor =
      [
        [1.0, 0.0],
        [0.0, 1.0],
        [1.0, 1.0]
      ]
      |> List.flatten()
      |> Enum.reduce(<<>>, fn value, acc -> <<acc::binary, value::little-float-32>> end)

    header =
      Jason.encode!(%{
        "embeddings" => %{
          "dtype" => "F32",
          "shape" => [3, 2],
          "data_offsets" => [0, byte_size(tensor)]
        }
      })

    File.write!(
      Path.join(model_dir, "model.safetensors"),
      <<byte_size(header)::little-unsigned-integer-64, header::binary, tensor::binary>>
    )
  end
end
