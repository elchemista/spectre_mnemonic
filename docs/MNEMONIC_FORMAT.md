# `.mnemonic` format version 1

This document is the normative contract for Spectre Mnemonic format-v1 exports.
Readers in Spectre Lab, Spectre Studio, or another implementation must follow
this document rather than depending on SpectreMnemonic runtime internals.
For writer, reader, stream, and erasure examples, see
[Persistence and operations](PERSISTENCE_AND_OPERATIONS.md#export-a-partition).

## Trust boundary

A `.mnemonic` file is a host-owned, trusted/local subject-access artifact. It
may contain personal data in `full` mode and must be protected accordingly.
Exported copies are outside `erase_partition/1` and must be deleted by their
owner. The checksums provide integrity, not encryption. A reader must never
decode an Erlang term from this container. Version 1 payloads are UTF-8
canonical JSON only. See
[Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md) for the
host-side disclosure and deletion workflow.

## File framing

The file is a sequence of frames with no bytes before the first frame or after
the last frame. All integers are unsigned, big-endian.

| Field | Bytes | Meaning |
| --- | ---: | --- |
| magic | 4 | ASCII `SMNE` |
| version | 1 | `1` |
| sequence | 8 | starts at 1 and increments by 1 |
| payload length | 4 | compressed payload byte length |
| CRC32 | 4 | CRC32 of the compressed payload |
| payload | variable | gzip-compressed canonical JSON |

Both the compressed and expanded JSON payload must be no larger than the
configured frame maximum (64 MiB by default). Readers reject unknown magic,
versions, missing sequences, truncation, invalid gzip, CRC mismatch, invalid
JSON, and trailing partial data.

Every decoded frame has this JSON shape:

```json
{"data": {}, "section": "manifest"}
```

The machine-readable Draft 2020-12 schema is
[`priv/mnemonic_schema_v1.json`](../priv/mnemonic_schema_v1.json). It defines
the manifest, every content section, the common record envelope, edges,
clusters, and the trailer. Implementations apply it to every decoded frame in
addition to the semantic checks below.

The bundled reader validates required fields, field types, digest syntax,
timestamps, exact count keys, normalized edge weights, cluster member ids, and
privacy-forbidden fields before returning any data. Schema failures identify
the frame sequence, section, record index when applicable, and failed rule.

Object keys are serialized in ascending Unicode codepoint order. Arrays retain
their specified order. Records are ordered by `family`, then `inserted_at`, then
`id`. Timestamps use ISO 8601 UTC strings. Non-UTF-8 binaries, when explicitly
included, use `{"$binary":"BASE64"}`.

The bundled writer and reader use the host module configured as
`config :spectre_mnemonic, json_library: ...`. It must export `decode/1` and
either `encode/1` or `encode!/1`. The canonical layer owns object ordering,
array order, and container structure; the adapter encodes JSON strings and
numbers and decodes frames. Elixir's `JSON` and Jason are covered by the
interchange tests. Adapter identity is not stored in the file.

Consumers must not assume exports produced by different JSON adapter
implementations or versions are byte-for-byte equal: valid string escaping and
number lexical forms can differ. Digest verification remains portable because
the reader hashes the exact expanded frame bytes rather than re-encoding the
decoded value. For repeatable byte-level exports, keep the adapter and its
version stable.

## Section order and chunking

Logical sections occur in exactly this order:

1. `manifest`
2. `nodes`
3. `edges`
4. `clusters`
5. `models`
6. `knowledge`
7. `governance`
8. `trailer`

`manifest` and `trailer` occur exactly once. Every content section occurs one
or more times: writers split large arrays into consecutive frames so both the
compressed and expanded form of each frame stays within the 64 MiB bound. A
small export therefore has eight frames; a large export can have more. Readers
concatenate consecutive chunks of the same section. A missing, reordered, or
non-consecutive section is invalid. An omitted content class is represented by
one frame containing an empty array.

The frame bound is a container invariant, not a constant-memory writer
guarantee. The bundled format-v1 writer materializes the selected partition to
deduplicate it, establish deterministic record order, and compute exact
manifest counts. Consumers that need incremental access should use the verified
reader stream.

## One-partition invariant

One file contains exactly one `{namespace, scope}` partition. `manifest`
contains the namespace, an opaque printable scope, and
`scope_digest = hex(sha256(deterministic_erlang_encoding({namespace, scope})))`.
The Erlang encoding is used only by the trusted writer to derive the digest; it
is never stored or decoded by the reader.

Every content record repeats `namespace` and `scope_digest`. A reader must reject
the entire file if any record disagrees with the manifest. No graph endpoint or
cluster may be sourced from another partition.

## Manifest

The manifest object contains:

- `format`: `spectre-mnemonic`
- `format_version`: `1`
- `library_version`: writer version
- `namespace`, `scope`, `scope_digest`
- `privacy_mode`: `structure`, `full`, or `redacted`
- `created_at`: the latest included record timestamp, or the Unix epoch for an
  empty partition; this makes unchanged exports byte-identical
- `counts`: record count for every content section
- `content_digest`: lowercase SHA-256 hex digest defined below

## Content records

Every record has `family`, `id`, `namespace`, `scope_digest`, and
`inserted_at`. Other fields depend on its section and privacy mode.

- `nodes`: signals, moments/entities, and artifacts.
- `edges`: association source, target, relation, weight, and approved metadata.
- `clusters`: Episode id, member ids, deterministic algorithm metadata, and
  temporal fields. The title is present only in privacy modes that permit raw
  labels.
- `models`: observations and mental models, including provenance in `full` mode.
- `knowledge`: consolidated records plus compact `knowledge.smem` events.
- `governance`: lifecycle state events and their temporal ordering.

Consumers must ignore unknown record fields. New optional fields may be added in
a compatible 1.x writer; removing required envelope fields or changing section
meaning requires a format-version increment.

## Privacy modes

`structure` is the default. It includes topology, ids, relations, weights,
states, time fields, and a small approved structural metadata set. It excludes
raw signal input, moment text, summaries, knowledge text, vectors, arbitrary
metadata, cluster titles, canonical entity labels, aliases, categories, and
secret labels. Readers scan forbidden keys recursively, including nested
metadata.

`full` is the broad projection intended to support subject-access and, where
applicable, portability workflows. It includes record payloads and provenance.
The host determines the final disclosure and contextual information required
by law. Embedding fields remain excluded unless the writer is called with
`embeddings?: true`.

`redacted` applies the caller's one-arity redaction function to every non-secret
payload before JSON encoding. Deterministic output requires a deterministic
function.

Secrets are structurally special in every mode. A secret record may contain
only presence, lock status, temporal fields, and—outside structure mode—a
label. Plaintext, ciphertext, IV, authentication tag, AAD, vectors, and
arbitrary secret metadata are never exported. A reader rejects a file
containing any of these fields even if its framing, checksums, digest, and
counts are otherwise valid.

Replay applies tombstones before projection. Logically forgotten records and
their dependent episodes therefore do not appear in an export even when their
old append-only bytes have not yet been physically compacted. This is a logical
subject-access view, not a forensic dump of storage bytes.

When active projections are included, the writer rejects Atlas truncation with
`{:mnemonic_export_truncated, details}` instead of silently emitting a partial
graph. Durable Episodes are merged with active clusters, so hot eviction or a
runtime restart does not drop cluster history.

## Digest and verification

For every content frame from `nodes` through `governance`, including every
chunk, take the exact expanded canonical JSON payload bytes (the whole frame
object including `section` and `data`) before compression. Concatenate those
byte strings in file order and compute SHA-256. A reader hashes those expanded
bytes directly; it does not re-encode the decoded value. The lowercase hex
result must equal both
`manifest.content_digest` and `trailer.content_digest`. Counts are the sum of
records across all chunks of a logical section.

The trailer also repeats per-section counts. A conforming reader verifies, in
order: frame structure, sequence, bounds, CRC, gzip, JSON, version, section
order, digest, counts, and partition agreement. No partially verified export is
returned.

## Reader and restore boundary

A format-v1 reader decodes and verifies a detached representation. Successful
verification does not authorize the reader to mutate active memory, replay a
record into a durable store, merge identities, or apply governance state.
`SpectreMnemonic.Export.read/2` and `SpectreMnemonic.Export.stream/2` are
read-only implementations of this contract.

The stream is verified before it is returned. If the underlying file changes
between verification and lazy enumeration, it emits one `{:error, reason}`
item and halts rather than raising midway through the enumerable.

Format version 1 defines no import or live-memory restore semantics. In
particular, it does not define conflict resolution, idempotency keys, tombstone
precedence, entity merging, governance transitions, or replacement rules for
records already present in the destination partition. Implementations must not
infer those operations from frame order or timestamps. A future rehydration API
must define and validate those rules explicitly before writing any record.
