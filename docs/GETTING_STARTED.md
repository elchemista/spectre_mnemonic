# Getting started

This guide takes a new application from installation to its first durable
memory and explains the partition model used by every other feature.

## Install the dependency

SpectreMnemonic is distributed from GitHub:

```elixir
def deps do
  [
    {:spectre_mnemonic, github: "elchemista/spectre_mnemonic", branch: "feature/stack-tools-0.4"}
  ]
end
```

There is currently no Hex package for SpectreMnemonic.
Spectre is optional for standalone use. For unreleased core 0.4 Stack
integration, use the Git/path dependencies in the [README](../README.md).

## Supervise an Engine

Each Engine has a stable durable identity, an application namespace, its own
data directory, projections, stores, limits, embedding space, and maintenance
scheduler:

```elixir
children = [
  {SpectreMnemonic.Engine,
   name: MyApp.Memory,
   storage_id: "my-app-memory",
   namespace: "my_app",
   data_root: "data/memory",
   limits: [
     max_hot_bytes_per_scope: 64 * 1024 * 1024,
     max_partition_queue: 128,
     max_store_queue: 256
   ]}
]
```

`storage_id` must remain stable through compatible releases. The registered
name is only a runtime address and may change. The Engine registry rejects a
duplicate `storage_id` in the same VM.

Pass the Engine on each operation:

```elixir
SpectreMnemonic.remember("Retry policy approved",
  engine: MyApp.Memory,
  scope: {:project, "checkout"},
  persist?: true
)
```

Accepted references are an Engine PID, atom name, `{:via, module, term}`, or
`%SpectreMnemonic.Engine.Ref{}`. A PID is call-local and is never stored.

### Legacy default Engine

Existing 0.1.x configuration still starts a compatibility Engine:

```elixir
config :spectre_mnemonic,
  namespace: "my_app_memory"
```

Calls without `engine:` then use `SpectreMnemonic.DefaultEngine` and the old
data-root layout. Without this configuration the application starts normally,
but a call lacking `engine:` returns `{:error, :mnemonic_engine_required}`.

## Configure JSON only when needed

Elixir 1.19 includes the dependency-free `JSON` module, so it is the smallest
default choice for JSON-backed features:

### Choose a JSON implementation

SpectreMnemonic does not select or start a JSON library. The configured module
must export `decode/1` and either `encode/1` or `encode!/1`. JSON is used by
`.mnemonic` exports/readers and by the local Model2Vec loader; operations that
do not touch those features work without `:json_library`.

Use the built-in implementation to add no dependency:

```elixir
config :spectre_mnemonic, json_library: JSON
```

Or let the host application own Jason:

```elixir
# mix.exs
{:jason, "~> 1.4"}

# config/config.exs
config :spectre_mnemonic, json_library: Jason
```

Missing, unavailable, or incomplete adapters return explicit
`:json_library_not_configured` or `{:json_*, ...}` errors at the feature
boundary. SpectreMnemonic declares Jason as optional, so consumer applications
must declare it themselves when selecting it.

### Install only optional feature dependencies you use

The base memory and Vettore paths do not require these packages:

```elixir
def deps do
  [
    # Accurate Hugging Face tokenization for the local Model2Vec provider:
    {:tokenizers, "~> 0.5"},
    # Compatibility only when the host exchanges Nx tensors:
    {:nx, "~> 0.11"}
  ]
end
```

Without `tokenizers`, the local Model2Vec adapter uses its bounded lexical
fallback. Without Nx, ordinary list and little-endian f32 vector operations
continue through Vettore.

The application starts shared registries and minimal compatibility services.
Every Engine supervises its own partition executors, bounded writer,
projection shards, durable and vector indexes, knowledge projection, task
supervisor, and scheduler. Independent partitions execute concurrently; only
the physical boundary of one store is serialized.

## Understand scopes

A partition inside an Engine is exactly:

```text
{engine_ref, namespace, scope}
```

`scope` is caller-owned data. Common choices are:

```elixir
{:subject, "alice"}
{:tenant, "acme"}
{:project, "checkout"}
{:conversation, conversation_id}
```

The same scope must be supplied when writing, recalling, searching, linking,
forgetting, exporting, or erasing related memory:

```elixir
scope = {:project, "checkout"}

SpectreMnemonic.remember("Retry policy approved",
  engine: MyApp.Memory,
  scope: scope,
  persist?: true
)

SpectreMnemonic.recall("What was approved?", engine: MyApp.Memory, scope: scope)
```

Omitting `scope:` selects the unscoped partition only. It never means “search
all scopes." Administrative cross-tenant reads must issue separate explicit
calls and merge their results outside the library.

### Single-node contract

Multiple Engines and partitions are supported in one VM. Distributed ETS,
distributed locks, consensus, and cross-node ownership are not. If several
BEAM nodes can reach the same data root or remote store, the host must ensure
that only one node has an active writer for a given `storage_id`.

For readability, the remaining core examples omit `engine: MyApp.Memory`.
Add it to every call unless the legacy DefaultEngine is configured.

## First complete workflow

### Write a rich memory

```elixir
scope = {:project, "checkout"}

{:ok, intake} =
  SpectreMnemonic.remember(
    %{
      title: "Checkout release decision",
      text:
        "Marta moved checkout deployment to Friday. " <>
          "The payment sandbox is unavailable until Thursday."
    },
    scope: scope,
    stream: :planning,
    task_id: "deploy-42",
    tags: [:checkout, :release],
    occurred_at: ~U[2026-08-21 09:30:00Z],
    metadata: %{source: :project_log},
    persist?: true
  )

intake.root
intake.chunks
intake.summaries
intake.categories
intake.associations
```

`remember/2` is active-first. It creates immediately searchable memory, then
writes the generated records durably when `persist?: true`.

### Add an immediate event

```elixir
{:ok, %{signal: signal, moment: moment}} =
  SpectreMnemonic.signal("Payment sandbox is available again",
    scope: scope,
    stream: :task_execution,
    task_id: "deploy-42",
    kind: :tool,
    attention: 1.5,
    persist?: true
  )
```

Use `signal/2` for one event that does not need intake chunking, summaries, or
entity extraction.

### Recall active context

```elixir
{:ok, packet} =
  SpectreMnemonic.recall("Why did checkout deployment move?",
    scope: scope,
    limit: 8,
    budget: :mid,
    max_tokens: 2_000,
    graph_depth: 2,
    trace: true
  )

Enum.map(packet.moments, & &1.text)
packet.associations
packet.trace
```

Recall returns evidence rather than an answer. Its packet can also include
observations, mental models, Episodes, artifacts, progressive knowledge, and
action recipes.

### Search active and durable memory

```elixir
{:ok, results} =
  SpectreMnemonic.search("checkout sandbox",
    scope: scope,
    limit: 10
  )

Enum.map(results, fn result ->
  %{source: result.source, family: result.family, id: result.id, score: result.score}
end)
```

`search/2` returns a flat candidate list. Use `recall/2` when the consumer
needs a structured context packet.

### Consolidate important active memory

```elixir
{:ok, records} =
  SpectreMnemonic.consolidate(
    scope: scope,
    min_attention: 1.0
  )
```

Consolidation promotes selected active moments to compact durable knowledge.
Immediate persistence and later consolidation can be used independently.

## Decide between the main read APIs

| Need | Use | Shape |
| --- | --- | --- |
| Recent context plus graph neighbors | `recall/2` | `Recall.Packet` |
| Flat candidates from active and durable memory | `search/2` | list of `SearchResult` |
| Stable models, derived observations, and source evidence | `reflect/2` | `Reflection.Packet` |
| Only compact progressive knowledge | `search_knowledge/2` | scored knowledge events |
| Only observations | `search_observations/2` | observation records |
| Only curated mental models | `search_mental_models/2` | mental-model records |

## Spectre core 0.4 AgentServer integration

Use the [current Stack → Agent → Server example](../README.md) and
[core 0.4 migration guide](MIGRATING_TO_SPECTRE_0_4.md). Explicit tools require a
named Stack runtime. For user-partitioned memory declare `isolate_by([:subject])`
inside the install block; the host supplies a canonical subject and carries the
same partition into an admitted save candidate. Use `automatic: false` when
saving should happen only through an explicit governed command.

The [historical Instance adapter](LEGACY_0_3.md) remains documented separately.
The standalone Engine and memory APIs above are unchanged.

## Next steps

- [Writing and connecting memory](MEMORY_GUIDE.md)
- [Retrieval and knowledge](RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence and operations](PERSISTENCE_AND_OPERATIONS.md)
- [Migrating from 0.1.x](MIGRATING_TO_0_2.md)
- [Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md)
- [Complete facade API guide](API_GUIDE.md)
