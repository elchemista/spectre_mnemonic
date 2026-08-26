# Getting started

This guide takes a new application from installation to its first durable
memory and explains the partition model used by every other feature.

## Install the dependency

SpectreMnemonic is distributed from GitHub:

```elixir
def deps do
  [
    {:spectre_mnemonic, github: "elchemista/spectre_mnemonic", branch: "main"}
  ]
end
```

There is currently no Hex package for SpectreMnemonic.
Spectre `~> 0.3.3` is an optional dependency; add it only for Stack integration.

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

## Spectre Agent integration

Mnemonic can be installed as the memory service in a Spectre Stack:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Mnemonic do
    isolate_by [:instance]
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end

children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.AI,
   name: MyApp.AIRuntime,
   packages: [mnemonic: [data_root: "data/memory"]]},
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]

Spectre.instance(
  MyApp.SpectreSupervisor,
  MyApp.Agent,
  subject,
  stack_runtime: MyApp.AIRuntime
)
```

`Spectre.Stack.Runtime` supervises the same `SpectreMnemonic.Engine` used by a
standalone application. Selecting the Stack activates
`Spectre.Mnemonic.Memory`; a second `use Spectre.Mnemonic` is not required.
The runtime name is resolved for each callback and is never persisted in a Run,
checkpoint, Journal payload, or receipt.

Spectre's normal memory callbacks then:

1. derive an opaque Mnemonic scope from the declared isolation dimensions;
2. recall memory before the Agent handles the turn;
3. persist a compact logical projection after a turn commits;
4. keep full Results, States, process handles, and adapter handles out of
   durable memory;
5. emit privacy-safe Journal outcomes containing dimension names and status,
   never memory content or subject values.

### Instance isolation

`isolate_by: []` remains the historical default and deliberately shares the
unscoped partition among every Agent and Subject using that installation. It is
not changed automatically because doing so would make 0.1.x shared memory
invisible.

`isolate_by [:instance]` is recommended for new installations. It derives the
opaque scope from `{instance_ref.schema_version, instance_ref.key}`. Agent
definition versions and Stack digests do not change that logical identity.
Missing Instance refs fail closed with:

```elixir
{:error, {:mnemonic_isolation_dimension_required, :instance}}
```

### Canonical subject isolation

If `:subject` is present in `isolate_by`, the runtime must supply an explicit
canonical `%Spectre.Subject{}`:

```elixir
subject = Spectre.Subject.new(account.id)

{:ok, memory_opts} =
  Spectre.Mnemonic.Memory.options(MyApp.Agent,
    agent: MyApp.Agent,
    subject: subject,
    input: input,
    state: state,
    stack_runtime: MyApp.AIRuntime
  )
```

The partition uses `Spectre.Subject.key/1`. Mnemonic does not infer identity
from a sender name, phone number, `Input.Source.actor_id`, or conversation id.
Different channel identities share memory only after the Subject Registry links
them and the owning Agent Instance supplies the same canonical Subject.

Missing canonical subjects fail closed with
`:mnemonic_canonical_subject_required`. Scalar identities passed explicitly by
application code are normalized through `Spectre.Subject.new/1`.

### Other isolation dimensions

- `:agent` uses canonical `Spectre.AgentRef`, so two logical Agent instances
  backed by the same module do not share memory accidentally.
- `:conversation` follows the current Run/Input origin. It is not the stable
  persistence identity of the Subject-owned Agent Instance.
- `:flow` and `:task` use the corresponding current runtime context.
- `:instance` uses the stable schema-versioned `Spectre.Instance.Ref` key and
  fails closed when only legacy Session metadata is available.

Mnemonic memory values are never stored in `%Spectre.Run{}`. Recall is resolved
again when a restored Run advances.

### Inspect the compiled installation

```elixir
{:ok, config} = Spectre.Mnemonic.config(MyApp.Agent)
config.store
config.isolate_by
config.options
```

The Stack installation owns one Engine resource. Its default `storage_id` is
derived from `{stack_owner, installation_id}`, not the complete Stack digest,
so a compatible Stack update does not silently select a fresh data directory.

## Next steps

- [Writing and connecting memory](MEMORY_GUIDE.md)
- [Retrieval and knowledge](RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence and operations](PERSISTENCE_AND_OPERATIONS.md)
- [Migrating from 0.1.x](MIGRATING_TO_0_2.md)
- [Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md)
- [Complete facade API guide](API_GUIDE.md)
