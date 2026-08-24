# SpectreMnemonic

SpectreMnemonic is an Elixir memory engine for live applications and agentic
systems. It keeps hot working memory in ETS, links moments into a graph,
persists durable memory through append-only stores, and recalls useful context
with deterministic text matching, graph expansion, optional embeddings, and
durable hybrid search.

It is not a replacement for your application database. It is the memory layer
beside your framework: record what happened, recall nearby context, promote
important moments, track stale or contradicted facts, and keep compact knowledge
available without hydrating every old event.

The supported surface is documented in the
[public API manifest](docs/PUBLIC_API.md).

```elixir
{:ok, memory} =
  SpectreMnemonic.remember("Alice email is alice@example.com",
    stream: :chat,
    kind: :personal_fact,
    persist?: true
  )

{:ok, packet} = SpectreMnemonic.recall("Alice email")
{:ok, results} = SpectreMnemonic.search("Alice email")
{:ok, durable} = SpectreMnemonic.consolidate()
```

## What It Gives You

- `remember/2` for high-level intake: text, maps, parsed documents, chat,
  tasks, research notes, code notes, and tool events.
- `signal/2` for low-level event recording when the caller already knows the
  stream, kind, task, and metadata.
- Active ETS memory for recent moments, task status, graph associations,
  artifacts, secrets, and action recipes.
- Deterministic local recall through keywords, entities, fingerprints, and graph
  expansion, even with no model configured.
- Caller-provided embeddings plus optional adapter or local Model2Vec generation,
  indexed per brain through Vettore.
- Built-in durable hybrid search over persisted records using BM25-style text
  scoring plus vector/signature reranking when embeddings exist.
- Scoped memory with optional `scope`, temporal validity fields, token-budget
  recall, and budgeted retrieval depth.
- Evidence-grounded observations and curated mental models for recall and
  reflection over memory.
- Governance state records: `:candidate`, `:short_term`, `:promoted`,
  `:pinned`, `:stale`, `:contradicted`, and `:forgotten`.
- Structured fact freshness and contradiction tracking for facts such as email,
  phone, age, status, birthday, deadline, and owner.
- Compact progressive knowledge in `knowledge.smem`.
- Encrypted secret memories with authorization-aware reveal.
- Plugs, adapters, and storage backends for framework-specific behavior.

## Installation

Add the dependency:

```elixir
def deps do
  [
    {:spectre, "~> 0.3.3"},
    {:spectre_mnemonic, github: "elchemista/spectre_mnemonic", branch: "main"}
  ]
end
```

Spectre Mnemonic is distributed exclusively from GitHub; there is no Hex
package.

Mnemonic configuration can also be published through an immutable Spectre
Stack definition:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack, id: :my_app

  install Spectre.Mnemonic do
    store MyApp.MemoryStore
    isolate_by [:agent, :subject, :conversation, :flow, :task]
  end
end
```

Selecting that Stack on an Agent activates `Spectre.Mnemonic.Memory`
automatically:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end
```

Spectre's normal memory load/save path now calls Mnemonic recall and remember.
The adapter derives an opaque scope from `isolate_by`, configures the declared
persistent store, and forwards the complete runtime context needed for
agent/subject/conversation/flow/task isolation. It also emits privacy-safe
Journal outcomes containing isolation dimension names, never memory content or
subject values. A second `use Spectre.Mnemonic` is not required.

When `isolate_by` includes `:subject`, the integration requires the explicit
canonical `%Spectre.Subject{}` supplied by an Agent Instance:

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

The resulting memory partition uses `Spectre.Subject.key/1`. Mnemonic never
falls back to `Input.Source.actor_id`, a sender name, phone number, or
conversation id as cross-channel identity. Different channel principals share
memory only after the core Subject Registry explicitly links them and the
owning Instance supplies the same canonical Subject. Calls without a Subject
fail closed with `:mnemonic_canonical_subject_required`; explicit scalar
application identities are normalized through `Spectre.Subject.new/1` for
caller compatibility.

Instance calls also partition the `:agent` dimension by canonical
`Spectre.AgentRef`, so two logical Agents backed by the same module cannot
share memory accidentally. The `:conversation` dimension follows the current
origin supplied by the Run/Input, not the stable persistence key of the
Subject-owned Instance.

Mnemonic values and runtime handles are never stored in `%Spectre.Run{}`.
Recall is resolved again whenever a restored Run advances. After the core
commits a turn, the adapter's `remember/4` callback writes a compact logical
projection with `persist?: true`; full Result, State, process, and adapter
handles remain outside durable memory records.

The installation does not start or claim the legacy Mnemonic application,
named processes, or ETS tables for that Stack. Those remain explicitly
supervised runtime infrastructure until they can be isolated per Stack.

Start it as an OTP application or under your supervision tree. The default
application starts ETS ownership, persistence, the durable index, stream routing,
active focus, recall, consolidation, and the opt-in consolidation scheduler.

A stable namespace is mandatory and must not change across deploys. It prevents
records from another application instance from entering replay or search:

```elixir
config :spectre_mnemonic,
  namespace: "my_app_memory",
  hot_memory: [
    max_moments_per_scope: 1_000,
    max_moments_per_namespace: 10_000
  ]
```

## Quick Start

Use `remember/2` for normal application memory:

```elixir
{:ok, packet} =
  SpectreMnemonic.remember("TODO: implement durable graph search",
    title: "Planner note",
    stream: :planning,
    task_id: "alpha",
    scope: {:project, "alpha"},
    occurred_at: ~U[2026-05-30 10:00:00Z],
    metadata: %{source: :agent},
    persist?: true
  )

packet.root
packet.chunks
packet.summaries
packet.categories
packet.associations
```

Use `recall/2` for active context:

```elixir
{:ok, packet} =
  SpectreMnemonic.recall("how is alpha going?",
    scope: {:project, "alpha"},
    max_tokens: 2_000,
    budget: :mid
  )

packet.moments
packet.observations
packet.mental_models
packet.active_status
packet.associations
packet.knowledge
```

`max_tokens` is a best-effort packet budget. Recall may include one oversized
primary evidence item when excluding it would make the packet empty.
`min_vector_similarity` can reject weak semantic candidates before fusion;
it accepts a cosine threshold from `0.0` to `1.0`:

```elixir
SpectreMnemonic.recall("how is alpha going?",
  scope: {:project, "alpha"},
  min_vector_similarity: 0.55,
  graph_depth: 2,
  max_graph_nodes: 200
)
```

Use `search/2` when you want active recall plus durable persisted memory:

```elixir
{:ok, results} = SpectreMnemonic.search("durable graph search", limit: 10)

Enum.map(results, &{&1.source, &1.family, &1.id, &1.score})
```

Every item is a `%SpectreMnemonic.SearchResult{}`. Recall builds one
`%SpectreMnemonic.QueryContext{}` per request, computes its embedding once, and
reuses it across active and durable ranking.

Use `consolidate/1` to promote active memory into durable families:

```elixir
{:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: 1.0)
```

Use `forget/2` to remove active memories and write tombstones:

```elixir
SpectreMnemonic.forget({:task, "alpha"}, scope: {:project, "alpha"})
SpectreMnemonic.forget("mom_123", scope: {:project, "alpha"})
```

## Memory Map, Export, and Erasure

One `{namespace, scope}` partition is one sealed brain. Entity extraction reuses
the partition's canonical entity node, recall traverses weighted associations,
and consolidation materializes deterministic Episode clusters.

Inspect the map without a model:

```elixir
{:ok, atlas} = SpectreMnemonic.atlas(scope: {:subject, "acme/alice"})

atlas.clusters
atlas.stats.top_hubs
atlas.stats.orphan_ratio
```

Ask recall to explain its graph path:

```elixir
{:ok, packet} =
  SpectreMnemonic.recall("why was deploy moved?",
    scope: {:subject, "acme/alice"},
    trace: true
  )

packet.trace
```

Entity merges are append-only and reversible. `merge_entities/3` writes a
non-traversable `:same_as` edge and redirects exact resolution to the winner;
`unmerge_entities/3` tombstones that edge and restores the loser's canonical
aliases without rewriting old memory records.

Export exactly one partition. `:structure` is the default and contains topology
without raw memory text, entity aliases, canonical labels, cluster titles, or
secret labels. `:full` is the subject-access/data-portability representation.
Secrets expose at most presence, label, and dates; structure mode omits the
label as well.

```elixir
{:ok, report} =
  SpectreMnemonic.export("acme_alice.mnemonic",
    scope: {:subject, "acme/alice"},
    mode: :structure
  )

{:ok, export} = SpectreMnemonic.Export.read("acme_alice.mnemonic")
report.content_digest == export.trailer["content_digest"]
```

The normative container contract is
[`docs/MNEMONIC_FORMAT.md`](docs/MNEMONIC_FORMAT.md), with a machine-readable
schema in
[`priv/mnemonic_schema_v1.json`](priv/mnemonic_schema_v1.json). Large sections
are split into bounded consecutive frames; `SpectreMnemonic.Export.stream/2`
verifies the file before exposing a lazy frame stream. If the file changes
after verification, the stream emits one typed `{:error, reason}` item and
halts. Active exports fail explicitly if Atlas bounds would truncate their
projection.

`forget/2` suppresses selected memory from retrieval and records its lifecycle;
it is not physical erasure. Its records and dependent episodes are absent from
logical exports even though append-only bytes can remain until compaction.
`erase_partition/1` destroys one complete partition and therefore requires both
namespace and scope explicitly:

```elixir
{:ok, report} =
  SpectreMnemonic.erase_partition(
    namespace: "my_app_memory",
    scope: {:subject, "acme/alice"},
    sealed: true
  )

report.compaction
#=> :erased
```

Erasure enumerates durable records (including records evicted from bounded hot
memory), tombstones every family, rewrites `knowledge.smem`, purges ETS, invokes
optional adapter crypto-shredding, removes retained file-store snapshots and
segments, physically replays the compacted store as a post-condition, and keeps
a durable generation marker that blocks stale-history resurrection even when a
restored record carries a future timestamp. Every configured store must expose
physical partition erasure and verification capabilities or the operation
fails before mutation. The progressive
knowledge log receives its own erasure compaction marker, so stale events do not
reappear through that path either.
`sealed: true` also refuses future writes to that partition. Exported files are
host-owned copies and remain outside runtime erasure.

For the append-only file adapter, erase-mode pruning is store-global: retained
previous snapshots and rotated compacted segments are removed for the whole
store so erased bytes cannot survive in recovery copies. Neighbor partitions
remain in the current compacted snapshot, but temporarily lose that redundant
recovery history. Deployments that require different redundancy semantics
should use a store adapter with partition-native physical erasure.

### Reading versus restoring an export

`SpectreMnemonic.Export.read/2` fully decodes and verifies a `.mnemonic` file;
`SpectreMnemonic.Export.stream/2` exposes the same verified frames lazily. Both
APIs are read-only: they return a detached export projection and never insert,
replace, or merge records in active ETS memory or a durable store.

Format version 1 does not define an import/restore operation. Reading a valid
file is therefore not a memory round trip. Runtime recovery uses the configured
persistent-store replay path. A future `.mnemonic` importer will need an
explicit API and conflict, idempotency, tombstone, governance, and partition
rules before it can safely rehydrate live memory.

## Remember Plug Pipeline

`remember/2` can run a composable plug pipeline before normal intake. This is
the first extension point to reach for when SpectreMnemonic is embedded inside a
larger framework.

Use plugs for framework-specific routing, classification, metadata,
summarization, filtering, compression, secret detection, or replacing intake
with a final custom packet.

Configure global plugs:

```elixir
config :spectre_mnemonic,
  plugs: [
    MyApp.Memory.ProjectPlug,
    {MyApp.Memory.SecretRouterPlug, providers: [:github, :stripe]}
  ]
```

Add per-call plugs:

```elixir
SpectreMnemonic.remember("sk_live_...",
  task_id: "chat-123",
  plugs: [MyApp.Memory.SessionPlug],
  secret_key: secret_key_32_bytes
)
```

Implement a plug:

```elixir
defmodule MyApp.Memory.ProjectPlug do
  @behaviour SpectreMnemonic.Intake.Plug

  @impl true
  def call(memory, _opts) do
    %{
      memory
      | metadata: Map.put(memory.metadata, :project, :billing),
        tags: [:billing | memory.tags]
    }
  end
end
```

Plugs may continue, halt, or return a final packet, moment, secret, or signal.
Low-level `signal/2` does not run remember plugs.

## Secret Memory

Secret memory is first-class because agents and live apps often see tokens,
keys, passwords, credentials, or private notes while doing real work.

Secrets are stored as encrypted `%SpectreMnemonic.Memory.Secret{}` structs. The
indexed text is redacted, and plaintext is encrypted before it enters active ETS
or durable persistence.

Recommended flow:

1. A remember plug detects the secret.
2. The plug sets `memory.secret? = true` and `memory.label`.
3. SpectreMnemonic encrypts the original text.
4. Recall finds the redacted secret by label and metadata.
5. Reveal requires application authorization.

Low-level explicit secret storage:

```elixir
{:ok, %{moment: secret}} =
  SpectreMnemonic.signal("github_pat_...",
    secret?: true,
    label: "GitHub token",
    secret_key: secret_key_32_bytes
  )

secret.text
#=> "secret: GitHub token"
```

Configure key access:

```elixir
config :spectre_mnemonic,
  secret_key_fun: fn -> MyApp.Keys.memory_secret_key() end
```

Configure authorization:

```elixir
config :spectre_mnemonic,
  secret_authorization_adapter: MyApp.SecretAuthorization
```

Reveal:

```elixir
{:ok, revealed} =
  SpectreMnemonic.reveal(secret,
    secret_key: secret_key_32_bytes,
    authorization_adapter: MyApp.SecretAuthorization,
    authorization_context: %{user_id: current_user.id}
  )
```

If authorization is denied or missing, recall still succeeds and returns the
locked redacted secret.

## Core Concepts

### Active Memory

Active memory is the hot working set in ETS. It stores signals, moments,
associations, artifacts, action recipes, attention, and task status.

`signal/2` writes one moment directly:

```elixir
{:ok, %{moment: moment}} =
  SpectreMnemonic.signal("implemented disk replay checksum",
    stream: :task_execution,
    task_id: "alpha",
    kind: :task_execution,
    persist?: true,
    metadata: %{source: :agent}
  )
```

### Intake Memory

`remember/2` is the higher-level intake path. It normalizes input, creates a
root moment, chunks long text, creates summaries and categories, extracts an
entity timeline graph, and links the graph with typed associations.

Cross-memory aggregation is partition-local and bounded. Tune it with
`cross_memory_similarity_threshold` (`0.0..1.0`) and
`max_cross_memory_edges`, or disable it with `cross_memory?: false`.

The deterministic extractor handles names, ISO/month dates, simple events,
emails, ages, numbers, and phone-like values. Phone-like values are redacted by
default. Use:

```elixir
SpectreMnemonic.remember(text, sensitive_numbers: :raw)
SpectreMnemonic.remember(text, sensitive_numbers: :skip)
SpectreMnemonic.remember(text, extract_entities?: false)
```

Memory can be scoped without changing the existing stream/task model. A scope is
caller-owned data, such as a user, agent, tenant, or project tuple. Scoped recall
only searches matching memory. Omitting `scope:` searches only the unscoped
partition. Every public operation accepts exactly one scope; administrative
cross-tenant reads must issue separate, explicitly scoped calls and merge them
outside the library.

```elixir
SpectreMnemonic.remember("Payment retry policy is stable",
  scope: {:tenant, "acme"},
  mission: :code_agent,
  extraction_mode: :concise,
  occurred_at: ~U[2026-05-01 12:00:00Z],
  valid_from: ~U[2026-05-01 00:00:00Z],
  persist?: true
)

SpectreMnemonic.recall("payment retry",
  scope: {:tenant, "acme"},
  valid_at: ~U[2026-05-30 00:00:00Z]
)
```

`mission:` is metadata by default. To let a mission affect intake retention,
add the opt-in mission policy plug:

```elixir
SpectreMnemonic.remember("TODO fix API retry contract",
  mission: :code_agent,
  plugs: [SpectreMnemonic.Intake.MissionPolicy]
)
```

The built-in `:code_agent` policy drops low-value conversational filler and
prioritizes technical decisions, bugs, API contracts, constraints, TODOs, user
preferences, and project state.

Temporal fields separate when something happened from when SpectreMnemonic
learned it:

- `:occurred_at` - when the event or fact happened.
- `:observed_at` - when memory observed or learned it.
- `:last_verified_at` - when evidence was last verified.
- `:valid_from` and `:valid_until` - when a fact/model should be treated as
  true.

For richer extraction, configure an adapter:

```elixir
config :spectre_mnemonic,
  entity_extraction_adapter: MyApp.MemoryExtractor
```

Adapters implement `SpectreMnemonic.Intake.Extraction.Adapter` and return graph
fragments with `entities`, `events`, `times`, `values`, and `relations`.

### Graph Associations

Memories can be linked manually:

```elixir
SpectreMnemonic.link(source_id, :supported_by, target_id, weight: 0.8)
```

Recall expands through graph associations, so a task can bring in related
research, code notes, artifacts, and action recipes.

## Durable Persistence And Search

The default durable backend is an append-only local file store. Configure it
explicitly when you want a custom data root:

```elixir
config :spectre_mnemonic,
  persistent_memory: [
    write_mode: :all,
    read_mode: :smart,
    failure_mode: :strict,
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

Persistent records are backend-neutral envelopes in families such as:

- `:signals`
- `:moments`
- `:summaries`
- `:categories`
- `:embeddings`
- `:associations`
- `:knowledge`
- `:observations`
- `:mental_models`
- `:memory_states`
- `:consolidation_jobs`
- `:semantic_compaction_jobs`
- `:artifacts`
- `:action_recipes`
- `:tombstones`

Append-only payloads are bounded to 64 MiB by default. Both the stored size and
the expanded size declared by compressed Erlang terms are checked before
decoding. Applications that need a different bound can configure it explicitly:

```elixir
config :spectre_mnemonic,
  max_frame_bytes: 16 * 1024 * 1024
```

The same bound protects `active.smem` and `knowledge.smem`.

`SpectreMnemonic.Persistence.Manager.replay/1` replays durable envelopes and
applies tombstones.

### Built-in Durable Hybrid Search

SpectreMnemonic keeps a rebuildable local durable index derived from replayed
persistent records. The append-only store remains the source of truth.

The durable index scores with:

- BM25-style full-text scoring
- exact term overlap
- entity overlap
- vector cosine and binary-signature similarity when embeddings exist
- lifecycle boosts and demotions from `:memory_states`

Default visibility:

- `:forgotten` and `:contradicted` are hidden
- `:stale` is demoted
- `:promoted` is boosted
- `:pinned` is strongly boosted

The public entrypoint stays simple:

```elixir
{:ok, results} = SpectreMnemonic.search("payment retry decision", limit: 10)
```

Rebuild the derived durable index if you manually changed durable storage:

```elixir
SpectreMnemonic.Durable.Index.rebuild()
```

### Observations, Mental Models, And Reflection

Observations are consolidated beliefs built from existing moments. Fact
observations still come from governance facts, while deterministic V1 extraction
also recognizes preferences, decisions, patterns, and project state. Observation
type is stored in metadata as `:observation_type` so old `%Observation{}`
records continue to work.

```elixir
{:ok, observations} =
  SpectreMnemonic.consolidate_observations(scope: {:project, "alpha"})

{:ok, matches} =
  SpectreMnemonic.search_observations("payment retry",
    scope: {:project, "alpha"}
  )

{:ok, verified} =
  SpectreMnemonic.verify_observation(hd(observations),
    source_id: "mom_123",
    relation: :supports
  )
```

Mental models are curated stable answers for recurring queries. They are stored
through the same persistence and durable search machinery as other memory.

```elixir
{:ok, model} =
  SpectreMnemonic.put_mental_model(%{
    title: "Payment Retry Policy",
    query: "payment retry",
    answer: "Use bounded retries with idempotency keys.",
    scope: {:project, "alpha"},
    source_ids: ["mom_123"]
  })

{:ok, models} =
  SpectreMnemonic.search_mental_models("payment retry",
    scope: {:project, "alpha"}
  )
```

`reflect/2` gathers mental models first, ranked observations second, then raw
recall evidence. Observation evidence is ranked as decisions, preferences,
project state, patterns, then facts. It always returns structured evidence;
natural-language response generation belongs to the calling Spectre layer.
`max_tokens` is forwarded to recall as a best-effort packet budget and may
include one oversized primary evidence item when excluding it would make the
packet empty.

```elixir
{:ok, packet} =
  SpectreMnemonic.reflect("What is the payment retry policy?",
    scope: {:project, "alpha"},
    max_tokens: 4_096
  )

packet.mental_models
packet.observations
packet.raw_memories
packet.evidence
packet.citations
```

### Compaction

Physical compaction writes an atomic live-record snapshot, applies tombstones,
rotates `active.smem`, and replays the snapshot before the new active segment:

```elixir
SpectreMnemonic.Persistence.Manager.compact(mode: :physical)
```

Semantic compaction asks a store or adapter to create compact records and
tombstones:

```elixir
SpectreMnemonic.Persistence.Manager.compact(mode: :semantic)
SpectreMnemonic.Persistence.Manager.compact(mode: :all)
```

Configure a semantic compaction adapter when your application wants custom,
LLM-backed, or database-native compaction:

```elixir
config :spectre_mnemonic,
  persistent_memory: [
    semantic_compact_adapter: MyApp.PersistentCompactAdapter,
    semantic_compact_families: [
      :moments,
      :knowledge,
      :summaries,
      :categories,
      :associations,
      :memory_states
    ],
    semantic_compact_limit: 1_000
  ]
```

## Governance, Freshness, And Contradictions

Governance is stored as append-only `:memory_states` records so existing memory
structs remain backward compatible.

Lifecycle states:

```elixir
[:candidate, :short_term, :promoted, :pinned, :stale, :contradicted, :forgotten]
```

When a persisted moment is observed, SpectreMnemonic writes a lifecycle state.
Consolidation promotes selected moments. Forgetting writes `:forgotten`.

Pin important memories:

```elixir
SpectreMnemonic.signal("Payment retry policy is stable",
  persist?: true,
  memory_state: :pinned
)
```

Inspect state:

```elixir
SpectreMnemonic.Governance.state_for("mom_123")
```

### Structured Fact Upserts

SpectreMnemonic detects simple entity facts such as:

```text
Alice email is alice@example.com
Deploy deadline is 2026-06-01
Task42 status is blocked
```

The upsert key is `{normalized_subject, attribute}`. A newer conflicting value
marks the older fact `:contradicted` and promotes the newer fact.

```elixir
{:ok, %{moment: old}} =
  SpectreMnemonic.signal("Alice email is old@example.com", persist?: true)

{:ok, %{moment: new}} =
  SpectreMnemonic.signal("Alice email is new@example.com", persist?: true)

SpectreMnemonic.Governance.state_for(old.id)
#=> :contradicted

SpectreMnemonic.Governance.state_for(new.id)
#=> :promoted
```

Pinned facts are not replaced automatically.

### Provenance

Generated and persisted records carry provenance in `metadata.provenance`:

```elixir
%{
  source_ids: ["mom_123"],
  source_span: nil,
  provider: :consolidator,
  confidence: 1.0,
  occurred_at: ~U[...],
  observed_at: ~U[...],
  last_verified_at: ~U[...],
  valid_from: ~U[...],
  valid_until: ~U[...]
}
```

Use provenance to explain why a recalled fact exists and whether it was
generated, extracted, verified, or compacted.

## Background Consolidation Scheduler

The scheduler is supervised but disabled by default. Enable it through config:

```elixir
config :spectre_mnemonic,
  consolidation_scheduler: [
    enabled: true,
    interval_ms: 300_000,
    mode: :all,
    min_attention: 1.0,
    stale_after_ms: 30 * 24 * 60 * 60 * 1_000
  ]
```

Each tick can:

- run consolidation
- run freshness decay
- mark old unverified facts `:stale`
- compact persistent memory
- rebuild the durable search index

Check status:

```elixir
SpectreMnemonic.ConsolidationScheduler.status()
```

## Progressive Knowledge

`knowledge.smem` is a compact append-only knowledge log stored at
`data_root/knowledge/knowledge.smem`. It is separate from active ETS memory and
from the durable persistent-memory families. Writes and replacements are
serialized through one supervised writer and every event is namespace/scope
filtered.

Supported event types:

- `:summary`
- `:skill`
- `:latest_ingestion`
- `:fact`
- `:procedure`
- `:compaction_marker`

Append compact events:

```elixir
SpectreMnemonic.Knowledge.Base.append(%{
  type: :skill,
  name: "Replay durable storage",
  text: "Use SpectreMnemonic.Persistence.Manager.replay/1 to inspect records.",
  metadata: %{attention: 2.0}
})
```

Teach a reusable skill:

```elixir
{:ok, learned} =
  SpectreMnemonic.learn("""
  Debug local replay
  - inspect active.smem
  - check tombstones
  - compare replayed ids
  """)

learned.event.name
learned.event.steps
```

Search compact knowledge without loading the whole packet:

```elixir
{:ok, matches} = SpectreMnemonic.search_knowledge("replay storage", limit: 5)
```

Load a budgeted packet:

```elixir
{:ok, knowledge} =
  SpectreMnemonic.load_knowledge(
    max_loaded_bytes: 8_000,
    max_skills: 10,
    max_latest_ingestions: 10
  )
```

Compact progressive knowledge:

```elixir
SpectreMnemonic.compact_knowledge()
```

Configure a custom compact adapter:

```elixir
config :spectre_mnemonic,
  compact_adapter: MyApp.KnowledgeCompactAdapter
```

## Embeddings

Embeddings are optional. Without an adapter, recall and search still work
through text, fingerprints, graph associations, and durable BM25-style scoring.

If your application already computes an embedding, attach it directly to a
signal or to the root memory created by `remember/2`:

```elixir
SpectreMnemonic.signal("opaque event",
  scope: {:subject, "alice"},
  embedding: [0.12, -0.44, 0.91]
)

SpectreMnemonic.remember("a longer memory",
  scope: {:subject, "alice"},
  embedding: %{
    vector: [0.12, -0.44, 0.91],
    metadata: %{model: "my-embedding-model", version: 3}
  }
)
```

The `vector: [...]` shorthand is also accepted. Caller-provided vectors take
priority over configured providers, are normalized into the internal float32
form, and receive a compact binary signature automatically. Invalid vectors do
not abort ingestion: the memory remains available to text and graph recall.
Malformed, non-finite, empty, and out-of-range float32 vectors are rejected at
this boundary instead of entering the index.

Configure a custom adapter:

```elixir
config :spectre_mnemonic,
  embedding_adapter: MyApp.EmbeddingAdapter
```

Adapters implement `c:SpectreMnemonic.Embedding.Adapter.embed/2` and return
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

Active semantic recall is indexed by Vettore. Mnemonic creates one collection
per `{namespace, scope}` partition, so approximate search never retrieves from
another brain and then filters the result afterward. The default hybrid path
combines HNSW candidates, quantized candidates, and exact reranking; if an index
cannot be created or queried, recall falls back to deterministic ETS scoring.

```elixir
config :spectre_mnemonic,
  embedding: [
    index: [
      backend: :vettore,
      vettore_index: :hnsw,
      strategy: :hybrid,
      vettore_index_options: [
        m: 16,
        m0: 32,
        ef_construction: 100,
        ef_search: 64
      ]
    ]
  ]
```

Downloads are opt-in. For production, pre-populate the cache or pass
`:model_dir`. Downloaded files are written atomically and optional SHA-256
checksums are verified before installation. Computed cache directories include
a short digest of the complete model identifier, so identifiers that sanitize
to the same readable name still remain isolated.

Consolidation does not re-embed text. It copies the `vector`,
`binary_signature`, and `embedding` already stored on each moment.

## Action Recipes

Memories and artifacts can carry inert Action Language recipes. SpectreMnemonic
stores and recalls these recipes as data only. It does not execute them.

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

Execution is delegated only when you configure an adapter:

```elixir
config :spectre_mnemonic,
  action_runtime_adapter: MyApp.KineticRuntime
```

## Runnable Example

The `example/` folder contains a local demo:

- parses `test.txt`, `tasks.txt`, and `chat.txt`
- writes a tiny local Model2Vec fixture
- remembers fixture events in parallel
- creates chunks, summaries, categories, extraction nodes, and graph edges
- persists active and consolidated records to append-only local storage
- demonstrates governed facts, contradiction, pinned/stale states, and durable
  hybrid search
- writes compact progressive knowledge
- registers an artifact
- runs replay, search, compaction, scheduler status, and evaluation output

Run it:

```bash
mix run example/demo.exs
```

Expected output includes lines like:

```text
model        Smoke test vector_dims=4 signature_bytes=1
remembered   ... chunks=1 summaries=2 categories=... edges=...
governance   old=.../contradicted new=.../promoted pinned=.../pinned stale=.../stale
hybrid       source=persistent family=moments state=promoted score=...
knowledge    search "durable replay storage" -> ... compact matches
replay       Loaded ... records from .../example/mnemonic_data/segments/active.smem
compact      example_file snapshot=.../example/mnemonic_data/snapshots/snapshot-...
eval         size=6 recall_accuracy=... exact_fact_recall=... latency_ms=...
```

Generated runtime data goes under `example/mnemonic_data/`.

## Evaluation And Development

Run the deterministic evaluation harness from IEx or your own test code:

```elixir
SpectreMnemonic.Evaluation.run(size: 100)
```

It reports:

- recall accuracy
- exact fact recall
- latency in milliseconds

For development:

```bash
mix format
mix credo
mix dialyzer
mix test
```

The default suite is offline and excludes model-backed system tests. Run the
real local embedding and retrieval matrix explicitly with:

```bash
MNEMONIC_REAL_EMBEDDING_TESTS=1 MIX_ENV=test \
  mix test test/system/real_embedding_retrieval_test.exs --include real_embedding
```

This opt-in suite uses `ex_fastembed` with a local BGE model and verifies real
semantic ranking, similarity floors, partition isolation, Vettore strategies,
cross-memory aggregation, and durable-index rebuilds. The downloaded model
cache is local-only and ignored by Git.

### Spectre agent memory end-to-end

The integration suite includes a real Spectre `0.3.3` Agent and Stack that run
through the public `Spectre.turn/3` boundary. Consecutive turns let the runtime
recall and persist Mnemonic memory normally; the test never injects a prepared
memory packet. It verifies exact answers for an email address, a deployment
reference and owner, a previously asked question, cross-conversation recall,
and subject isolation.

The responder is deliberately deterministic and builds its answers only from
the `%SpectreMnemonic.Recall.Packet{}` supplied by the runtime. This keeps the
assertions stable without a remote language model while still exercising the
real Agent, turn lifecycle, memory adapter, persistence callback, and recall
path.

Run the offline scenarios with:

```bash
mix test test/integration/spectre_agent_memory_e2e_test.exs
```

The same file contains an opt-in semantic scenario. It uses `ex_fastembed`
locally and proves that the Agent retrieves the email when the follow-up has no
lexical overlap with the remembered text:

```bash
MNEMONIC_REAL_EMBEDDING_TESTS=1 MIX_ENV=test \
  mix test test/integration/spectre_agent_memory_e2e_test.exs --only real_embedding
```

## Project Layout

- `lib/spectre_mnemonic.ex` is the public facade.
- `lib/spectre_mnemonic/active/*` owns hot ETS focus, routing, and stream
  workers.
- `lib/spectre_mnemonic/durable/*` owns derived durable search indexes.
- `lib/spectre_mnemonic/governance.ex` owns lifecycle states, provenance, and
  structured fact contradiction logic.
- `lib/spectre_mnemonic/observations.ex` and
  `lib/spectre_mnemonic/mental_models.ex` own evidence-grounded observations
  and curated mental models.
- `lib/spectre_mnemonic/reflection*` builds structured, source-linked reflection
  evidence packets.
- `lib/spectre_mnemonic/consolidation_scheduler.ex` owns opt-in background
  consolidation and freshness decay.
- `lib/spectre_mnemonic/intake*` powers `remember/2`, plugs, extraction, and
  intake packets.
- `lib/spectre_mnemonic/recall/*` builds recall packets, cues, fingerprints,
  and active embedding indexes.
- `lib/spectre_mnemonic/knowledge/*` loads `knowledge.smem`, compacts
  progressive knowledge, and consolidates active graph memory into durable
  families.
- `lib/spectre_mnemonic/persistence/*` coordinates durable stores, records,
  codecs, compaction, and storage behaviours.
- `lib/spectre_mnemonic/embedding/*` contains embedding adapters, vector math,
  binary quantization, and Model2Vec helpers.
- `lib/spectre_mnemonic/actions/*` delegates optional Action Language analysis
  and execution to an explicitly configured runtime adapter.
