Code.require_file("models.ex", __DIR__)

alias ParallelMemoryExample.Parser
alias SpectreMnemonic.Embedding.Vector
alias SpectreMnemonic.Knowledge.Base
alias SpectreMnemonic.Persistence.Manager
alias SpectreMnemonic.Persistence.Store.File, as: StoreFile

log = fn step, message ->
  time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  IO.puts("[#{time}] #{String.pad_trailing(step, 12)} #{message}")
end

preview = fn text ->
  if String.length(text) > 110 do
    String.slice(text, 0, 107) <> "..."
  else
    text
  end
end

write_tiny_model = fn model_dir ->
  File.mkdir_p!(model_dir)

  vocab_words =
    ~w(
      active adapter alerts apis append application artifact assistant chat compact config database
      decisions demo durable embedding error ets event events example file focus hot ingestion
      code examples library local memory metadata model moments parallel parser planning public query
      recall records replay research root save search signal signatures snapshots spectremnemonic storage
      store streams task tasks test tokenizer tool untouched user vectors working
    )

  vocab =
    vocab_words
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new()

  category_vector = fn word ->
    cond do
      word in ~w(parallel ingestion task tasks planning status) ->
        [1.0, 0.2, 0.0, 0.0]

      word in ~w(durable replay storage file records snapshots compact artifact) ->
        [0.1, 1.0, 0.1, 0.0]

      word in ~w(chat user assistant streams metadata) ->
        [0.0, 0.1, 1.0, 0.1]

      word in ~w(tool research apis public adapter model embedding vectors signatures) ->
        [0.1, 0.0, 0.1, 1.0]

      true ->
        [0.35, 0.35, 0.35, 0.35]
    end
  end

  rows =
    vocab
    |> Enum.sort_by(fn {_word, id} -> id end)
    |> Enum.flat_map(fn {word, _id} -> category_vector.(word) end)

  tensor =
    Enum.reduce(rows, <<>>, fn value, acc ->
      <<acc::binary, value::little-float-32>>
    end)

  header =
    Jason.encode!(%{
      "embeddings" => %{
        "dtype" => "F32",
        "shape" => [map_size(vocab), 4],
        "data_offsets" => [0, byte_size(tensor)]
      }
    })

  File.write!(
    Path.join(model_dir, "config.json"),
    Jason.encode!(%{
      "model_type" => "model2vec",
      "dim" => 4,
      "description" => "Tiny example fixture for SpectreMnemonic parallel_memory"
    })
  )

  File.write!(
    Path.join(model_dir, "tokenizer.json"),
    Jason.encode!(%{"model" => %{"vocab" => vocab}})
  )

  File.write!(
    Path.join(model_dir, "model.safetensors"),
    <<byte_size(header)::little-unsigned-integer-64, header::binary, tensor::binary>>
  )
end

data_root = Path.join(__DIR__, "mnemonic_data")
model_dir = Path.join([__DIR__, "models", "tiny_model2vec"])

log.("setup", "Resetting example data root: #{data_root}")
File.rm_rf!(data_root)

log.("model", "Writing tiny embedding model fixture to #{model_dir}")
write_tiny_model.(model_dir)

log.("model", "Configuring local Model2Vec embedding provider")

Application.put_env(:spectre_mnemonic, :embedding,
  fast: [
    enabled: true,
    model_id: "example/tiny-model2vec",
    model_dir: model_dir,
    dimensions: 4,
    signature_bits: 8
  ]
)

demo_embedding = SpectreMnemonic.Embedding.Service.embed("parallel durable replay task", [])

log.(
  "model",
  "Smoke test vector_dims=#{Vector.dimensions(demo_embedding.vector)} signature_bytes=#{byte_size(demo_embedding.binary_signature || <<>>)}"
)

log.("setup", "Configuring persistent memory to use local append-only file storage")

Application.put_env(:spectre_mnemonic, :persistent_memory,
  write_mode: :all,
  read_mode: :smart,
  failure_mode: :best_effort,
  stores: [
    [
      id: :example_file,
      adapter: StoreFile,
      role: :primary,
      duplicate: true,
      opts: [data_root: data_root]
    ]
  ]
)

files = [
  Path.join(__DIR__, "test.txt"),
  Path.join(__DIR__, "tasks.txt"),
  Path.join(__DIR__, "chat.txt")
]

log.("parse", "Reading #{length(files)} fixture files in parallel")

events =
  files
  |> Task.async_stream(
    fn path ->
      parsed_events = Parser.from_file(path)
      {path, parsed_events}
    end,
    ordered: false,
    timeout: 10_000
  )
  |> Enum.flat_map(fn {:ok, {path, parsed_events}} ->
    log.("parse", "#{Path.basename(path)} -> #{length(parsed_events)} events")

    Enum.each(parsed_events, fn event ->
      line = Map.fetch!(event.metadata, :line)

      log.(
        "event",
        "#{event.source}:#{line} #{event.type}/#{event.stream} task=#{event.task_id || "-"} #{preview.(event.text)}"
      )
    end)

    parsed_events
  end)

log.("parse", "Normalized #{length(events)} total events")
log.("remember", "Remembering events concurrently through SpectreMnemonic.remember/2")

remembered =
  events
  |> Task.async_stream(
    fn event ->
      result =
        SpectreMnemonic.remember(event.text,
          title: "#{event.source}:#{event.metadata.line} #{event.type}",
          stream: event.stream,
          kind: event.type,
          task_id: event.task_id,
          metadata: Map.put(event.metadata, :source, event.source),
          chunk_words: 42,
          overlap_words: 8
        )

      {event, result}
    end,
    ordered: false,
    timeout: 10_000
  )
  |> Enum.map(fn
    {:ok, {event, {:ok, packet}}} ->
      root = packet.root
      dimensions = Vector.dimensions(root.vector)
      signature_bytes = byte_size(root.binary_signature || <<>>)
      model = get_in(root.embedding, [:metadata, :model])

      log.(
        "remembered",
        "#{event.source}:#{event.metadata.line} root=#{root.id} #{event.type}/#{event.stream} chunks=#{length(packet.chunks)} summaries=#{length(packet.summaries)} categories=#{length(packet.categories)} edges=#{length(packet.associations)} vector_dims=#{dimensions} signature_bytes=#{signature_bytes} model=#{model || "-"}"
      )

      packet

    {:ok, {event, {:error, reason}}} ->
      raise "failed to remember #{event.source}:#{event.metadata.line}: #{inspect(reason)}"

    {:exit, reason} ->
      raise "parallel remember task failed: #{inspect(reason)}"
  end)

remembered_moments = Enum.flat_map(remembered, & &1.moments)
remembered_edges = Enum.flat_map(remembered, & &1.associations)

log.(
  "summary",
  "Remembered #{length(remembered)} events into #{length(remembered_moments)} active moments and #{length(remembered_edges)} graph edges"
)

embedded_count = Enum.count(remembered_moments, &is_binary(&1.vector))

log.(
  "model",
  "Embedded #{embedded_count}/#{length(remembered_moments)} active moments with #{Path.basename(model_dir)}"
)

if embedded_count == 0 do
  raise "expected remembered moments to have embeddings"
end

remembered_moments
|> Enum.group_by(& &1.kind)
|> Enum.sort_by(fn {kind, _items} -> kind end)
|> Enum.each(fn {kind, items} ->
  log.("summary", "#{kind}: #{length(items)}")
end)

artifact_path = Path.join([data_root, "artifacts", "parallel-memory-session-report.txt"])

log.("artifact", "Writing example artifact file to #{artifact_path}")

File.mkdir_p!(Path.dirname(artifact_path))

File.write!(artifact_path, """
Parallel memory session report

Remembered events: #{length(remembered)}
Source files: #{Enum.map_join(files, ", ", &Path.basename/1)}
Active moments: #{length(remembered_moments)}
Graph edges: #{length(remembered_edges)}
Purpose: Demonstrate unified intake, graph memory, summaries, persistent memory, artifact registration, replay, recall, search, and snapshots.
""")

{:ok, artifact} =
  SpectreMnemonic.artifact(artifact_path,
    content_type: "text/plain",
    metadata: %{
      example: :parallel_memory,
      remembered_events: length(remembered),
      active_moments: length(remembered_moments),
      graph_edges: length(remembered_edges),
      generated_by: "example/demo.exs"
    }
  )

log.(
  "artifact",
  "Registered artifact=#{artifact.id} source=#{artifact.source} content_type=#{artifact.content_type}"
)

log.("consolidate", "Promoting active remembered graph into durable records")
{:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: 1.0)

log.(
  "consolidate",
  "Persisted #{length(knowledge)} knowledge records plus summaries, categories, embeddings, and associations"
)

log.("knowledge", "Writing compact progressive knowledge events")

knowledge_events = [
  %{
    type: :summary,
    summary:
      "The demo ingested chat, tasks, tool events, decisions, and research into active graph memory, then consolidated durable records.",
    usage: %{count: 2},
    metadata: %{attention: 3.0, example: :parallel_memory}
  },
  %{
    type: :skill,
    name: "Replay durable file memory",
    text:
      "Call SpectreMnemonic.Persistence.Manager.replay/1 to inspect append-only persistent records.",
    metadata: %{attention: 2.0, example: :parallel_memory}
  },
  %{
    type: :skill,
    name: "Search progressive knowledge",
    text:
      "Call SpectreMnemonic.search_knowledge/2 for targeted knowledge.smem lookup without loading the full packet.",
    metadata: %{attention: 2.0, example: :parallel_memory}
  },
  %{
    type: :fact,
    text: "knowledge.smem stores compact events under data_root/knowledge/knowledge.smem.",
    metadata: %{confidence: 1.0, example: :parallel_memory}
  },
  %{
    type: :procedure,
    name: "Load budgeted knowledge",
    steps: [
      "Append compact knowledge events.",
      "Search with SpectreMnemonic.search_knowledge/2 when a cue is specific.",
      "Load with SpectreMnemonic.load_knowledge/1 when recall needs a compact packet."
    ],
    metadata: %{confidence: 1.0, example: :parallel_memory}
  },
  %{
    type: :latest_ingestion,
    text: "The latest demo run remembered #{length(remembered)} fixture events.",
    metadata: %{remembered_events: length(remembered), example: :parallel_memory}
  }
]

knowledge_sequences =
  Enum.map(knowledge_events, fn event ->
    {:ok, sequence} = Base.append(event, data_root: data_root)
    sequence
  end)

log.(
  "knowledge",
  "Appended #{length(knowledge_sequences)} compact events to #{Path.join([data_root, "knowledge", "knowledge.smem"])}"
)

{:ok, knowledge_matches} =
  SpectreMnemonic.search_knowledge("durable replay storage", data_root: data_root, limit: 4)

log.(
  "knowledge",
  "search #{inspect("durable replay storage")} -> #{length(knowledge_matches)} compact matches"
)

Enum.each(knowledge_matches, fn match ->
  log.(
    "know-match",
    "#{match.type} score=#{match.score} id=#{match.id} #{preview.(match.text)}"
  )
end)

{:ok, loaded_knowledge} =
  SpectreMnemonic.load_knowledge(
    data_root: data_root,
    max_loaded_bytes: 2_000,
    max_skills: 3,
    max_latest_ingestions: 2
  )

log.(
  "knowledge",
  "loaded summary_bytes=#{byte_size(loaded_knowledge.summary || "")} skills=#{length(loaded_knowledge.skills)} facts=#{length(loaded_knowledge.facts)} procedures=#{length(loaded_knowledge.procedures)} latest=#{length(loaded_knowledge.latest_ingestions)}"
)

{:ok, compacted_knowledge} = SpectreMnemonic.compact_knowledge(data_root: data_root)

log.(
  "knowledge",
  "compacted knowledge.smem events=#{compacted_knowledge.count}"
)

log.("status", "Checking task statuses created from task/todo lines")

events
|> Enum.map(& &1.task_id)
|> Enum.reject(&is_nil/1)
|> Enum.uniq()
|> Enum.each(fn task_id ->
  case SpectreMnemonic.status(task_id) do
    {:ok, status} ->
      log.(
        "status",
        "#{task_id} stream=#{Map.get(status, :stream)} kind=#{Map.get(status, :kind)}"
      )

    {:error, :not_found} ->
      log.("status", "#{task_id} not found")
  end
end)

queries = [
  "parallel ingestion task status",
  "durable replay local file storage",
  "chat query about streams and metadata",
  "tool research public APIs"
]

log.("recall", "Running #{length(queries)} recall queries")

Enum.each(queries, fn query ->
  {:ok, packet} = SpectreMnemonic.recall(query, limit: 4)

  log.(
    "recall",
    "#{inspect(query)} -> #{length(packet.moments)} moments, confidence=#{packet.confidence}"
  )

  Enum.each(packet.moments, fn moment ->
    source = Map.get(moment.metadata, :source, "unknown")
    line = Map.get(moment.metadata, :line, "?")

    log.(
      "match",
      "[#{moment.kind}/#{moment.stream}] #{source}:#{line} moment=#{moment.id} #{preview.(moment.text)}"
    )
  end)
end)

log.("replay", "Replaying persistent records from local file storage")
{:ok, durable_records} = Manager.replay()

log.(
  "replay",
  "Loaded #{length(durable_records)} records from #{Path.join([data_root, "segments", "active.smem"])}"
)

durable_records
|> Enum.take(10)
|> Enum.each(fn record ->
  payload = record.payload
  text = Map.get(payload, :text) || inspect(payload)

  log.(
    "record",
    "#{record.family}/#{record.operation} #{record.id} source=#{record.source_event_id} #{preview.(text)}"
  )
end)

log.("search", "Searching active memory plus durable stores for replay records metadata")
{:ok, search_results} = SpectreMnemonic.search("replay records metadata", limit: 5)

Enum.each(search_results, fn result ->
  record = Map.get(result, :record)
  text = if record && Map.has_key?(record, :text), do: record.text, else: inspect(result)

  log.(
    "search",
    "rank=#{Map.get(result, :rank, "-")} source=#{Map.get(result, :source, "-")} family=#{Map.get(result, :family, "-")} #{preview.(text)}"
  )
end)

log.("done", "Search returned #{length(search_results)} active/durable result entries")

log.("compact", "Running semantic persistent memory compaction")
{:ok, semantic_compact_results} = Manager.compact(mode: :semantic)

log.("compact", "semantic #{inspect(semantic_compact_results)}")

log.("compact", "Running semantic plus physical persistent memory compaction")
{:ok, all_compact_results} = Manager.compact(mode: :all)

log.("compact", "all semantic=#{inspect(all_compact_results.semantic)}")

compact_results = all_compact_results.physical

Enum.each(compact_results, fn
  {store_id, {:ok, snapshot_path}} ->
    log.("compact", "#{store_id} snapshot=#{snapshot_path}")

  {store_id, {:error, reason}} ->
    log.("compact", "#{store_id} failed=#{inspect(reason)}")
end)

log.("files", "Persistent memory files now on disk")

[
  Path.join([model_dir, "*"]),
  Path.join([data_root, "knowledge", "*"]),
  Path.join([data_root, "segments", "*"]),
  Path.join([data_root, "snapshots", "*"]),
  Path.join([data_root, "artifacts", "*"])
]
|> Enum.flat_map(&Path.wildcard/1)
|> Enum.sort()
|> Enum.each(fn path ->
  %{size: size} = File.stat!(path)

  relative_path =
    if String.starts_with?(path, data_root) do
      Path.relative_to(path, data_root)
    else
      Path.relative_to(path, __DIR__)
    end

  log.("files", "#{relative_path} size=#{size}")
end)
