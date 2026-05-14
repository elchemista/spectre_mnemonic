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
- Optional embedding recall through an adapter or local Model2Vec provider.
- Built-in durable hybrid search over persisted records using BM25-style text
  scoring plus vector/signature reranking when embeddings exist.
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
    {:spectre_mnemonic, "~> 0.1.0"}
  ]
end
```

Start it as an OTP application or under your supervision tree. The default
application starts ETS ownership, persistence, the durable index, stream routing,
active focus, recall, consolidation, and the opt-in consolidation scheduler.

## Quick Start

Use `remember/2` for normal application memory:

```elixir
{:ok, packet} =
  SpectreMnemonic.remember("TODO: implement durable graph search",
    title: "Planner note",
    stream: :planning,
    task_id: "alpha",
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
{:ok, packet} = SpectreMnemonic.recall("how is alpha going?", limit: 5)

packet.moments
packet.active_status
packet.associations
packet.knowledge
```

Use `search/2` when you want active recall plus durable persisted memory:

```elixir
{:ok, results} = SpectreMnemonic.search("durable graph search", limit: 10)

Enum.map(results, &{&1.source, &1.family, &1.id, &1.score})
```

Use `consolidate/1` to promote active memory into durable families:

```elixir
{:ok, knowledge} = SpectreMnemonic.consolidate(min_attention: 1.0)
```

Use `forget/2` to remove active memories and write tombstones:

```elixir
SpectreMnemonic.forget({:task, "alpha"})
SpectreMnemonic.forget("mom_123")
```

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

The deterministic extractor handles names, ISO/month dates, simple events,
emails, ages, numbers, and phone-like values. Phone-like values are redacted by
default. Use:

```elixir
SpectreMnemonic.remember(text, sensitive_numbers: :raw)
SpectreMnemonic.remember(text, sensitive_numbers: :skip)
SpectreMnemonic.remember(text, extract_entities?: false)
```

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

Persistent records are backend-neutral envelopes in families such as:

- `:signals`
- `:moments`
- `:summaries`
- `:categories`
- `:embeddings`
- `:associations`
- `:knowledge`
- `:memory_states`
- `:consolidation_jobs`
- `:semantic_compaction_jobs`
- `:artifacts`
- `:action_recipes`
- `:tombstones`

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

### Compaction

Physical compaction writes snapshots for append-only local files:

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
  observed_at: ~U[...],
  last_verified_at: ~U[...]
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
from the durable persistent-memory families.

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

Configure a custom adapter:

```elixir
config :spectre_mnemonic,
  embedding_adapter: MyApp.EmbeddingAdapter
```

Adapters implement `SpectreMnemonic.Embedding.Adapter.embed/2` and return
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

Downloads are opt-in. For production, pre-populate the cache or pass
`:model_dir`.

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
mix credo --strict
mix dialyzer
mix test
```

## Project Layout

- `lib/spectre_mnemonic.ex` is the public facade.
- `lib/spectre_mnemonic/active/*` owns hot ETS focus, routing, and stream
  workers.
- `lib/spectre_mnemonic/durable/*` owns derived durable search indexes.
- `lib/spectre_mnemonic/governance.ex` owns lifecycle states, provenance, and
  structured fact contradiction logic.
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
