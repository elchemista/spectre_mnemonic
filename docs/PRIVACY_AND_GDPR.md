# Privacy, data protection, and GDPR operations

This guide maps SpectreMnemonic's technical controls to a privacy operations
workflow. It is engineering guidance, not legal advice and not a certification
of GDPR compliance. The application that determines why and how personal data
is processed remains responsible for its legal basis, notices, policies,
processors, international transfers, request handling, and evidence of
compliance.

The GDPR principles include purpose limitation, data minimisation, accuracy,
storage limitation, integrity, confidentiality, and accountability. Start with
the [official regulation](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32016R0679),
the [European Commission's GDPR principles](https://commission.europa.eu/law/law-topic/data-protection/information-business-and-organisations/principles-gdpr_en),
and applicable national guidance.

## Responsibility boundary

SpectreMnemonic is an in-process library. It is not, by itself, a data
controller or processor. The host application chooses the data, purposes,
scope identifiers, persistence adapters, embedding providers, backups, logs,
and recipients.

| Area | SpectreMnemonic provides | Host application remains responsible for |
| --- | --- | --- |
| Isolation | exact `{namespace, scope}` partitions | mapping authenticated people to every relevant scope |
| Minimisation | optional embeddings, redacted exports, bounded hot memory | deciding which fields are necessary and lawful |
| Retention | `valid_until`, `sweep_expired/1`, tombstones, compaction | policy, scheduling, legal holds, and all external copies |
| Access and portability | verified `full` `.mnemonic` export | identity verification, completeness, secure delivery, and any required format conversion |
| Erasure | verified whole-partition erasure for capable stores | finding every partition and deleting backups, exports, logs, provider data, and other systems |
| Secrets | explicit reveal authorization and pluggable encryption | keys, rotation, envelope encryption, access policy, and infrastructure encryption |
| Automated use | evidence packets with provenance and governance state | human review, decision logic, notices, contestability, and Article 22 assessment |

If a remote embedding, extraction, persistence, object-store, or model service
receives personal data, assess that service separately as a recipient or
processor. Record its retention, region, sub-processors, deletion API, and
contractual safeguards.

## Inventory the data surfaces

Treat all of these as potentially containing personal data:

- raw signal input, moment text, summaries, observations, mental models,
  knowledge events, action recipes, artifacts, metadata, and provenance;
- namespace and scope values, ids, entity aliases, graph edges, clusters, and
  timestamps, even when they appear pseudonymous;
- embeddings and binary signatures derived from personal text;
- active ETS tables, configured durable stores, `knowledge.smem`, snapshots,
  rotated segments, model/provider caches, and application backups;
- `.mnemonic` exports and any application logs, traces, analytics, queues, or
  downstream prompts built from recall packets.

The active and durable vector indexes are derived projections, not independent
sources of truth. They are cleared during the corresponding library erasure
path, but copies made by the host remain outside that path.

## Privacy-by-design configuration

### Use opaque partitions

Choose stable opaque subject or tenant identifiers. Avoid putting an email
address, phone number, name, prompt, or other raw personal value in the
namespace, scope, record id, filesystem path, or Vettore collection name.

```elixir
config :spectre_mnemonic,
  namespace: "support_memory",
  json_library: JSON

scope = {:subject, account.internal_uuid}
```

Keep an authenticated application-owned mapping from a data subject to every
scope that may contain their data. `erase_partition/1` intentionally never
guesses scopes and never treats an omitted scope as a wildcard.

### Minimise collection and derivation

- Do not store complete request/response objects when a small, typed projection
  is enough.
- Phone-like values are redacted before intake derives chunks, summaries,
  keywords, embeddings, indexes, or durable records unless the caller
  explicitly selects `sensitive_numbers: :raw`. This is a narrow phone control,
  not a general PII detector; classify and redact other fields in the host.
- Keep secrets in `Memory.Secret`; do not duplicate plaintext in ordinary
  moments, metadata, titles, summaries, or logs.
- Leave embeddings disabled unless semantic retrieval is needed. Consider
  local Model2Vec processing before sending text to a remote provider.
- Limit extraction, graph depth, metadata, hot-memory counts, and durable
  families to the stated purpose.
- Use `mode: :structure` for operational topology exports and a deterministic
  redactor for narrower disclosures. Do not use `full` as a routine diagnostic
  export.

### Define and execute retention

`valid_until` records a validity boundary; it does not run a timer. Invoke a
scoped sweep from application-owned scheduled work:

```elixir
{:ok, count} =
  SpectreMnemonic.sweep_expired(
    namespace: "support_memory",
    scope: {:subject, account.internal_uuid},
    now: DateTime.utc_now()
  )
```

The sweep and `forget/2` make records logically unavailable and write durable
tombstones. Old bytes may remain in append-only storage until compaction.
Use verified partition erasure when the policy requires physical removal of
the whole partition. Define separate retention and deletion procedures for
backups, exported files, object versions, logs, caches, and processor systems.

## Data-subject request runbook

The [EDPB right-of-access guidelines](https://www.edpb.europa.eu/documents/guideline/guidelines-012022-on-data-subject-rights-right-of-access_en)
stress that a controller's search must include relevant processor-held data.
Do not treat one Mnemonic partition as proof that the request is complete.

### Access

1. Authenticate the requester and authorize the request outside this library.
2. Resolve every namespace and scope linked to the subject.
3. Rebuild or replay durable state as required before export.
4. Export each partition with `mode: :full`; decide explicitly whether
   embeddings are necessary for the request.
5. Inspect the result for third-party data, legal restrictions, and required
   redaction before disclosure.
6. Include data held by providers, backups, logs, and other application stores.
7. Deliver the result through an authenticated, encrypted channel and apply a
   short retention period to the generated copy.

```elixir
SpectreMnemonic.export("subject.mnemonic",
  namespace: "support_memory",
  scope: {:subject, subject_id},
  mode: :full,
  embeddings?: false,
  active?: true
)
```

A `.mnemonic` file is a verified, machine-readable container whose frames
contain JSON. It is not automatically the final format required for every
Article 15 or Article 20 response. The host may need to translate it and add
the contextual information required by its privacy notice and applicable law.

### Rectification

Do not mutate append-only history silently. Record the corrected fact with
provenance, mark or forget the inaccurate record, rebuild derived indexes, and
verify normal recall no longer exposes the superseded value. If keeping the old
bytes is not lawful, use whole-partition erasure and rebuild only the data that
may still be processed.

### Erasure

Use the exact partition and require verified stores:

```elixir
{:ok, report} =
  SpectreMnemonic.erase_partition(
    namespace: "support_memory",
    scope: {:subject, subject_id},
    sealed: true
  )
```

`sealed: true` also rejects future writes to that partition. Preserve the
privacy-safe report in an application audit system if necessary, without
copying the erased content or raw subject identifier into the audit event.

Then independently delete or expire:

- every `.mnemonic` export and temporary disclosure file;
- application backups, replicas, object versions, queues, logs, traces, and
  analytics governed by the request;
- remote embedding/extraction/provider data and caches;
- artifacts referenced by memory when their bytes live outside a configured
  Mnemonic store;
- keys when application envelope encryption uses per-partition key material.

`forget/2` is not physical erasure. A successful `erase_partition/1` proves the
postcondition only for the configured adapters participating in that call.
The forget transition also removes inherited `fact_*` values from lifecycle
events and filters governed observations/knowledge/export projections, so the
value is not reintroduced through the governance audit view.

For the built-in file adapter, “physical” means the rewritten live files and
reachable recovery copies have been verified and old paths unlinked.
Filesystem unlink is not forensic media sanitization on SSDs,
copy-on-write/snapshot storage, backups, or provider replicas. Apply
encryption-at-rest, key destruction, provider deletion, and media-disposal
controls where the threat model requires them.

### Restriction, objection, and automated decisions

Restriction and objection workflows belong to the host. Stop new intake and
downstream use for the affected subject, enforce authorization before recall,
and record the policy state outside free-form memory. Sealing is available only
as part of partition erasure; it is not a general legal-hold or restriction
workflow.

Recall and reflection return evidence, not final decisions. If an application
uses that evidence for profiling or a decision with legal or similarly
significant effects, assess human intervention, explanation, contestability,
and the restrictions on automated decision-making. The
[European Commission's guidance](https://commission.europa.eu/law/law-topic/data-protection/information-individuals_en)
describes these responsibilities.

## Security and accountability checklist

- Apply least privilege to the BEAM node, durable stores, model cache, exports,
  backups, and encryption keys.
- Encrypt storage and transport at the infrastructure boundary; do not assume
  the `.mnemonic` container itself is encrypted.
- Keep secret reveal adapters deny-by-default and test authorization failures.
- Secret AAD uses a deterministic versioned digest of `{namespace, scope}`.
  Authorization, crypto adapters, and keys configured by the application take
  precedence over per-call options, so untrusted recall options cannot replace
  the reveal policy. Existing legacy AAD remains readable for migration.
- Avoid raw memory, scope values, prompts, secrets, and exports in logs or
  telemetry. Use request ids, counts, status, and opaque digests.
- Test restore, compaction, erasure verification, stale-backup resurrection,
  and processor deletion procedures.
- Maintain a record of purposes, categories, recipients, retention schedules,
  transfers, access controls, and request outcomes outside the memory corpus.
- Run a DPIA before high-risk processing and revisit it when models, purposes,
  data categories, providers, or decision effects change. See the
  [European Commission DPIA guidance](https://commission.europa.eu/law/law-topic/data-protection/information-business-and-organisations/obligations/when-data-protection-impact-assessment-dpia-required_en).

## Technical limitations

- There is no wildcard cross-partition access or erasure API.
- Granular `forget/2` is logical; verified physical erasure operates on a whole
  partition.
- Export version 1 is read-only and cannot restore or import live memory.
- The built-in AES-GCM adapter does not implement per-partition key destruction.
- External artifacts, logs, provider systems, and host-owned exports are not
  controlled by `erase_partition/1`.
- Compliance depends on deployment, configuration, organizational procedures,
  contracts, and applicable law; enabling these APIs alone is not compliance.

For storage mechanics and exact postconditions, continue with
[Persistence and operations](PERSISTENCE_AND_OPERATIONS.md) and the normative
[`.mnemonic` format](MNEMONIC_FORMAT.md).
