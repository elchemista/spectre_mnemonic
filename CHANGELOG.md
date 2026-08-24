# Changelog

All notable changes to Spectre Mnemonic are documented in this file.

## [Unreleased]

### Added

- Added opt-in `ex_fastembed` system tests with a real local BGE model covering
  semantic top-result accuracy, Vettore strategies, similarity filtering,
  partition isolation, graph aggregation, and durable rebuilds.
- Added broad `.mnemonic`, graph, aggregation, entity-resolution, traversal,
  Atlas, plasticity, and parameter-conformance test matrices.
- Added a Spectre `0.3.3` Agent end-to-end test covering automatic turn
  persistence, cross-conversation recall, exact email/reference/question
  answers, subject isolation, and real local semantic retrieval.

### Changed

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

### Security

- Reject non-finite and out-of-range float32 embeddings before indexing.
- Validate `.mnemonic` manifest, trailer, record envelopes, section-specific
  fields, and privacy invariants before returning decoded content.
- Fail durable writes closed when the erasure marker guard cannot be checked.
- Reject unsupported JSON runtime values instead of serializing nondeterministic
  `inspect/1` output.

### Performance

- Avoid durable graph appends at stable bounds and within the configured
  reweight interval; avoid materializing the global association index during
  scheduled decay.

## [0.4.0] - 2026-08-24

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

## [0.3.0] - 2026-08-13

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

## [0.2.0] - 2026-08-01

### Changed

- Raised the package, memory adapter, and Stack compatibility contracts to
  Spectre 0.2.0.
- Verified active memory, durable recall, subject isolation, and Agent memory
  integration against the Spectre 0.2.0 operational runtime.

### Compatibility

- Memory records and runtime handles remain outside canonical Run and
  operational checkpoints.

## [0.1.6] - 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and complete release documentation.
- Added no runtime functionality and made no intentional breaking API change.

[Unreleased]: https://github.com/elchemista/spectre_mnemonic/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/elchemista/spectre_mnemonic/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/elchemista/spectre_mnemonic/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/elchemista/spectre_mnemonic/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/elchemista/spectre_mnemonic/compare/v0.1.5...v0.1.6
