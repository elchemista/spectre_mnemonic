# Getting started

This guide takes a new application from installation to its first durable
memory and explains the partition model used by every other feature.

## Install the dependency

SpectreMnemonic is distributed from GitHub:

```elixir
def deps do
  [
    {:spectre, "~> 0.3.3"},
    {:spectre_mnemonic, github: "elchemista/spectre_mnemonic", branch: "main"}
  ]
end
```

There is currently no Hex package for SpectreMnemonic.

## Configure identity, JSON, and hot-memory bounds

Every memory record belongs to one application namespace. Choose a stable value
and keep it unchanged across releases. Elixir 1.19 includes the dependency-free
`JSON` module, so it is the smallest default choice:

```elixir
# config/config.exs
config :spectre_mnemonic,
  namespace: "my_app_memory",
  json_library: JSON,
  hot_memory: [
    max_moments_per_scope: 1_000,
    max_moments_per_namespace: 10_000
  ]
```

The namespace prevents another application instance's records from entering
replay or search. A missing namespace fails at the API boundary instead of
silently sharing a default partition.

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

The normal OTP application starts:

- the ETS table owner and active focus;
- stream routing and stream workers;
- the persistence manager and durable search index;
- recall and consolidation workers;
- the progressive-knowledge writer;
- the consolidation scheduler, disabled until configured.

## Understand scopes

A partition is exactly:

```text
{namespace, scope}
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
  scope: scope,
  persist?: true
)

SpectreMnemonic.recall("What was approved?", scope: scope)
```

Omitting `scope:` selects the unscoped partition only. It never means “search
all scopes.” Administrative cross-tenant reads must issue separate explicit
calls and merge their results outside the library.

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
  use Spectre.Stack, id: :my_app

  install Spectre.Mnemonic do
    store MyApp.MemoryStore
    isolate_by [:agent, :subject, :conversation, :flow, :task]
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end
```

Selecting the Stack activates `Spectre.Mnemonic.Memory`. A second
`use Spectre.Mnemonic` is not required.

Spectre's normal memory callbacks then:

1. derive an opaque Mnemonic scope from the declared isolation dimensions;
2. recall memory before the Agent handles the turn;
3. persist a compact logical projection after a turn commits;
4. keep full Results, States, process handles, and adapter handles out of
   durable memory;
5. emit privacy-safe Journal outcomes containing dimension names and status,
   never memory content or subject values.

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
    state: state
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

Mnemonic memory values are never stored in `%Spectre.Run{}`. Recall is resolved
again when a restored Run advances.

### Inspect the compiled installation

```elixir
{:ok, config} = Spectre.Mnemonic.config(MyApp.Agent)
config.store
config.isolate_by
config.options
```

The Stack installation configures the adapter but does not start a second
Mnemonic application or claim separate named processes and ETS tables.

## Next steps

- [Writing and connecting memory](MEMORY_GUIDE.md)
- [Retrieval and knowledge](RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence and operations](PERSISTENCE_AND_OPERATIONS.md)
- [Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md)
- [Complete facade API guide](API_GUIDE.md)
