# Changelog

All notable changes to Spectre Mnemonic are documented in this file.

The current package and public API version is `0.2.0`. The numbered sections
below record internal development milestones; they are not published package
release declarations.

## [0.2.0] - 2026-08-26

### Highlights

- Introduced the supervised `SpectreMnemonic.Engine` as the single core for
  standalone and Spectre Stack usage, with stable `Engine.Ref`, `storage_id`,
  per-Engine configuration, health, scheduler, stores, persistence runtime,
  durable/vector indexes, projection shards, and bounded queues.
- Made Spectre optional and added a real minimal-consumer CI gate that compiles
  and runs without Spectre or a transitive JSON dependency. The OTP application
  no longer requires a global namespace; legacy configuration starts the
  compatible DefaultEngine.
- Added multi-Engine isolation in one VM and documented the explicit
  single-node/one-writer-per-`storage_id` deployment contract.
- Removed `PathLock`. Partition executors now own mutation lifetimes,
  generation-fenced erasure, deadlines, cancellation, bounded admission, and
  atomic batch visibility; store writers serialize only physical boundaries.
- Added candidate-first projection shards with unnamed protected ETS tables,
  bounded lexical/entity/stream/task/temporal/vector candidates, small-scope
  brute-force fallback, recall diagnostics, and strict/available consistency.
- Added record schema v2, operation and commit identities, write receipts,
  primary-authoritative commit semantics, durable repair jobs, streaming
  replay, framed v2 snapshots, and rotate/build/commit compaction while keeping
  v1 read compatibility.
- Replaced the durable corpus maps with unnamed protected ETS documents,
  postings, document frequencies, lifecycle state, recent candidates, and
  generation metadata. Rebuild and physical snapshot publication now fold and
  write records incrementally without materializing the live corpus.
- Added explicit embedding-space identity, byte and queue quotas, pinned-memory
  accounting, per-Engine knowledge projection, coalesced maintenance, secret
  key/crypto/AAD versions, scoped reveal helpers, and truthful crypto-shred
  reports.
- Added optional, content-free Telemetry spans and events for public memory
  operations, candidate collection, embeddings, vector queries, bounded queue
  waits, writes, repair, replay, rebuild, compaction, erasure, secret reveal,
  and maintenance.
- Added the persistence adapter Contract and structural Conformance audit.
  Postgres, Mongo, and S3 remain explicitly non-conformant placeholders.
- Added `:instance` as an opt-in Spectre isolation dimension. The historical
  `isolate_by: []` shared scope remains unchanged, while missing Instance refs
  fail closed with the dimension-specific error.
- Completed the coordinated Spectre runtime integration: a named Stack Runtime
  supervises the Engine resource, resource resolution is restart-safe and
  cached, and generic package-data erasure includes Mnemonic before checkpoint
  deletion.

### Migration

- Configure `config :spectre_mnemonic, json_library: JSON` before using
  `.mnemonic` export/read or local Model2Vec. Applications choosing Jason must
  add `{:jason, "~> 1.4"}` directly and set `json_library: Jason`.
- Applications that require complete Hugging Face tokenization for local
  Model2Vec must declare `{:tokenizers, "~> 0.5"}`. The provider otherwise uses
  its bounded vocabulary fallback.

### Added

- Added a configurable `:json_library` boundary supporting Elixir's built-in
  `JSON`, Jason, and compatible host-owned adapters, with explicit
  configuration and capability errors.
- Added Vettore 0.3.5 CPU/GPU and Flat-index policy integration tests, plus
  coverage for runtime-only Nx interoperability.
- Added a privacy and GDPR operations guide covering responsibility boundaries,
  minimisation, retention, access, rectification, erasure, processor copies,
  and automated-decision limitations.
- Added a release checklist covering version alignment, optional dependency
  consumers, NIF distribution, documentation, security, and privacy gates.
- Added opt-in `ex_fastembed` system tests with a real local BGE model covering
  semantic top-result accuracy, Vettore strategies, similarity filtering,
  partition isolation, graph aggregation, and durable rebuilds.
- Added broad `.mnemonic`, graph, aggregation, entity-resolution, traversal,
  Atlas, plasticity, and parameter-conformance test matrices.
- Added a Spectre `0.3.3` Agent end-to-end test covering automatic turn
  persistence, cross-conversation recall, exact email/reference/question
  answers, subject isolation, and real local semantic retrieval.

### Changed

- Replaced Router/StreamServer/Focus/Recall/Consolidator call chains with
  caller-owned work and partition-local locks. Removed per-stream processes and
  their unused ETS registry; persistence remains serialized only at the writer
  boundary.
- Moved Vettore lookup, query embedding, BM25 scoring, recall ranking, and
  consolidation work out of coordinator GenServers. Active collection handles
  are read from ETS and durable search uses short immutable snapshots.
- Made intake preserve map `:text` and long code verbatim, build chunks from
  source byte spans, skip redundant final chunks, lower derivative attention,
  reuse partition category nodes, and cap extracted nodes.
- Implemented recall reinforcement, scheduled attention decay, priority/age
  eviction, and pinned-memory protection. Hot bounds are now application config
  only and cannot be overridden by an individual caller.
- Unified Unicode lexical normalization, stopwords, keywords, entities, and
  whole-word intent boosts across intake, recall, observations, knowledge, and
  mental models. Fingerprints now use 64 bits and vector matches have a positive
  similarity floor.
- Made mission-policy priority affect the runtime attention of generated intake
  records instead of remaining metadata-only.
- Updated Vettore to `~> 0.3.5` and replaced local/dynamic vector fallbacks with
  direct `Vettore.Vector` conversion, validation, normalization, cosine/dot
  scoring, Model2Vec f32-matrix mean pooling, and runtime Nx interoperability.
  The existing tensor helper functions remain available when Nx is supplied by
  the host application, and the persisted embedding format is unchanged.
- Made Jason and `tokenizers` optional dependencies. JSON-backed features use
  the implementation selected by the host, while Model2Vec retains its bounded
  lexical fallback when the Tokenizers NIF is absent.
- Preserved repeated Model2Vec token ids during pooling instead of silently
  deduplicating token occurrences.
- Reorganized the README as a concise entry point and added task-oriented
  guides covering every facade call, intake, retrieval, knowledge, persistence,
  export, erasure, and Spectre integration workflow with runnable examples.
- Added `min_vector_similarity` for recall, strict aggregation and traversal
  option validation, link shape validation, and a hard graph-node cap that
  includes seed memories.
- Centralized English and Italian stopword handling so sentence-leading
  articles do not create false keyword/entity boosts.
- Documented that `.mnemonic` readers validate detached exports but do not
  import or restore records into live memory.
- Made graph traversal exclude cluster membership and identity-redirection
  edges by default, with explicit relation opt-in.
- Rehydrated durable entity aliases and Episodes after hot eviction, and made
  reclustering supersede stale Episodes and membership edges.
- Added reversible entity unmerge events that tombstone `:same_as` edges and
  restore the prior winner/loser alias registries.
- Made structure exports topology-only for entity, cluster, category, and
  secret labels; durable clusters are retained in active exports.

### Fixed

- Repaired torn tails in both framed logs before the next append, refused
  complete CRC corruption, kept post-crash sequence numbers visible, and moved
  per-path counters out of leaking `persistent_term` entries.
- Synced append data, atomic snapshots, renames, directory metadata, and
  recovery-copy removal by default; added explicit `:always`, `:data`, and
  `:none` durability policies.
- Cached durable replay projections and Model2Vec model/tokenizer artifacts,
  removing full-log rescans and repeated model/checksum I/O from hot paths.
- Rebuilt the active Vettore index from hot moments after restart and moved its
  handle registry under the long-lived ETS owner so an index restart cannot
  silently lose earlier semantic candidates.
- Enforced `limit` with token budgets, deduplicated active/durable flat search,
  normalized merged ranks through reciprocal-rank fusion, and stopped random
  low-similarity vectors from becoming universal matches.
- Applied phone redaction before every derived/storage projection, removed raw
  forgotten fact values from lifecycle events and exports, and made
  observations and knowledge honor governance visibility.
- Made the scheduler enumerate all known partitions, skip semantic job writes
  without an adapter, and purge derived index state during verified erasure.
- Removed the unused plaintext `index/durable.term` snapshot and ensured
  partition erasure drops active Vettore collections and all recovery copies.
- Made rich intake roll back partial products, hot-only entity resolution stay
  hot-only, entity merge idempotent and cycle-safe, and link metadata accept
  only the intended option subset.
- Made secret AAD deterministic and versioned with legacy-read compatibility,
  inferred reveal scope from the secret, protected configured authorization and
  crypto adapters from per-call replacement, and hid cipher fields from
  `Inspect`.
- Made `%Date{}` `valid_until` values cover the entire named UTC date, fixed age
  extraction across sentence boundaries, normalized external string kinds to
  atoms, and propagated plug `{:error, reason}` results unchanged.
- Made the evaluation harness isolated, hot-only, and self-cleaning by default.
- Removed persistence-manager timeouts from large replay, compaction, erasure,
  and verification operations while preserving configurable typed timeouts.
- Made erasure verify every configured store, evict partition dedupe state,
  close concurrent hot-write windows, and reject stale future-dated records by
  durable erasure generation.
- Made forget cascade through Episodes and every membership edge, made sealed
  partitions reject links, and counted expired hot-only memories.
- Decayed only unused graph edges, respected hot-only persistence, throttled
  durable reweights, and prevented reinforcement from recreating forgotten
  hot edges.
- Made Atlas retain overflow dirty work, preserve concurrent dirty updates,
  prefer recent nodes, and report truncation to materialization and export.
- Removed stale lifecycle projections from the durable index after tombstones.
- Returned typed JSON/open/stream errors from `.mnemonic` readers.
- Kept JSON-free core operations independent of a JSON package and made
  JSON-backed operations fail explicitly when no adapter is configured.

### Security

- Bounded gzip expansion before allocation and separated CRC/framing recovery
  from safe term decoding, so recovery neither creates atoms nor mistakes
  not-yet-loaded application atoms for corrupt bytes.
- Added explicit logs for critical recovery and degraded index/rollback paths
  while keeping raw memory and secrets out of diagnostics.
- Reject non-finite and out-of-range float32 embeddings before indexing.
- Validate `.mnemonic` manifest, trailer, record envelopes, section-specific
  fields, and privacy invariants before returning decoded content.
- Fail durable writes closed when the erasure marker guard cannot be checked.
- Reject unsupported JSON runtime values instead of serializing nondeterministic
  `inspect/1` output.
- Documented that verified exports are not encrypted and that logical
  forgetting, physical partition erasure, and host/provider copy deletion are
  distinct privacy operations.

### Performance

- Avoid durable graph appends at stable bounds and within the configured
  reweight interval; avoid materializing the global association index during
  scheduled decay.

## Development milestone 0.4.0 - 2026-08-24

### Added

- Added partition-local canonical entity resolution, weighted typed spreading
  activation, recall traces, append-only edge reinforcement, and scheduled
  decay.
- Added deterministic Atlas projections and persisted Episode clusters with
  stable membership edges, incremental dirty-component clustering, optional
  label adapters, layout hints, graph statistics, and hard caps.
- Added durable-first `erase_partition/1`, retention sweeps, optional
  crypto-shredding, anti-resurrection markers, knowledge-log rewriting, and
  erase-mode compaction that retains no previous snapshots or rotated segments.
- Added the canonical JSON, CRC32- and SHA-256-verified `.mnemonic` v1 export
  container with structure, full, and caller-redacted privacy modes, chunked
  bounded frames, a lazy verified reader, and a versioned JSON Schema.
- Added caller-provided embeddings on `signal/2` and `remember/2`, plus
  partition-local Vettore collections for hybrid HNSW, quantized, and exact
  semantic recall.

### Changed

- Replaced graph BFS with hub-damped weighted activation and made entity intake
  reuse the existing canonical node within a partition.
- Made hot association and namespace-bound reads use partition indexes instead
  of scanning global ETS tables.
- Made semantic similarity contribute to intake graph links even when two
  memories share no useful vocabulary.

### Security

- Secret plaintext and ciphertext are excluded from every export mode by
  construction; structure exports contain topology and approved labels only.
- Export readers decode JSON only and reject mixed partitions, corrupt frames,
  digest mismatches, oversized frames, and unsupported format versions.

## Development milestone 0.3.0 - 2026-08-13

### Changed

- Retained GitHub-only distribution with no Hex package metadata.
- Replaced the GitHub Spectre dependency with the published Hex package at
  `~> 0.3.0`.
- Made default Credo analysis part of the required CI quality job.

### Fixed

- Serialized append and compaction operations for durable and progressive
  knowledge logs, preserving unique monotonic sequences under concurrency.
- Contained malformed options and adapter failures across focus, recall,
  governance, consolidation, action execution, embeddings, and secrets.
- Hardened Model2Vec artifact validation, checksum handling, download writes,
  and cache naming so distinct model identifiers cannot collide.

### Security

- Limited both compressed and declared expanded frame payloads to 64 MiB by
  default, configurable through `:max_frame_bytes`, before allocating or
  decoding persisted Erlang terms.
- Bound AES-GCM ciphertext to the current secret context and validated custom
  authorization, cryptography, and key-provider boundaries.

### Performance

- Replaced per-append persistent-term sequence writes with atomic counters.
- Removed repeated indexed list scans and incremental binary copying from
  binary embedding quantization.

## Development milestone 0.2.0 - 2026-08-01

### Changed

- Raised the package, memory adapter, and Stack compatibility contracts to
  Spectre 0.2.0.
- Verified active memory, durable recall, subject isolation, and Agent memory
  integration against the Spectre 0.2.0 operational runtime.

### Compatibility

- Memory records and runtime handles remain outside canonical Run and
  operational checkpoints.

## Development milestone 0.1.6 - 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and complete release documentation.
- Added no runtime functionality and made no intentional breaking API change.
