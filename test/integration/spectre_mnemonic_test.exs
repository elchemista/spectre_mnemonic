defmodule SpectreMnemonic.IntegrationTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Actions.Runtime
  alias SpectreMnemonic.Intake.Packet
  alias SpectreMnemonic.Knowledge.Consolidation
  alias SpectreMnemonic.Memory.{ActionRecipe, Moment, Secret, Signal}
  alias SpectreMnemonic.Embedding.{BinaryQuantizer, Model2VecStatic, ModelDownloader, Vector}
  alias SpectreMnemonic.Recall.Index
  alias SpectreMnemonic.Secrets.Crypto.AESGCM

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

  test "remember ingests long text as categorized active graph memory" do
    text = """
    # Architecture
    The system design uses a parser module and adapter integration. The decision is to split
    documents into chunks so recall can digest a long report. This architecture note explains
    the concept and the model for active memory.

    # Tasks
    TODO: implement document chunking and verify graph relations. The next action should link
    every chunk to its section and category. The task also needs status events and tool commands
    for testing the ingestion path.

    # Risks
    A bug or failure in chunk overlap could create an error where information is missing.
    Research evidence should show that adjacent chunks stay connected and related chunks can be
    recalled together.
    """

    assert {:ok, packet} =
             SpectreMnemonic.remember(text,
               title: "Long Architecture Report",
               chunk_words: 24,
               overlap_words: 6
             )

    assert packet.root.kind == :task
    assert packet.persistence == %{mode: :active, durable?: false}
    assert length(packet.chunks) > 3
    assert length(packet.summaries) == length(packet.chunks) + 1
    assert Enum.any?(packet.categories, &(&1.metadata.category == :task))
    assert Enum.any?(packet.categories, &(&1.metadata.category == :error))

    relations = Enum.map(packet.associations, & &1.relation)
    assert :contains_chunk in relations
    assert :next_chunk in relations
    assert :previous_chunk in relations
    assert :has_summary in relations
    assert :categorized_as in relations

    assert {:ok, recalled} =
             SpectreMnemonic.recall("document chunking graph relations", limit: 30)

    assert Enum.any?(recalled.moments, &(&1.id == packet.root.id))
    assert Enum.any?(recalled.associations, &(&1.relation in [:contains_chunk, :categorized_as]))
  end

  test "remember accepts maps lists code and json-looking strings without parsing json" do
    assert {:ok, task_packet} =
             SpectreMnemonic.remember(%{
               type: :task,
               title: "Ship intake",
               content: "Implement the memory intake graph",
               metadata: %{source: "planner"}
             })

    assert task_packet.root.kind == :task
    assert task_packet.root.metadata.source == "planner"

    assert {:ok, list_packet} =
             SpectreMnemonic.remember([
               %{role: "user", content: "hello"},
               %{role: "assistant", content: "hi"}
             ])

    assert list_packet.root.kind == :structured_event

    code = "defmodule Demo do\n  def run(value), do: value + 1\nend"
    assert {:ok, code_packet} = SpectreMnemonic.remember(code)
    assert code_packet.root.kind == :code

    json = ~s({"kind":"task","content":"this should stay text"})
    assert {:ok, json_packet} = SpectreMnemonic.remember(json)
    assert json_packet.root.kind == :text
    assert json_packet.chunks |> hd() |> Map.fetch!(:text) == json
  end

  test "remember ignores direct secret options unless a plug routes the draft" do
    assert {:ok, packet} =
             SpectreMnemonic.remember("github_pat_super_secret",
               secret?: true,
               label: "github token",
               secret_key: secret_key()
             )

    assert %Moment{} = packet.root
    assert packet.root.text == "text: github_pat_super_secret"
    refute packet.root.metadata[:secret?]
    assert packet.persistence == %{mode: :active, durable?: false}
  end

  test "secret signal persists only encrypted and redacted memory" do
    plaintext = "github_pat_super_secret"

    assert {:ok, %{signal: signal, moment: secret}} =
             SpectreMnemonic.signal(plaintext,
               secret?: true,
               label: "github token",
               secret_key: secret_key()
             )

    assert %Secret{} = secret
    assert signal.input == "secret: github token"
    assert secret.text == "secret: github token"
    assert secret.input == "secret: github token"
    assert is_binary(secret.ciphertext)
    refute secret.ciphertext == plaintext

    assert {:ok, records} = SpectreMnemonic.Persistence.Manager.replay()
    rendered = inspect(records, limit: :infinity)
    refute String.contains?(rendered, plaintext)
    assert String.contains?(rendered, "secret: github token")
  end

  test "remember plugs compose global and per-call memory mutations" do
    Application.put_env(:spectre_mnemonic, :plugs, [__MODULE__.GlobalMemoryPlug])

    assert {:ok, packet} =
             SpectreMnemonic.remember("plain plug memory",
               plugs: [__MODULE__.PerCallMemoryPlug],
               test_pid: self()
             )

    assert packet.root.metadata.global_plug? == true
    assert packet.root.metadata.per_call_plug? == true
    assert packet.root.metadata.plug_order == [:global, :per_call]
    assert_received {:plug_called, :global, "plain plug memory"}
    assert_received {:plug_called, :per_call, [:global]}
  after
    Application.delete_env(:spectre_mnemonic, :plugs)
  end

  test "remember tuple plugs receive plug-specific options" do
    assert {:ok, packet} =
             SpectreMnemonic.remember("tuple plug memory",
               plugs: [{__MODULE__.TupleOptionPlug, route: :billing, confidence: 0.81}],
               test_pid: self()
             )

    assert packet.root.metadata.route == :billing
    assert packet.root.metadata.confidence == 0.81
    assert_received {:tuple_option_plug, :billing, 0.81}
  end

  test "remember plug can mutate draft text kind title tags and metadata" do
    assert {:ok, packet} =
             SpectreMnemonic.remember("plain incoming chat",
               plugs: [__MODULE__.MemoryMutatorPlug],
               chunk_words: 50
             )

    assert packet.root.kind == :task
    assert packet.root.text == "task: Ship the plug-generated task"
    assert packet.root.metadata.intent == :implementation
    assert packet.root.metadata.tags == [:plugged, :task]
    assert [chunk] = packet.chunks
    assert chunk.text == "TODO implement the plug-generated task"
    assert chunk.metadata.intent == :implementation
  end

  test "remember plug halt with memory stops later plugs and dispatches the draft" do
    assert {:ok, packet} =
             SpectreMnemonic.remember("halt this draft",
               plugs: [__MODULE__.HaltMemoryPlug, __MODULE__.ShouldNotRunPlug],
               test_pid: self()
             )

    assert packet.root.metadata.halted_by_plug? == true
    assert packet.warnings == [:halted_by_memory_plug]
    assert packet.root.text == "text: Halted by memory plug"
    refute_received {:should_not_run_plug, _text}
  end

  test "remember returns clear errors for unavailable or invalid plugs" do
    assert {:error, {:plug_not_available, __MODULE__.MissingPlug}} =
             SpectreMnemonic.remember("missing plug", plugs: [__MODULE__.MissingPlug])

    assert {:error, {:invalid_plug, "bad plug"}} =
             SpectreMnemonic.remember("invalid plug", plugs: ["bad plug"])
  end

  test "remember plugs route secrets with recent memory before encryption" do
    {:ok, %{moment: context}} =
      SpectreMnemonic.signal("Deploy Stripe payments to production",
        stream: :chat,
        task_id: "session-1"
      )

    context_id = context.id

    assert {:ok, packet} =
             SpectreMnemonic.remember("sk_live_super_secret",
               stream: :chat,
               task_id: "session-1",
               secret_key: secret_key(),
               plugs: [__MODULE__.StripeSecretRouterPlug],
               test_pid: self()
             )

    secret = packet.root
    assert %Secret{} = secret
    assert secret.text == "secret: Stripe production secret key"
    assert secret.label == "Stripe production secret key"
    assert secret.metadata.provider == :stripe
    assert secret.metadata.environment == :production
    assert secret.metadata.plug_confidence == 0.92

    assert_received {:secret_router_context, ["Deploy Stripe payments to production"],
                     ^context_id}
  end

  test "remember plug-routed secrets persist encrypted replay records without plaintext" do
    plaintext = "plug_routed_super_secret"

    assert {:ok, packet} =
             SpectreMnemonic.remember(plaintext,
               plugs: [__MODULE__.AlwaysSecretPlug],
               secret_key: secret_key(),
               metadata: %{provider: :github}
             )

    assert %Secret{} = secret = packet.root
    assert secret.text == "secret: GitHub automation token"
    assert secret.input == "secret: GitHub automation token"
    assert secret.metadata.provider == :github
    assert secret.metadata.secret? == true
    refute secret.ciphertext == plaintext

    assert {:ok, records} = SpectreMnemonic.Persistence.Manager.replay()
    rendered = inspect(records, limit: :infinity)

    refute String.contains?(rendered, plaintext)
    assert String.contains?(rendered, "secret: GitHub automation token")
    assert String.contains?(rendered, secret.id)
  end

  test "remember plugs can halt with packet moment secret or signal results" do
    assert {:ok, %Packet{warnings: [:halted_packet]}} =
             SpectreMnemonic.remember("halt packet", plugs: [__MODULE__.HaltPacketPlug])

    assert {:ok, %Packet{root: %Moment{id: "plug_moment"}}} =
             SpectreMnemonic.remember("halt moment", plugs: [__MODULE__.HaltMomentPlug])

    assert {:ok, %Packet{root: %Secret{id: "plug_secret"}}} =
             SpectreMnemonic.remember("halt secret", plugs: [__MODULE__.HaltSecretPlug])

    assert {:ok, %Packet{events: [%Signal{id: "plug_signal"}]}} =
             SpectreMnemonic.remember("halt signal", plugs: [__MODULE__.HaltSignalPlug])
  end

  test "recall leaves secret moments locked without authorization" do
    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal("github_pat_super_secret",
        secret?: true,
        label: "github token",
        secret_key: secret_key()
      )

    assert {:ok, packet} = SpectreMnemonic.recall("github token")
    recalled = Enum.find(packet.moments, &(&1.id == secret.id))

    assert %Secret{} = recalled
    assert recalled.locked? == true
    assert recalled.revealed? == false
    assert recalled.text == "secret: github token"
    assert recalled.authorization.status == :required
    assert recalled.authorization.reason == :authorization_not_configured
    assert recalled.authorization.request.operation == :recall
    assert recalled.authorization.request.label == "github token"
    assert recalled.reveal == %{module: SpectreMnemonic, function: :reveal, arity: 2}
  end

  test "recall reveals secret moments after authorization succeeds" do
    plaintext = "github_pat_super_secret"

    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal(plaintext,
        secret?: true,
        label: "github token",
        secret_key: secret_key()
      )

    assert {:ok, packet} =
             SpectreMnemonic.recall("github token",
               secret_key: secret_key(),
               authorization_adapter: __MODULE__.ApprovingSecretAuth,
               authorization_context: %{user_id: "user-1"},
               test_pid: self()
             )

    recalled = Enum.find(packet.moments, &(&1.id == secret.id))
    assert %Secret{} = recalled
    assert recalled.locked? == false
    assert recalled.revealed? == true
    assert recalled.text == plaintext
    assert recalled.input == plaintext
    assert recalled.authorization.status == :authorized
    assert recalled.authorization.grant == %{authorized?: true}
    assert recalled.authorization.request.label == "github token"

    assert_received {:secret_authorize,
                     %{
                       operation: :recall,
                       secret_id: secret_id,
                       memory_id: memory_id,
                       label: "github token",
                       authorization_context: %{user_id: "user-1"}
                     }}

    assert secret_id == secret.secret_id
    assert memory_id == secret.id
  end

  test "recall keeps secret locked when authorization denies" do
    plaintext = "github_pat_super_secret"

    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal(plaintext,
        secret?: true,
        label: "github token",
        secret_key: secret_key()
      )

    assert {:ok, packet} =
             SpectreMnemonic.recall("github token",
               secret_key: secret_key(),
               authorization_adapter: __MODULE__.DenyingSecretAuth
             )

    recalled = Enum.find(packet.moments, &(&1.id == secret.id))
    assert %Secret{} = recalled
    assert recalled.locked? == true
    assert recalled.revealed? == false
    assert recalled.text == "secret: github token"
    refute recalled.text == plaintext
    assert recalled.authorization.status == :denied
    assert recalled.authorization.reason == :denied
  end

  test "recall uses configured authorization adapter when options omit one" do
    Application.put_env(
      :spectre_mnemonic,
      :secret_authorization_adapter,
      __MODULE__.ApprovingSecretAuth
    )

    plaintext = "configured_auth_secret"

    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal(plaintext,
        secret?: true,
        label: "configured token",
        secret_key: secret_key()
      )

    assert {:ok, packet} =
             SpectreMnemonic.recall("configured token",
               secret_key: secret_key(),
               test_pid: self()
             )

    recalled = Enum.find(packet.moments, &(&1.id == secret.id))
    assert %Secret{locked?: false, revealed?: true} = recalled
    assert recalled.text == plaintext
    assert recalled.authorization.status == :authorized
    assert_received {:secret_authorize, %{label: "configured token"}}
  after
    Application.delete_env(:spectre_mnemonic, :secret_authorization_adapter)
  end

  test "agents can reveal a locked recalled secret after asking for authorization" do
    plaintext = "github_pat_super_secret"

    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal(plaintext,
        secret?: true,
        label: "github token",
        secret_key: secret_key()
      )

    assert {:ok, packet} = SpectreMnemonic.recall("github token")
    locked = Enum.find(packet.moments, &(&1.id == secret.id))

    assert %Secret{locked?: true} = locked
    assert locked.reveal == %{module: SpectreMnemonic, function: :reveal, arity: 2}

    assert {:ok, revealed} =
             SpectreMnemonic.reveal(locked,
               secret_key: secret_key(),
               authorization_adapter: __MODULE__.ApprovingSecretAuth,
               authorization_context: %{user_id: "user-1"},
               test_pid: self()
             )

    assert revealed.id == locked.id
    assert revealed.locked? == false
    assert revealed.revealed? == true
    assert revealed.text == plaintext
    assert revealed.authorization.status == :authorized
    assert_received {:secret_authorize, %{memory_id: memory_id, label: "github token"}}
    assert memory_id == locked.id
  end

  test "reveal supports configured secret key functions" do
    plaintext = "key_fun_secret"

    key_fun = fn
      %{label: "key fun token"} -> secret_key()
      _context -> wrong_secret_key()
    end

    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal(plaintext,
        secret?: true,
        label: "key fun token",
        secret_key_fun: key_fun
      )

    assert {:ok, revealed} =
             SpectreMnemonic.reveal(secret,
               secret_key_fun: key_fun,
               authorization_adapter: __MODULE__.ApprovingSecretAuth,
               test_pid: self()
             )

    assert revealed.text == plaintext
    assert revealed.authorization.status == :authorized
    assert_received {:secret_authorize, %{label: "key fun token"}}
  end

  test "reveal returns already revealed secrets without requiring authorization again" do
    plaintext = "already_revealed_secret"

    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal(plaintext,
        secret?: true,
        label: "already revealed token",
        secret_key: secret_key()
      )

    assert {:ok, revealed} =
             SpectreMnemonic.reveal(secret,
               secret_key: secret_key(),
               authorization_adapter: __MODULE__.ApprovingSecretAuth,
               test_pid: self()
             )

    assert_receive {:secret_authorize, %{label: "already revealed token"}}

    assert {:ok, same_secret} = SpectreMnemonic.reveal(revealed, test_pid: self())
    assert same_secret == revealed
    refute_received {:secret_authorize, _request}
  end

  test "AES-GCM adapter rejects missing invalid and wrong keys cleanly" do
    context = %{secret_id: "sec_test", memory_id: "mom_test", label: "api key"}

    assert {:error, :secret_key_not_configured} = AESGCM.encrypt("secret", context, [])

    assert {:error, {:invalid_secret_key, expected_bytes: 32}} =
             AESGCM.encrypt("secret", context, secret_key: "short")

    assert {:ok, encrypted} = AESGCM.encrypt("secret", context, secret_key: secret_key())

    secret =
      struct!(
        Secret,
        Map.merge(encrypted, %{
          id: "mom_test",
          signal_id: "sig_test",
          secret_id: "sec_test",
          label: "api key",
          text: "secret: api key",
          input: "secret: api key"
        })
      )

    assert {:error, :invalid_secret_ciphertext} =
             AESGCM.decrypt(secret, context, secret_key: wrong_secret_key())
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

    embedding = SpectreMnemonic.Embedding.Service.embed("apple query", [])
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

  test "consolidation persists remember summaries categories associations and embeddings" do
    Application.put_env(:spectre_mnemonic, :embedding_adapter, __MODULE__.VectorAdapter)

    {:ok, packet} =
      SpectreMnemonic.remember("TODO implement durable graph summary adapter relation",
        chunk_words: 6,
        overlap_words: 0
      )

    assert {:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: 1.0)
    assert Enum.any?(knowledge, &(&1.source_id == packet.root.id))

    assert {:ok, records} = SpectreMnemonic.Persistence.Manager.replay()
    assert Enum.any?(records, &(&1.family == :summaries))
    assert Enum.any?(records, &(&1.family == :categories))

    assert Enum.any?(
             records,
             &(&1.family == :associations and &1.payload.relation == :contains_chunk)
           )

    assert Enum.any?(records, &(&1.family == :embeddings))
  after
    Application.delete_env(:spectre_mnemonic, :embedding_adapter)
  end

  test "consolidation can use runtime function and configured adapter" do
    {:ok, packet} = SpectreMnemonic.remember("runtime consolidation should keep this memory")

    runtime_fun = fn context ->
      assert %Consolidation{} = context

      knowledge =
        context.moments
        |> Enum.filter(&(&1.id == packet.root.id))
        |> Enum.map(fn moment ->
          %SpectreMnemonic.Knowledge.Record{
            id: "runtime_#{moment.id}",
            source_id: moment.id,
            text: "runtime #{moment.text}",
            metadata: %{strategy: :runtime},
            inserted_at: context.now
          }
        end)

      {:ok, %{knowledge: knowledge, moments: context.moments, strategy: :runtime_fun}}
    end

    assert {:ok, runtime_knowledge} = SpectreMnemonic.consolidate(consolidate_with: runtime_fun)
    assert Enum.any?(runtime_knowledge, &(&1.metadata.strategy == :runtime))

    Application.put_env(
      :spectre_mnemonic,
      :consolidation_adapter,
      __MODULE__.ConsolidationAdapter
    )

    assert {:ok, adapter_knowledge} = SpectreMnemonic.consolidate(test_pid: self())
    assert Enum.any?(adapter_knowledge, &(&1.metadata.strategy == :adapter))

    assert_received {:consolidator_called, count, window_count}
                    when count > 0 and window_count > 0
  after
    Application.delete_env(:spectre_mnemonic, :consolidation_adapter)
  end

  test "consolidation adapter receives graph windows and can return a struct plan" do
    {:ok, %{moment: left}} =
      SpectreMnemonic.signal("connected graph window left memory",
        task_id: "window-a",
        attention: 2.0
      )

    {:ok, %{moment: right}} =
      SpectreMnemonic.signal("connected graph window right memory",
        task_id: "window-a",
        attention: 2.0
      )

    {:ok, %{moment: solo}} =
      SpectreMnemonic.signal("standalone graph window memory",
        task_id: "window-b",
        attention: 2.0
      )

    assert {:ok, link} = SpectreMnemonic.link(left.id, :supports, right.id)

    test_pid = self()

    runtime_fun = fn %Consolidation{} = consolidation ->
      send(test_pid, {:consolidation_windows, consolidation.windows})

      knowledge =
        Enum.map(consolidation.windows, fn window ->
          %SpectreMnemonic.Knowledge.Record{
            id: "window_knowledge_#{window.id}",
            source_id: hd(window.moment_ids),
            text: "window #{window.id} #{Enum.join(window.moment_ids, ",")}",
            metadata: %{window_id: window.id},
            inserted_at: consolidation.now
          }
        end)

      {:ok,
       %{
         consolidation
         | knowledge: knowledge,
           records: [{:custom_consolidation, %{id: "custom_record", window_count: 2}}],
           tombstones: [%{family: :moments, id: solo.id, reason: :compressed}],
           strategy: :struct_chain,
           metadata: %{chain: :test},
           warnings: [:window_compressed]
       }}
    end

    assert {:ok, knowledge} =
             SpectreMnemonic.consolidate(min_attention: 2.0, consolidate_with: runtime_fun)

    assert length(knowledge) == 2

    assert_received {:consolidation_windows, windows}

    connected =
      Enum.find(windows, fn window ->
        MapSet.equal?(MapSet.new(window.moment_ids), MapSet.new([left.id, right.id]))
      end)

    singleton = Enum.find(windows, &(&1.moment_ids == [solo.id]))

    assert connected.association_ids == [link.id]
    assert connected.task_ids == ["window-a"]
    assert singleton.task_ids == ["window-b"]

    assert {:ok, records} = SpectreMnemonic.Persistence.Manager.replay()
    assert Enum.any?(records, &(&1.family == :custom_consolidation))
    assert Enum.any?(records, &(&1.family == :tombstones and &1.payload.id == solo.id))

    job =
      Enum.find(
        records,
        &(&1.family == :consolidation_jobs and &1.payload.strategy == :struct_chain)
      )

    assert job.payload.windows == 2
    assert job.payload.tombstones == 1
    assert job.payload.metadata == %{chain: :test}
    assert job.payload.warnings == [:window_compressed]
  end

  test "consolidation keeps secret plaintext out of durable records" do
    plaintext = "consolidation_secret_plaintext"

    {:ok, %{moment: secret}} =
      SpectreMnemonic.signal(plaintext,
        secret?: true,
        label: "consolidation token",
        secret_key: secret_key(),
        attention: 2.0
      )

    assert %Secret{} = secret
    assert {:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: 2.0)
    assert Enum.any?(knowledge, &(&1.source_id == secret.id))
    assert Enum.all?(knowledge, &(not String.contains?(&1.text, plaintext)))

    assert {:ok, records} = SpectreMnemonic.Persistence.Manager.replay()
    rendered = inspect(records, limit: :infinity)
    refute String.contains?(rendered, plaintext)
    assert String.contains?(rendered, "secret: consolidation token")
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

    assert {:ok, records} = SpectreMnemonic.Persistence.Manager.replay()
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

    assert {:error, :runtime_not_configured} = Runtime.analyze(recipe)
    assert {:error, :runtime_not_configured} = Runtime.run(recipe, %{})

    assert {:ok, %{safe?: true}} =
             Runtime.analyze(recipe, adapter: __MODULE__.RuntimeAdapter, test_pid: self())

    assert_received {:runtime_called, :analyze, ^recipe}

    assert {:ok, %{refreshed?: true}} =
             Runtime.run(recipe, %{memory: :context},
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
    assert {:ok, _records} = SpectreMnemonic.Persistence.Manager.replay()
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
    @behaviour SpectreMnemonic.Persistence.Store.Adapter

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

  defmodule ConsolidationAdapter do
    @behaviour SpectreMnemonic.Knowledge.Consolidator.Adapter

    @impl true
    def consolidate(context, opts) do
      %Consolidation{} = context

      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:consolidator_called, length(context.moments), length(context.windows)})
      end

      knowledge =
        Enum.map(context.moments, fn moment ->
          %SpectreMnemonic.Knowledge.Record{
            id: "adapter_#{moment.id}",
            source_id: moment.id,
            text: "adapter #{moment.text}",
            metadata: %{strategy: :adapter},
            inserted_at: context.now
          }
        end)

      {:ok, %{knowledge: knowledge, moments: context.moments, strategy: :adapter}}
    end
  end

  defmodule RuntimeAdapter do
    @behaviour SpectreMnemonic.Actions.Runtime.Adapter

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

  defmodule ApprovingSecretAuth do
    @behaviour SpectreMnemonic.Secrets.Authorization.Adapter

    @impl true
    def authorize(request, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:secret_authorize, request})
      end

      {:ok, %{authorized?: true}}
    end
  end

  defmodule DenyingSecretAuth do
    @behaviour SpectreMnemonic.Secrets.Authorization.Adapter

    @impl true
    def authorize(_request, _opts), do: {:error, :denied}
  end

  defmodule GlobalMemoryPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:plug_called, :global, memory.text})
      end

      metadata =
        memory.metadata
        |> Map.put(:global_plug?, true)
        |> Map.put(:plug_order, [:global])

      %{memory | metadata: metadata}
    end
  end

  defmodule PerCallMemoryPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, opts) do
      order = Map.get(memory.metadata, :plug_order, [])

      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:plug_called, :per_call, order})
      end

      metadata =
        memory.metadata
        |> Map.put(:per_call_plug?, true)
        |> Map.put(:plug_order, order ++ [:per_call])

      %{memory | metadata: metadata}
    end
  end

  defmodule TupleOptionPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, opts) do
      route = Keyword.fetch!(opts, :route)
      confidence = Keyword.fetch!(opts, :confidence)

      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:tuple_option_plug, route, confidence})
      end

      metadata =
        memory.metadata
        |> Map.put(:route, route)
        |> Map.put(:confidence, confidence)

      %{memory | metadata: metadata}
    end
  end

  defmodule MemoryMutatorPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, _opts) do
      metadata = Map.put(memory.metadata, :intent, :implementation)

      %{
        memory
        | text: "TODO implement the plug-generated task",
          kind: :task,
          title: "Ship the plug-generated task",
          tags: [:plugged, :task],
          metadata: metadata
      }
    end
  end

  defmodule HaltMemoryPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, _opts) do
      metadata = Map.put(memory.metadata, :halted_by_plug?, true)

      {:halt,
       %{
         memory
         | title: "Halted by memory plug",
           metadata: metadata,
           warnings: [:halted_by_memory_plug | memory.warnings]
       }}
    end
  end

  defmodule ShouldNotRunPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:should_not_run_plug, memory.text})
      end

      %{memory | metadata: Map.put(memory.metadata, :should_not_run?, true)}
    end
  end

  defmodule StripeSecretRouterPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, opts) do
      recent_text = Enum.map(memory.recent_moments, & &1.text)
      stripe_context = Enum.find(memory.recent_moments, &String.contains?(&1.text, "Stripe"))

      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:secret_router_context, recent_text, stripe_context.id})
      end

      if String.starts_with?(memory.text, "sk_live_") and stripe_context do
        metadata =
          memory.metadata
          |> Map.put(:provider, :stripe)
          |> Map.put(:environment, :production)
          |> Map.put(:plug_confidence, 0.92)

        %{
          memory
          | secret?: true,
            label: "Stripe production secret key",
            metadata: metadata
        }
      else
        memory
      end
    end
  end

  defmodule AlwaysSecretPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(memory, _opts) do
      metadata = Map.put(memory.metadata, :source, :always_secret_plug)

      %{
        memory
        | secret?: true,
          label: "GitHub automation token",
          metadata: metadata
      }
    end
  end

  defmodule HaltPacketPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(_memory, _opts), do: {:ok, %Packet{warnings: [:halted_packet]}}
  end

  defmodule HaltMomentPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(_memory, _opts), do: %Moment{id: "plug_moment", text: "plug moment"}
  end

  defmodule HaltSecretPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(_memory, _opts), do: %Secret{id: "plug_secret", text: "secret: plug"}
  end

  defmodule HaltSignalPlug do
    @behaviour SpectreMnemonic.Intake.Plug

    @impl true
    def call(_memory, _opts), do: %Signal{id: "plug_signal", input: "plug signal"}
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

  defp secret_key, do: <<1::256>>
  defp wrong_secret_key, do: <<2::256>>
end
