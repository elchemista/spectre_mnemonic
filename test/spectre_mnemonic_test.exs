defmodule SpectreMnemonicTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.{ActionRecipe, ActionRuntime}
  alias SpectreMnemonic.Embedding.{BinaryQuantizer, Model2VecStatic, ModelDownloader, Vector}
  alias SpectreMnemonic.Recall.Index

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

  test "vector helpers accept Nx tensors" do
    tensor = Nx.tensor([3.0, 4.0], type: :f32)

    vector = Vector.normalize_to_f32_binary(tensor)

    assert is_binary(vector)
    assert Vector.dimensions(tensor) == 2
    assert Vector.to_list(tensor) == [3.0, 4.0]
    assert_in_delta Vector.dot(tensor, [0.6, 0.8]), 5.0, 0.0001
    assert_in_delta Vector.cosine(vector, tensor), 1.0, 0.0001
  end

  test "recall index brute-force fallback ranks indexed embeddings" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.TwoVectorAdapter)

    {:ok, %{moment: match}} = SpectreMnemonic.signal("vector apple memory")
    {:ok, %{moment: miss}} = SpectreMnemonic.signal("vector orange memory")

    embedding = SpectreMnemonic.Embedding.embed("apple query", [])
    cue = %{vector: embedding.vector, binary_signature: embedding.binary_signature}

    assert {:ok, [first | rest]} = Index.query(cue, overfetch: 2)
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

  test "model downloader copies model artifacts into cache and reuses them" do
    source_dir = tmp_dir("spectre-model-source")
    cache_root = tmp_dir("spectre-model-cache")
    write_model2vec_fixture(source_dir)

    assert {:ok, model_dir} =
             ModelDownloader.ensure_model(
               model_id: "fixture/model",
               cache_dir: cache_root,
               source_dir: source_dir,
               download: true
             )

    assert model_dir == Path.join(cache_root, "fixture--model")

    for file <- ModelDownloader.required_files() do
      assert File.regular?(Path.join(model_dir, file))
    end

    File.rm_rf!(source_dir)

    assert {:ok, ^model_dir} =
             ModelDownloader.ensure_model(
               model_id: "fixture/model",
               cache_dir: cache_root,
               source_dir: source_dir,
               download: true
             )
  after
    cleanup_tmp_dirs()
  end

  test "model downloader rejects checksum mismatches before writing cache file" do
    source_dir = tmp_dir("spectre-bad-model-source")
    cache_root = tmp_dir("spectre-bad-model-cache")
    write_model2vec_fixture(source_dir)

    assert {:error, {:checksum_mismatch, "tokenizer.json", _expected, _actual}} =
             ModelDownloader.ensure_model(
               model_id: "fixture/bad-model",
               cache_dir: cache_root,
               source_dir: source_dir,
               download: true,
               checksums: %{"tokenizer.json" => String.duplicate("0", 64)}
             )

    refute File.exists?(Path.join([cache_root, "fixture--bad-model", "tokenizer.json"]))
  after
    cleanup_tmp_dirs()
  end

  test "model downloader fetches artifacts from an HTTP base url" do
    source_dir = tmp_dir("spectre-http-model-source")
    cache_root = tmp_dir("spectre-http-model-cache")
    write_model2vec_fixture(source_dir)
    base_url = start_fixture_http_server(source_dir, length(ModelDownloader.required_files()))

    assert {:ok, model_dir} =
             ModelDownloader.ensure_model(
               model_id: "fixture/http-model",
               cache_dir: cache_root,
               base_url: base_url,
               download: true
             )

    for file <- ModelDownloader.required_files() do
      assert File.regular?(Path.join(model_dir, file))
    end
  after
    cleanup_tmp_dirs()
  end

  test "model2vec static can download missing model artifacts before embedding" do
    source_dir = tmp_dir("spectre-download-source")
    cache_root = tmp_dir("spectre-download-cache")
    write_model2vec_fixture(source_dir)

    assert {:ok, embedding} =
             Model2VecStatic.embed("apple query",
               model_id: "fixture/downloaded",
               cache_dir: cache_root,
               source_dir: source_dir,
               download: true,
               dimensions: 2,
               signature_bits: 8
             )

    assert is_binary(embedding.vector)
    assert Vector.dimensions(embedding.vector) == 2
    assert File.regular?(Path.join([cache_root, "fixture--downloaded", "model.safetensors"]))
  after
    cleanup_tmp_dirs()
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

  test "stores action language recipe with a signal and recalls it as data" do
    recipe_text = "When recalled, refresh JSON from https://example.test/weather"

    assert {:ok, %{moment: moment, action_recipe: recipe}} =
             SpectreMnemonic.signal("cached weather json for Rome",
               action_recipe: recipe_text,
               action_intent: "refresh cached JSON",
               ttl_ms: 60_000,
               refresh_on_recall?: true,
               source_url: "https://example.test/weather",
               tags: [:weather]
             )

    assert %ActionRecipe{} = recipe
    assert recipe.memory_id == moment.id
    assert recipe.language == :spectre_al
    assert recipe.text == recipe_text
    assert recipe.intent == "refresh cached JSON"
    assert recipe.status == :stored
    assert recipe.metadata.ttl_ms == 60_000
    assert recipe.metadata.refresh_on_recall? == true
    assert recipe.metadata.source_url == "https://example.test/weather"
    assert recipe.metadata.tags == [:weather]

    assert {:ok, packet} = SpectreMnemonic.recall("weather Rome JSON")
    assert Enum.any?(packet.action_recipes, &(&1.id == recipe.id))
    refute_receive {:runtime_called, _operation, _recipe}
  end

  test "action language recipes survive persistent memory replay" do
    assert {:ok, %{action_recipe: recipe}} =
             SpectreMnemonic.signal("cached market json",
               action_recipe: %{
                 text: "Refresh the market JSON from the configured API",
                 intent: "refresh market data",
                 metadata: %{source_url: "https://example.test/markets"}
               }
             )

    assert {:ok, records} = SpectreMnemonic.PersistentMemory.replay()
    assert Enum.any?(records, &(&1.family == :action_recipes and &1.payload.id == recipe.id))
    assert Enum.any?(records, &(&1.family == :associations and &1.payload.target_id == recipe.id))
  end

  test "stores action language recipe with an artifact and recalls it through linked memory" do
    assert {:ok, %{artifact: artifact, action_recipe: recipe}} =
             SpectreMnemonic.artifact("/tmp/weather.json",
               action_recipe: "Refresh this artifact from the weather endpoint",
               action_recipe_metadata: %{decoder: :json}
             )

    assert {:ok, %{moment: moment}} = SpectreMnemonic.signal("weather artifact for Rome")
    assert {:ok, _association} = SpectreMnemonic.link(moment.id, :mentions, artifact.id)

    assert {:ok, packet} = SpectreMnemonic.recall("weather artifact Rome")
    assert Enum.any?(packet.artifacts, &(&1.id == artifact.id))
    assert Enum.any?(packet.action_recipes, &(&1.id == recipe.id))
    assert recipe.metadata.decoder == :json
  end

  test "action runtime is disabled by default and delegates only when explicitly configured" do
    recipe = %ActionRecipe{
      id: "act_test",
      memory_id: "mom_test",
      text: "Refresh JSON from the test endpoint"
    }

    assert {:error, :runtime_not_configured} = ActionRuntime.analyze(recipe)
    assert {:error, :runtime_not_configured} = ActionRuntime.run(recipe, %{})

    assert {:ok, %{safe?: true}} =
             ActionRuntime.analyze(recipe, adapter: __MODULE__.RuntimeAdapter, test_pid: self())

    assert_received {:runtime_called, :analyze, ^recipe}

    assert {:ok, %{refreshed?: true}} =
             ActionRuntime.run(recipe, %{memory: :context},
               adapter: __MODULE__.RuntimeAdapter,
               test_pid: self()
             )

    assert_received {:runtime_called, :run, ^recipe, %{memory: :context}}
  end

  test "normal memory operations do not invoke a configured action runtime" do
    Application.put_env(:spectre_mnemonic, :action_runtime_adapter, __MODULE__.RuntimeAdapter)

    assert {:ok, %{action_recipe: recipe}} =
             SpectreMnemonic.signal("cached calendar json",
               action_recipe: "Refresh the calendar JSON when Kinetic asks"
             )

    assert {:ok, packet} = SpectreMnemonic.recall("calendar json")
    assert Enum.any?(packet.action_recipes, &(&1.id == recipe.id))
    assert {:ok, _records} = SpectreMnemonic.PersistentMemory.replay()
    assert {:ok, _results} = SpectreMnemonic.search("calendar json")
  after
    Application.delete_env(:spectre_mnemonic, :action_runtime_adapter)
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

  defmodule RuntimeAdapter do
    @behaviour SpectreMnemonic.ActionRuntime.Adapter

    @impl true
    def analyze(recipe, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_called, :analyze, recipe})
      {:ok, %{safe?: true}}
    end

    @impl true
    def run(recipe, context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_called, :run, recipe, context})
      {:ok, %{refreshed?: true}}
    end
  end

  defp write_model2vec_fixture(model_dir) do
    Process.put(:model_dir, model_dir)

    File.write!(
      Path.join(model_dir, "config.json"),
      Jason.encode!(%{"model_type" => "model2vec", "dim" => 2})
    )

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

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    Process.put(:tmp_dirs, [path | Process.get(:tmp_dirs, [])])
    path
  end

  defp cleanup_tmp_dirs do
    Enum.each(Process.get(:tmp_dirs, []), &File.rm_rf!/1)
    Process.delete(:tmp_dirs)

    if model_dir = Process.get(:model_dir) do
      File.rm_rf!(model_dir)
      Process.delete(:model_dir)
    end
  end

  defp start_fixture_http_server(source_dir, request_count) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listen_socket)

    pid =
      spawn_link(fn ->
        for _ <- 1..request_count do
          {:ok, socket} = :gen_tcp.accept(listen_socket)
          {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
          file = request_file(request)
          body = File.read!(Path.join(source_dir, file))

          response = [
            "HTTP/1.1 200 OK\r\n",
            "content-length: #{byte_size(body)}\r\n",
            "connection: close\r\n",
            "\r\n",
            body
          ]

          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
        end

        :gen_tcp.close(listen_socket)
      end)

    Process.put(:tmp_pids, [pid | Process.get(:tmp_pids, [])])
    "http://127.0.0.1:#{port}"
  end

  defp request_file(request) do
    request
    |> String.split("\r\n", parts: 2)
    |> hd()
    |> String.split(" ")
    |> Enum.at(1)
    |> URI.decode()
    |> String.trim_leading("/")
  end
end
