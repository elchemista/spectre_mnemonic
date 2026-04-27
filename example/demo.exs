Code.require_file("models.ex", __DIR__)

alias ParallelMemoryExample.Parser
alias SpectreMnemonic.Embedding.Vector
alias SpectreMnemonic.PersistentMemory
alias SpectreMnemonic.Store.FileStorage

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

demo_embedding = SpectreMnemonic.Embedding.embed("parallel durable replay task", [])

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
      adapter: FileStorage,
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
log.("save", "Saving events concurrently through SpectreMnemonic.signal/2")

saved =
  events
  |> Task.async_stream(
    fn event ->
      result =
        SpectreMnemonic.signal(event.text,
          stream: event.stream,
          kind: event.type,
          task_id: event.task_id,
          metadata: Map.put(event.metadata, :source, event.source)
        )

      {event, result}
    end,
    ordered: false,
    timeout: 10_000
  )
  |> Enum.map(fn
    {:ok, {event, {:ok, result}}} ->
      dimensions = Vector.dimensions(result.moment.vector)
      signature_bytes = byte_size(result.moment.binary_signature || <<>>)
      model = get_in(result.moment.embedding, [:metadata, :model])

      log.(
        "saved",
        "#{event.source}:#{event.metadata.line} signal=#{result.signal.id} moment=#{result.moment.id} #{event.type}/#{event.stream} vector_dims=#{dimensions} signature_bytes=#{signature_bytes} model=#{model || "-"}"
      )

      result

    {:ok, {event, {:error, reason}}} ->
      raise "failed to save #{event.source}:#{event.metadata.line}: #{inspect(reason)}"

    {:exit, reason} ->
      raise "parallel save task failed: #{inspect(reason)}"
  end)

log.("summary", "Saved #{length(saved)} events from #{length(files)} files")

embedded_count = Enum.count(saved, &is_binary(&1.moment.vector))

log.(
  "model",
  "Embedded #{embedded_count}/#{length(saved)} saved moments with #{Path.basename(model_dir)}"
)

if embedded_count != length(saved) do
  raise "expected every saved moment to have an embedding, got #{embedded_count}/#{length(saved)}"
end

saved
|> Enum.group_by(& &1.moment.kind)
|> Enum.sort_by(fn {kind, _items} -> kind end)
|> Enum.each(fn {kind, items} ->
  log.("summary", "#{kind}: #{length(items)}")
end)

artifact_path = Path.join([data_root, "artifacts", "parallel-memory-session-report.txt"])

log.("artifact", "Writing example artifact file to #{artifact_path}")

File.mkdir_p!(Path.dirname(artifact_path))

File.write!(artifact_path, """
Parallel memory session report

Saved events: #{length(saved)}
Source files: #{Enum.map_join(files, ", ", &Path.basename/1)}
Purpose: Demonstrate persistent memory, artifact registration, replay, recall, search, and snapshots.
""")

{:ok, artifact} =
  SpectreMnemonic.artifact(artifact_path,
    content_type: "text/plain",
    metadata: %{
      example: :parallel_memory,
      saved_events: length(saved),
      generated_by: "example/demo.exs"
    }
  )

log.(
  "artifact",
  "Registered artifact=#{artifact.id} source=#{artifact.source} content_type=#{artifact.content_type}"
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
{:ok, durable_records} = PersistentMemory.replay()

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

log.("compact", "Compacting example file store into snapshots/")
{:ok, compact_results} = PersistentMemory.compact()

Enum.each(compact_results, fn
  {store_id, {:ok, snapshot_path}} ->
    log.("compact", "#{store_id} snapshot=#{snapshot_path}")

  {store_id, {:error, reason}} ->
    log.("compact", "#{store_id} failed=#{inspect(reason)}")
end)

log.("files", "Persistent memory files now on disk")

[
  Path.join([model_dir, "*"]),
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
