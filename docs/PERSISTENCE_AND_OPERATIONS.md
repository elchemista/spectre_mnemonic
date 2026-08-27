# Persistence and operations

This guide covers durable storage, hybrid search, compaction, scheduling,
exports, logical forgetting, physical erasure, operational limits, evaluation,
and development commands. For controller/processor responsibilities and a
data-subject request runbook, read
[Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md).

## Durable storage

The default backend is an append-only local file store. Configure it on the
Engine so a single operation cannot replace stores or paths:

~~~elixir
{SpectreMnemonic.Engine,
 name: MyApp.Memory,
 storage_id: "my-app-memory",
 namespace: "my_app",
 data_root: "data/memory",
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
        opts: []
      ]
    ]
  ]}
~~~

The Engine injects its resolved data root into built-in File stores. Global
`persistent_memory` configuration remains available to the legacy
DefaultEngine.

Persistence records are backend-neutral envelopes. Known families include:

- signals, moments, summaries, and categories;
- embeddings and associations;
- knowledge, observations, and mental models;
- memory states;
- consolidation and semantic-compaction jobs;
- artifacts and action recipes;
- Episodes;
- tombstones and erasure markers.

The configured stores remain the source of truth. Hot ETS and the durable
search index are rebuildable projections.

### Adapter contract and conformance

Adapters expose a machine-readable
`SpectreMnemonic.Persistence.Store.Contract` covering idempotency and operation
IDs, batch visibility, commit revisions, cursors and pagination, replay fold,
conflict detection, erase semantics, schema versions, health, retry
classification, transactional capability, and maximum batch size.

~~~elixir
{:ok, contract} =
  SpectreMnemonic.Persistence.Store.Adapter.describe(MyApp.Store)

{:ok, report} =
  SpectreMnemonic.Persistence.Store.Conformance.audit(MyApp.Store)
~~~

The bundled Postgres, Mongo, and S3 modules remain explicit non-conformant
placeholders. They must not be treated as complete adapters until they provide
the callbacks and pass the shared behavioural suite.

### Frame safety

Append-only frames are limited to 64 MiB by default. Both stored size and the
expanded size declared by compressed Erlang terms are checked:

~~~elixir
config :spectre_mnemonic,
  max_frame_bytes: 16 * 1024 * 1024
~~~

The same bound protects `active.smem` and `knowledge.smem`. On the next append,
the writer scans framing and CRC, truncates an incomplete crash tail to the last
valid byte, and then resumes the sequence. A complete frame with a bad CRC is
reported as corruption and is never silently truncated. Replay still stops
safely when it encounters invalid input.

Durability defaults to `:always`: appends, temporary snapshots, renames, and
directory metadata are synced before success is returned or recovery copies
are removed. The host can choose a different, explicit trade-off:

~~~elixir
config :spectre_mnemonic, persistence_sync: :always

# Or per built-in file store:
opts: [data_root: "mnemonic_data", sync: :data]
~~~

Supported values are `:always`, `:data`, and `:none`. `:none` only provides the
filesystem/page-cache guarantee and must not be described operationally as
power-loss durability. A bounded `PartitionExecutor` owns the logical mutation;
a bounded `StoreWriter` serializes only the necessary physical file boundary.
There is no VM-global writer and no distributed lock.

Inspect replayed live records:

~~~elixir
{:ok, records} =
  SpectreMnemonic.Persistence.Manager.replay(
    engine_ref: %SpectreMnemonic.Engine.Ref{id: "my-app-memory"},
    scope: {:project, "checkout"}
  )
~~~

Replay folds adapters incrementally, accepts v1 and v2 envelopes, and applies
committed-batch markers, tombstones, erasure generations, partition filters,
and lifecycle visibility. New envelopes are v2 records with operation, commit,
batch, revision, and digest identities.

The primary decides commit. A committed primary with a failed replica returns
`{:ok, %SpectreMnemonic.Persistence.WriteReceipt{repair_required?: true}}` and
enqueues idempotent repair; it does not return an ambiguous error after commit.

## Durable hybrid search

The local durable index is rebuilt from persistent replay. It combines:

- BM25-style text ranking;
- exact term and entity overlap;
- vector cosine similarity;
- binary-signature similarity;
- lifecycle boosts and demotions.

The normal entry point searches both active and durable memory:

~~~elixir
{:ok, results} =
  SpectreMnemonic.search("payment retry decision",
    scope: {:project, "checkout"},
    limit: 10
  )
~~~

Rebuild the derived index after manual store maintenance:

~~~elixir
SpectreMnemonic.Durable.Index.rebuild(
  engine_ref: %SpectreMnemonic.Engine.Ref{id: "my-app-memory"}
)
~~~

Rebuild is normally automatic during startup and configured maintenance.

Documents, postings, document frequencies, lifecycle state, recent candidates,
partition counts, and generation metadata live in unnamed protected ETS tables
owned by the Engine's durable-index process. Search asks that process only for a
bounded candidate snapshot; it never copies the whole corpus to the caller.
Rebuild folds persistent replay directly into a temporary ETS generation,
applies writes that arrived concurrently, and atomically swaps the generation.
Recall, entity resolution, forget planning, and Atlas therefore do not rescan
the append-only file on each hot-path call.

Active Vettore collection handles are also published through protected ETS.
Query embedding, Vettore search, BM25 scoring, and final ranking run in the
requesting process, while index processes coordinate only short mutation,
candidate-snapshot, and generation-swap boundaries.

## Consolidation

consolidate/1 promotes eligible active moments into durable knowledge, expands
selected graph context, records a consolidation job, updates lifecycle states,
and optionally materializes Atlas Episodes.

~~~elixir
{:ok, records} =
  SpectreMnemonic.consolidate(
    scope: {:project, "checkout"},
    min_attention: 1.0,
    graph_depth: 1,
    cluster?: true
  )
~~~

| Option | Purpose |
| --- | --- |
| min_attention | minimum source-moment attention |
| graph_depth | nearby graph depth included in promotion |
| cluster? | materialize Episode clusters after promotion |
| compact? | run configured persistence compaction afterward |
| consolidate_with | one- or two-arity per-call customization |
| consolidation_adapter | application adapter module |

Configure a reusable adapter:

~~~elixir
config :spectre_mnemonic,
  consolidation_adapter: MyApp.MemoryConsolidator
~~~

Adapters receive a populated SpectreMnemonic.Knowledge.Consolidation struct
containing selected moments, associations, graph windows, timestamps, options,
and default durable outputs.

## Physical and semantic compaction

Physical compaction rotates the active segment briefly, builds a framed v2
snapshot with per-frame CRC and a final digest outside the brief rotation and
publication boundaries, then publishes it atomically. It applies and removes
tombstones without blocking append for the whole build phase:

~~~elixir
SpectreMnemonic.Persistence.Manager.compact(mode: :physical)
~~~

Semantic compaction delegates selection or compression to a store or configured
adapter:

~~~elixir
SpectreMnemonic.Persistence.Manager.compact(mode: :semantic)
SpectreMnemonic.Persistence.Manager.compact(mode: :all)
~~~

Configure an adapter and bounds:

~~~elixir
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
~~~

Storage adapters can expose native compaction. Otherwise the manager replays a
bounded selection into SpectreMnemonic.Persistence.Compact.Adapter.compact/2.

## Background maintenance

Each Engine has one supervised scheduler, disabled by default:

~~~elixir
{SpectreMnemonic.Engine,
 # identity options omitted
 scheduler: [
    enabled: true,
    interval_ms: 300_000,
    deadline_ms: 60_000,
    mode: :all,
    min_attention: 1.0,
    stale_after_ms: 30 * 24 * 60 * 60 * 1_000
  ]}
~~~

Depending on its mode, each tick can:

- consolidate active memory;
- decay graph weights unused beyond the configured window;
- mark old unverified facts stale;
- compact durable storage;
- rebuild the derived durable index.

Maintenance enumerates every known `{engine, namespace, scope}` partition instead of
running only against the unscoped partition. Semantic compaction is a no-op
when no semantic adapter is configured, so an `:all` tick does not create an
unbounded stream of empty semantic job records. Overlapping ticks coalesce and
heavy work runs under the Engine's TaskSupervisor with a deadline.

Inspect status:

~~~elixir
SpectreMnemonic.health(MyApp.Memory)
~~~

## Telemetry and diagnostics

Telemetry integration is optional. A host that wants events declares
`{:telemetry, "~> 1.3"}` itself; Mnemonic performs no event dispatch when that
module is absent. Public operation spans use `:start`, `:stop`, and
`:exception` suffixes where applicable.

The event families are:

- `[:spectre_mnemonic, :signal | :remember | :recall, suffix]`;
- `[:spectre_mnemonic, :embedding, suffix]` and
  `[:spectre_mnemonic, :vector, :query, suffix]`;
- active and durable candidate collection or full-scan fallback;
- partition/store wait, primary commit, replica write, and repair attempt;
- replay, durable rebuild, compaction, erasure, maintenance, and secret reveal.

Measurements contain durations and bounded counts. Metadata may contain an
Engine reference, operation ID, store/family identifier, trigger, and outcome;
it never contains the remembered input, recall cue, plaintext, ciphertext, or
memory payload. Use `SpectreMnemonic.health/1` for a content-free current
snapshot and `packet.diagnostics` for per-recall source completeness.

## Logical forgetting and retention

forget/2 suppresses selected memory through lifecycle events and tombstones:

~~~elixir
scope = {:project, "checkout"}

SpectreMnemonic.forget("mom_123", scope: scope)
SpectreMnemonic.forget({:task, "deploy-42"}, scope: scope)
SpectreMnemonic.forget({:stream, :planning}, scope: scope)

SpectreMnemonic.forget(
  fn moment -> :temporary in Map.get(moment.metadata, :tags, []) end,
  scope: scope
)
~~~

Selectors are a memory id, a task tuple, a stream tuple, or a predicate
receiving each scoped moment.

Forgetting cascades through dependent Episodes and membership edges. Forgotten
records are hidden from recall, normal search, Atlas, and logical exports.
Append-only bytes can remain until physical compaction.

Sweep expired validity windows:

~~~elixir
{:ok, count} =
  SpectreMnemonic.sweep_expired(
    scope: {:project, "checkout"},
    now: DateTime.utc_now()
  )
~~~

The returned count includes active-only and durable expired moments.
`valid_until` records do not schedule their own sweep. The host must run this
operation on its retention schedule and separately govern backups, logs,
exports, and processor-held copies.

## Physical partition erasure

erase_partition/1 requires an Engine (or legacy namespace) and an explicit
scope. It never interprets a missing scope as a wildcard:

~~~elixir
{:ok, report} =
  SpectreMnemonic.erase_partition(
    engine: MyApp.Memory,
    scope: {:subject, "alice"},
    sealed: true
  )

report.families
report.hot
report.knowledge_events
report.compaction
report.marker_id
report.crypto_shred
report.already_erased?
~~~

The operation:

1. verifies that every configured store supports physical partition erasure and
   post-erasure verification;
2. replays evicted and active durable records;
3. writes family tombstones;
4. rewrites knowledge.smem;
5. purges hot ETS projections;
6. requests optional crypto-shredding;
7. writes a durable erasure generation marker;
8. closes concurrent hot-write windows with repeated purges;
9. compacts stores in erase mode;
10. replays and verifies that target records do not survive;
11. evicts partition deduplication state and plaintext cache entries.

sealed: true rejects future signals, rich intake, graph links, and durable
writes to the partition. Generation markers also reject stale restored history,
including records with future-skewed timestamps.

### Store requirements

An adapter must expose physical erase and verification capabilities. If any
configured store cannot prove erasure, the operation fails before mutation.
Logical hiding is never reported as successful physical deletion.

The built-in File adapter rewrites the live store and verifies the result. In
erase mode it removes retained previous snapshots and rotated segments for the
whole store so erased bytes cannot survive in crash-recovery copies. Neighbor
partitions remain in the current compacted snapshot but temporarily lose that
redundant history.

Here “physical” means verified absence from files reachable through the
configured adapter after rewrite and unlink. `File.rm/1` is not a promise of
forensic media sanitization on SSDs, copy-on-write filesystems, snapshots, or
backups. Encryption-at-rest, key destruction, storage-provider deletion, and
media disposal remain deployment responsibilities.

Deployments requiring different redundancy semantics should provide a
partition-native adapter.

### Crypto-shredding boundary

The built-in AES-GCM secret adapter does not derive or destroy per-partition
keys, so `report.crypto_shred` is
`%{supported?: false, performed?: false}` by default. It never claims key
destruction that did not occur.

Applications using envelope encryption can implement
SpectreMnemonic.Secrets.Crypto.Adapter.shred/2 to destroy partition key
material. Physical verified store erasure remains mandatory regardless of the
optional crypto result.

### Forget versus erase

| Operation | Scope | Retrieval visibility | Physical bytes | Future writes |
| --- | --- | --- | --- | --- |
| forget/2 | selected id, task, stream, or predicate | hidden | may remain until compaction | allowed |
| sweep_expired/1 | expired moments | hidden | may remain until compaction | allowed |
| erase_partition/1 | entire explicit partition | absent | verified removal for supported stores | optional sealing |

For Spectre-owned Engines, use `Spectre.Mnemonic.erasure_plan/2` and
`erase_instance/2` with the stable `%Spectre.Instance.Ref{}` and named Stack
Runtime. These functions resolve the same core partition and never place the
runtime handle in durable data.

## Export a partition

Export requires the host-selected JSON implementation:

~~~elixir
# Dependency-free on Elixir 1.19:
config :spectre_mnemonic, json_library: JSON

# Or add Jason to the host deps and select it:
config :spectre_mnemonic, json_library: Jason
~~~

The module must provide `decode/1` and either `encode/1` or `encode!/1`.
Missing or unavailable configuration fails before a file is written or
verified.

Write one verified `.mnemonic` file:

~~~elixir
{:ok, report} =
  SpectreMnemonic.export("alice.mnemonic",
    scope: {:subject, "alice"},
    mode: :structure,
    include: :all,
    embeddings?: false,
    active?: true
  )

report.path
report.content_digest
report.counts
report.bytes
report.mode
~~~

| Option | Values |
| --- | --- |
| mode | :structure, :full, or {:redacted, fun} |
| include | :all or nodes, edges, clusters, models, knowledge, governance |
| embeddings? | include vectors and signatures when privacy mode permits |
| active? | merge active projections with durable replay; default true |
| frame_target_bytes | frame chunk target, at least 256 bytes |

structure mode is topology-only. It removes raw memory text, canonical entity
labels, aliases, cluster titles, category labels, arbitrary metadata, vectors,
and secret labels.

`full` mode is the broad subject-access/data-portability projection. Secrets
still never export plaintext or cryptographic material; they expose at most
presence, label, and dates. The host must still establish which data and
context an applicable request requires.

Caller redaction receives each projected record:

~~~elixir
redactor = fn record ->
  record
  |> Map.drop(["input", "summary"])
  |> Map.update("text", nil, fn _ -> "[redacted]" end)
end

SpectreMnemonic.export("alice-redacted.mnemonic",
  scope: {:subject, "alice"},
  mode: {:redacted, redactor}
)
~~~

Active exports fail explicitly when Atlas caps would truncate the projection.

### Read a detached export

~~~elixir
{:ok, decoded} = SpectreMnemonic.Export.read("alice.mnemonic")

decoded.manifest
decoded.nodes
decoded.edges
decoded.clusters
decoded.models
decoded.knowledge
decoded.governance
decoded.trailer
~~~

The reader validates framing, CRC32, gzip bounds, canonical JSON shape, section
order, required fields, partition isolation, privacy invariants, record counts,
and SHA-256 content digest.

### Stream verified frames

~~~elixir
{:ok, frames} = SpectreMnemonic.Export.stream("alice.mnemonic")

Enum.reduce_while(frames, :ok, fn
  {:error, reason}, _acc -> {:halt, {:error, reason}}
  frame, :ok ->
    consume(frame)
    {:cont, :ok}
end)
~~~

The file is verified before the lazy stream is returned. If it changes
afterward, enumeration emits one typed error item and halts.

### Export limits and restore boundary

Chunking bounds each encoded frame, not the writer's total heap. The format-v1
writer materializes the selected partition to deduplicate records, establish
stable ordering, and compute exact counts. Size the exporter for its partition.

read/2 and stream/2 return detached data only. Format version 1 has no import or
live-memory restore operation. Runtime recovery uses persistent-store replay.
Exported copies are host-owned and remain outside erase_partition/1.
The container is integrity-checked, not encrypted; protect it in storage and
transit and delete temporary copies on the host's retention schedule.

The normative contract is [.mnemonic format version 1](MNEMONIC_FORMAT.md).
The operational privacy workflow is
[Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md).

## Evaluation and development

Run the deterministic evaluation harness:

~~~elixir
SpectreMnemonic.Evaluation.run(size: 100)
~~~

It reports recall accuracy, exact-fact recall, and latency. By default the
harness creates a unique `{:evaluation, id}` scope, uses `persist?: false`, and
removes the hot records it created in an `after` block. Pass `scope:` or
`persist?: true` only when an intentionally retained evaluation corpus is
required; durable cleanup then uses normal logical forgetting.

Run the local demonstration:

~~~bash
mix run --no-start example/demo.exs
~~~

Standard checks:

~~~bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test
mix docs --warnings-as-errors
mix hex.audit
~~~

The default suite is offline and excludes model-backed system tests.

Run real local embedding retrieval with ex_fastembed:

~~~bash
MNEMONIC_REAL_EMBEDDING_TESTS=1 MIX_ENV=test \
  mix test test/system/real_embedding_retrieval_test.exs --include real_embedding
~~~

This matrix checks semantic ranking, similarity floors, partition isolation,
Vettore strategies, cross-memory aggregation, and durable-index rebuild.

Run the Spectre Agent end-to-end scenarios:

~~~bash
mix test test/integration/spectre_agent_memory_e2e_test.exs
~~~

The test runs through Spectre.turn/3 and verifies e-mail, reference, question,
cross-conversation, and subject-isolation memory.

Run its real semantic scenario:

~~~bash
MNEMONIC_REAL_EMBEDDING_TESTS=1 MIX_ENV=test \
  mix test test/integration/spectre_agent_memory_e2e_test.exs --only real_embedding
~~~

The downloaded model cache is local-only and ignored by Git.

## Project layout

- lib/spectre_mnemonic.ex — high-level public facade.
- lib/spectre/mnemonic* — Spectre Stack installation and memory adapter.
- lib/spectre_mnemonic/active/* — hot ETS focus, routing, and streams.
- lib/spectre_mnemonic/intake* — rich intake, plugs, extraction, and packets.
- lib/spectre_mnemonic/recall/* — context packets, ranking, and vector index.
- lib/spectre_mnemonic/graph/* — resolver, traversal, and plasticity.
- lib/spectre_mnemonic/durable/* — derived durable search index.
- lib/spectre_mnemonic/persistence/* — stores, records, replay, and compaction.
- lib/spectre_mnemonic/knowledge/* — progressive knowledge and consolidation.
- lib/spectre_mnemonic/export/* — verified export writer and reader.
- lib/spectre_mnemonic/embedding/* — adapters, vectors, quantization, models.

## Related guides

- [Getting started](GETTING_STARTED.md)
- [Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md)
- [Complete facade API guide](API_GUIDE.md)
- [Public API manifest](PUBLIC_API.md)
- [Release checklist](../RELEASE.md)
