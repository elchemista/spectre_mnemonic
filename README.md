# SpectreMnemonic

SpectreMnemonic is a small Elixir memory engine for live applications. It keeps
recent working memory in ETS, routes new signals into streams, recalls related
moments, and writes durable memory envelopes through pluggable storage adapters.

Use it when an application needs short-term and durable memory around live
work: agent sessions, chat context, task execution, tool events, research notes,
decisions, artifacts, and recall queries. It is not a full application
database. It is a memory layer that lets your app record what happened, retrieve
nearby context later, and persist those memories through configurable stores.

The public API is intentionally compact:

```elixir
{:ok, memory} =
  SpectreMnemonic.remember("research found Elixir ETS details",
    stream: :research,
    task_id: "task-a"
  )

{:ok, packet} = SpectreMnemonic.recall("how is task-a going?")
{:ok, results} = SpectreMnemonic.search("ETS details")
{:ok, knowledge} = SpectreMnemonic.consolidate()
```

## Features

- Unified intake through `SpectreMnemonic.remember/2` for text, prompts, chat,
  tasks, code strings, maps, lists, and already-parsed external documents.
- Stream-aware low-level ingestion through `SpectreMnemonic.signal/2`,
  `SpectreMnemonic.Active.Router`, and per-stream workers.
- Active memory in ETS for signals, moments, associations, artifacts, and status.
- Automatic chunking, fallback summarization, categorization, and graph linking
  for high-level remembered input.
- Adapter-free recall using keywords, entities, SimHash-style fingerprints, and graph expansion.
- Optional vector recall through embedding adapters or the local Model2Vec provider.
- Durable persistence through `SpectreMnemonic.Persistence.Manager` and storage adapters.
- Append-only local file storage with replay, deduplication, tombstones, and compaction.
- Compact progressive knowledge through `knowledge.smem`, with budgeted loading,
  targeted search, and adapter-driven compaction.
- Adapter-driven consolidation for deciding what active memory becomes durable.
- Inert Action Language recipes attached to memories for external runtimes such
  as `spectre_kinetic`.

## Installation

Add the dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:spectre_mnemonic, "~> 0.1.0"}
  ]
end
```

Start it under your supervision tree or include it as an OTP application. The
library supervision tree starts ETS ownership, persistent memory, stream
supervision, routing, recall indexing, focus, recall, and consolidation.

## API Overview

`SpectreMnemonic.remember/2` is the high-level intake API. It accepts any
already-parsed information, creates active graph memory, chunks long text,
summarizes, categorizes, links related records, and returns a
`SpectreMnemonic.Intake.Packet`:

```elixir
{:ok, memory} =
  SpectreMnemonic.remember("TODO: implement graph recall over chunked notes",
    title: "Planner note",
    task_id: "alpha",
    metadata: %{source: :agent},
    chunk_words: 180,
    overlap_words: 40
  )

memory.root
memory.chunks
memory.summaries
memory.categories
memory.associations
memory.persistence
```

`remember/2` is active-first by default. It builds hot ETS memory and graph
edges immediately, but durable promotion is handled by
`SpectreMnemonic.consolidate/1` unless you pass `persist?: true`.

JSON-looking strings are treated as text. If another library parses JSON, PDF,
DOCX, HTML, or code into maps/lists/text first, pass that parsed result to
`remember/2`.

`SpectreMnemonic.signal/2` is the lower-level API for recording one event or
moment directly:

```elixir
SpectreMnemonic.signal("implemented disk replay checksum",
  stream: :task_execution,
  task_id: "alpha",
  kind: :task_execution,
  metadata: %{source: :agent}
)
```

`SpectreMnemonic.recall/2` returns a `SpectreMnemonic.Recall.Packet` containing
nearby moments, active statuses, associations, artifacts, and confidence:

```elixir
{:ok, packet} = SpectreMnemonic.recall("progress alpha disk replay", limit: 5)
```

`SpectreMnemonic.search/2` merges active recall results with durable storage
results from adapters that advertise search capabilities:

```elixir
{:ok, results} = SpectreMnemonic.search("database search")
```

`SpectreMnemonic.forget/2` removes matching active moments and writes tombstones:

```elixir
SpectreMnemonic.forget({:task, "alpha"})
SpectreMnemonic.forget("mom_123")
```

`SpectreMnemonic.consolidate/1` promotes active memory into durable records:

```elixir
{:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: 1.0)
```

For experiments, pass a runtime function:

```elixir
SpectreMnemonic.consolidate(consolidate_with: fn context ->
  {:ok, %{knowledge: MyApp.choose_knowledge(context.moments)}}
end)
```

For production, configure an adapter:

```elixir
config :spectre_mnemonic,
  consolidation_adapter: MyApp.MemoryConsolidator
```

## Runnable Example

The `example/` folder contains a complete local demo that exercises the main
system paths:

- parses rich fixture data from `test.txt`, `tasks.txt`, and `chat.txt`
- remembers chat, task, tool, research, decision, error, event, system, and
  memory records in parallel through `SpectreMnemonic.remember/2`
- creates chunks, summaries, categories, and graph edges for each remembered
  fixture event
- creates a tiny local Model2Vec fixture under `example/models/tiny_model2vec`
  and uses it to generate vectors and binary signatures
- consolidates active graph memory into durable moments, summaries, categories,
  embeddings, associations, and knowledge records
- appends compact progressive knowledge events to
  `example/mnemonic_data/knowledge/knowledge.smem`
- searches and loads progressive knowledge without hydrating the full event log
- writes durable memory to the append-only persistent store at
  `example/mnemonic_data/segments/active.smem`
- writes and registers an example artifact under `example/mnemonic_data/artifacts`
- runs semantic and physical persistent memory compaction
- runs recall and search queries and logs each step

Run it from the repository root:

```bash
mix run example/demo.exs
```

Successful output includes lines like:

```text
model        Smoke test vector_dims=4 signature_bytes=1
remembered   ... chunks=1 summaries=2 categories=... edges=...
summary      Remembered 39 events into ... active moments and ... graph edges
consolidate  Persisted ... knowledge records plus summaries, categories, embeddings, and associations
knowledge    Appended compact progressive events to .../knowledge/knowledge.smem
knowledge    search "durable replay" -> ... compact matches
knowledge    loaded summary_bytes=... skills=... facts=...
replay       Loaded ... records from .../example/mnemonic_data/segments/active.smem
compact      semantic %{example_file: %{...}}
compact      example_file snapshot=.../example/mnemonic_data/snapshots/snapshot-...
files        models/tiny_model2vec/model.safetensors size=...
```

After running, inspect the generated persistent-memory files with:

```bash
find example -maxdepth 4 -type f | sort
```

The tiny model files are intentionally committed so the embedding example is
visible and offline-friendly. The `example/mnemonic_data/` directory is ignored
because it is generated runtime data.

## Action Language Recipes

Memories and artifacts can carry English-like Action Language (AL) recipes.
SpectreMnemonic stores and recalls these recipes as data only; it never parses
or executes AL during signal, recall, search, replay, or compaction.

```elixir
{:ok, %{moment: moment, action_recipe: recipe}} =
  SpectreMnemonic.signal("cached weather JSON for Rome",
    action_recipe: "When Kinetic asks, refresh JSON from the weather endpoint",
    action_intent: "refresh cached JSON",
    ttl_ms: 60_000,
    refresh_on_recall?: true,
    source_url: "https://api.example.test/weather",
    tags: [:weather, :json]
  )

{:ok, packet} = SpectreMnemonic.recall("weather JSON Rome")
Enum.map(packet.action_recipes, & &1.text)
```

Recipes are stored as `%SpectreMnemonic.Memory.ActionRecipe{}` records under the
`:action_recipes` persistent-memory family and linked to their memory through
an `:attached_action` association. Use `SpectreMnemonic.Actions.Runtime` only
when you explicitly want to delegate analysis or execution to a configured
adapter:

```elixir
config :spectre_mnemonic,
  action_runtime_adapter: MyApp.KineticRuntime

SpectreMnemonic.Actions.Runtime.analyze(recipe)
SpectreMnemonic.Actions.Runtime.run(recipe, %{memory: moment})
```

The default runtime is disabled, so both calls return
`{:error, :runtime_not_configured}` unless an adapter is configured or passed in
the call options.

## Project Layout

- `lib/spectre_mnemonic.ex` is the public facade.
- `lib/spectre_mnemonic/active/*` owns hot ETS focus, routing, stream workers,
  and active process supervision.
- `lib/spectre_mnemonic/memory/*` contains memory structs such as
  `SpectreMnemonic.Memory.Moment`, `Signal`, `Association`, and `Artifact`.
- `lib/spectre_mnemonic/intake*` powers `remember/2`, intake packets, and
  summarization adapters.
- `lib/spectre_mnemonic/recall/*` builds recall packets, cues, fingerprints,
  and active embedding indexes.
- `lib/spectre_mnemonic/knowledge/*` loads `knowledge.smem`, compacts
  progressive knowledge, and consolidates active graph memory into durable
  families.
- `lib/spectre_mnemonic/persistence/*` coordinates durable stores and contains
  storage behaviours, records, and built-in backends.
- `lib/spectre_mnemonic/actions/*` delegates Action Language analysis/execution
  to an explicitly configured runtime adapter.
- `lib/spectre_mnemonic/embedding/*` contains the embedding service, adapter
  behaviour, vector math, quantization, and model helpers.

## Persistence

The default persistence backend is the local append-only file store:

```elixir
config :spectre_mnemonic,
  persistent_memory: [
    write_mode: :all,
    read_mode: :smart,
    failure_mode: :best_effort,
    stores: [
      [
        id: :local_file,
        adapter: SpectreMnemonic.Persistence.Store.File,
        role: :primary,
        duplicate: true,
        opts: [data_root: "mnemonic_data"]
      ]
    ]
  ]
```

Storage adapters implement `SpectreMnemonic.Persistence.Store.Adapter`. Built-in Postgres,
Mongo, and S3 modules advertise intended capabilities but return setup errors
until replaced with app-specific implementations.

Persistent memory compaction has explicit modes:

```elixir
SpectreMnemonic.Persistence.Manager.compact()
SpectreMnemonic.Persistence.Manager.compact(mode: :physical)
SpectreMnemonic.Persistence.Manager.compact(mode: :semantic)
SpectreMnemonic.Persistence.Manager.compact(mode: :all)
```

`:physical` is the default and keeps the original file snapshot behavior.
`:semantic` first asks an adapter with `:semantic_compact` support to compact
natively. If the store can replay records, SpectreMnemonic falls back to a
generic semantic pass and writes compact records or tombstones through the same
store API. Stores without either path are skipped cleanly. `:all` runs semantic
compaction first, then physical snapshot compaction.

Configure persistent semantic compaction with a project adapter when you want
LLM-backed or database-native behavior:

```elixir
config :spectre_mnemonic,
  persistent_memory: [
    compact_mode: :physical,
    semantic_compact_adapter: MyApp.PersistentCompactAdapter,
    semantic_compact_families: [:moments, :knowledge, :summaries, :categories, :associations],
    semantic_compact_limit: 1_000
  ]
```

The adapter implements `SpectreMnemonic.Persistence.Compact.Adapter`:

```elixir
defmodule MyApp.PersistentCompactAdapter do
  @behaviour SpectreMnemonic.Persistence.Compact.Adapter

  @impl true
  def compact(input, _opts) do
    records =
      input.records
      |> Enum.group_by(& &1.family)
      |> Enum.map(fn {family, records} ->
        {family,
         %{
           text: "Compacted #{length(records)} #{family} records",
           source_record_ids: Enum.map(records, & &1.id)
         }}
      end)

    {:ok, %{strategy: :my_app, records: records, replace_ids: []}}
  end
end
```

The durable envelope model is family-based and intentionally Postgres-ready.
Current consolidation writes families such as `:moments`, `:summaries`,
`:categories`, `:embeddings`, `:associations`, `:knowledge`,
`:consolidation_jobs`, and `:tombstones`. A future SQL adapter can index family,
payload id, graph endpoints, text, vector metadata, source id, and inserted
time without changing the high-level intake API.

## Progressive Knowledge

`knowledge.smem` is a compact progressive knowledge log, separate from active
ETS memory and separate from the durable persistent-memory families. It stores
small knowledge events at `data_root/knowledge/knowledge.smem`:

- `:summary`
- `:skill`
- `:latest_ingestion`
- `:fact`
- `:procedure`
- `:compaction_marker`

Write compact events directly:

```elixir
SpectreMnemonic.Knowledge.Base.append(%{
  type: :skill,
  name: "Replay local file storage",
  text: "Use SpectreMnemonic.Persistence.Manager.replay/1 to inspect append-only store records.",
  metadata: %{attention: 2.0}
})

SpectreMnemonic.Knowledge.Base.append(%{
  type: :fact,
  text: "knowledge.smem is loaded by budget and is not expanded into ETS."
})
```

Search the knowledge log without loading the whole packet:

```elixir
{:ok, matches} = SpectreMnemonic.search_knowledge("replay storage", limit: 5)
```

Load only a compact budgeted packet:

```elixir
{:ok, knowledge} =
  SpectreMnemonic.load_knowledge(
    max_loaded_bytes: 8_000,
    max_skills: 10,
    max_latest_ingestions: 10
  )

knowledge.summary
knowledge.skills
knowledge.facts
knowledge.procedures
knowledge.latest_ingestions
```

`SpectreMnemonic.recall/2` includes this compact packet in
`RecallPacket.knowledge` by default. Pass `include_knowledge: false` when a
recall should stay active-memory only.

Compact progressive knowledge with the deterministic default or a custom
adapter:

```elixir
SpectreMnemonic.compact_knowledge()

config :spectre_mnemonic,
  compact_adapter: MyApp.KnowledgeCompactAdapter
```

The adapter implements `SpectreMnemonic.Knowledge.Compact.Adapter` and can call an LLM,
a local model, or a deterministic app-specific policy. Its output is normalized
back into compact knowledge events.

## Summarization

Summarization is optional. Without configuration, `remember/2` uses a
deterministic fallback to produce chunk summaries, a root summary, key points,
entities, and heuristic categories.

Configure an adapter for LLM or local model summaries:

```elixir
config :spectre_mnemonic,
  summarizer_adapter: MyApp.Summarizer
```

Adapters implement `SpectreMnemonic.Intake.Summarizer.Adapter.summarize/2`. They
receive `%{scope: :chunk | :root | atom(), text: binary(), metadata: map()}` and
may return either summary text or a map containing `:text`, `:key_points`,
`:entities`, `:categories`, `:relations`, `:confidence`, and `:metadata`.

## Embeddings

Embeddings are optional. Without an adapter, recall still works through text,
fingerprints, and associations.

When embeddings are enabled, `SpectreMnemonic.signal/2` and `remember/2` embed
each new memory moment at ingestion time. The normalized vector and binary
signature are stored on the active `%SpectreMnemonic.Memory.Moment{}` and indexed by
`SpectreMnemonic.Recall.Index`.
Later, `SpectreMnemonic.recall/2` embeds the cue and uses vector/signature
similarity as part of the recall score.

Configure a custom adapter:

```elixir
config :spectre_mnemonic, embedding_adapter: MyApp.EmbeddingAdapter
```

Adapters implement `SpectreMnemonic.Embedding.Adapter.embed/2` and return either
`{:ok, vector}`, `{:ok, embedding_map}`, or `{:error, reason}`.

Enable the local Model2Vec provider:

```elixir
config :spectre_mnemonic,
  embedding: [
    fast: [
      enabled: true,
      model_id: "minishlab/potion-base-8M",
      download: true
    ]
  ]
```

Downloads are opt-in. For production, pre-populate the model cache or provide a
known `:model_dir`.

For a fully local demo, run:

```bash
mix run example/demo.exs
```

The demo configures `SpectreMnemonic.Embedding.Model2VecStatic` with the tiny
fixture in `example/models/tiny_model2vec`, remembers embedded graph memory,
recalls with vectors, consolidates, and persists the resulting records.

### Gemma embeddings for consolidation

`SpectreMnemonic.consolidate/1` promotes selected active moments into durable
`%SpectreMnemonic.Knowledge.Record{}` records. Consolidation does not re-embed text by
itself; it copies the `vector`, `binary_signature`, and `embedding` already
stored on each moment. To consolidate memory with Gemma embeddings, configure a
Gemma-backed embedding adapter before calling `remember/2` or `signal/2`, then
consolidate:

```elixir
config :spectre_mnemonic,
  embedding_adapter: MyApp.GemmaEmbeddingAdapter
```

```elixir
defmodule MyApp.GemmaEmbeddingAdapter do
  @behaviour SpectreMnemonic.Embedding.Adapter

  @impl true
  def embed(input, _opts) do
    text = if is_binary(input), do: input, else: inspect(input)

    # Call your Gemma embedding runtime here: Bumblebee/Nx, an HTTP service,
    # Ollama, EXLA-backed serving, or another local inference process.
    {:ok, vector} = MyApp.Gemma.embed(text)

    {:ok,
     %{
       vector: vector,
       metadata: %{
         provider: :gemma,
         model: "embedding-gemma",
         purpose: :memory_consolidation
       }
     }}
  end
end
```

```elixir
{:ok, memory} =
  SpectreMnemonic.remember("User prefers compact technical summaries",
    stream: :chat,
    task_id: "session-42",
    kind: :memory,
    metadata: %{importance: :high}
  )

{:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: memory.root.attention)

Enum.map(knowledge, fn item ->
  {item.text, item.embedding.metadata.model}
end)
```

The reserved module `SpectreMnemonic.Embedding.EmbeddingGemma` is currently a
disabled placeholder and returns `{:error, :deep_embedding_disabled}`. Use your
own adapter, as above, until Gemma support is wired into the library.

## Development

Format and test before committing:

```bash
mix format
mix test
```
