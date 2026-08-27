# Migrating from 0.1.x to 0.2.0

Version 0.2.0 keeps the 0.1.x durable reader and public option-based facade,
but moves ownership into explicit Engines. This guide separates the safe
compatibility path from changes that alter memory identity.

## Safe upgrade with no identity change

Keep the existing global namespace and data root:

```elixir
config :spectre_mnemonic,
  namespace: "my_app_memory",
  data_root: "mnemonic_data"
```

The application starts `SpectreMnemonic.DefaultEngine` in legacy-layout mode.
Existing calls without `engine:` continue through the new core and the reader
accepts v1 records and legacy snapshots. New appends use record and snapshot
schema v2. Do not rename the namespace or data root during this first upgrade.

The historical unscoped/shared partition is unchanged. In particular, Spectre
installations with `isolate_by: []` continue to see their shared memory.

## Move to an explicit standalone Engine

For a new data identity, supervise an Engine and pass it on calls:

```elixir
children = [
  {SpectreMnemonic.Engine,
   name: MyApp.Memory,
   storage_id: "my-app-memory",
   namespace: "my_app",
   data_root: "data/memory"}
]

SpectreMnemonic.recall("deployment decision",
  engine: MyApp.Memory,
  scope: {:project, "checkout"}
)
```

An explicit Engine stores File data below a directory derived from
`storage_id`. Treat `storage_id` as durable identity, not as a display name.
Changing an Engine's registered process name does not change its storage.

To adopt an explicit Engine while retaining existing 0.1.x files, first run
the DefaultEngine compatibility path and perform an application-owned,
verified export/replay into the new identity. Do not simply point two active
Engines or two nodes at the same files.

## Spectre installation

Spectre is now optional. Standalone consumers should remove it unless they use
the Stack adapter. A Stack installation supervises an Engine resource:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Mnemonic do
    isolate_by [:instance]
  end
end

children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.AI,
   name: MyApp.AIRuntime,
   packages: [mnemonic: [data_root: "data/memory"]]}
]
```

Pass `stack_runtime: MyApp.AIRuntime` when creating the Spectre Instance. The
adapter resolves the resource for each callback; the runtime name or Engine PID
is never persisted.

The default Stack `storage_id` is derived from `{stack_owner,
installation_id}`. It deliberately does not include the complete Stack digest,
so a compatible Stack update keeps the same memory directory.

## Choose scope migration explicitly

There is no automatic migration from shared legacy scope to Instance scope.
The engine cannot infer which historical record belongs to which Instance.

- Keep `isolate_by: []` to retain the shared partition unchanged.
- Use `isolate_by: [:instance]` for new installations or after an explicit
  host-owned repartition.
- During repartition, the host must assign every record to one destination
  scope or `:skip`, verify the destination, and only then erase the source
  partition. `SpectreMnemonic.Migration.repartition/3` supplies deterministic
  operation IDs and never erases the source implicitly.
- Never fall back from a missing Instance ref to shared memory. The adapter
  returns `{:mnemonic_isolation_dimension_required, :instance}`.

When an `Instance.Ref` schema changes one-to-one, migrate from the old opaque
scope to the new scope with an idempotent operation and preserve the old
partition's erasure marker to prevent resurrection.

For an operational migration, implement
`SpectreMnemonic.Migration.Assigner` and run:

```bash
mix spectre_mnemonic.repartition MyApp.MemoryRepartition
```

The callback module supplies source/destination Engine options and `assign/1`.
The task reports counts only and deliberately leaves source erasure as a
separate verified operation.

## Persistence and adapter changes

The primary store now decides commit. A failed primary returns an error. A
committed primary plus failed replica returns an OK `WriteReceipt` with
`repair_required?: true`; retrying the same `operation_id` is idempotent.

Custom adapters should implement and audit
`SpectreMnemonic.Persistence.Store.Contract`. Legacy adapters receive a
conservative non-conformant contract. Postgres, Mongo, and S3 modules bundled
with the library remain placeholders.

The File reader supports:

- v1 and v2 record envelopes;
- legacy term snapshots and framed v2 snapshots;
- incomplete-tail recovery with CRC validation.

The writer emits v2 only. Take a recoverable backup and exercise replay,
compaction, erasure verification, and restart before deleting old copies.

## Resource limits and failures

Engine limits are maxima. Per-call options may lower them but cannot replace
stores, paths, secrets, embeddings, or raise quotas. New bounded failure modes
include:

```elixir
{:error, :mnemonic_busy}
{:error, {:queue_full, :partition}}
{:error, {:queue_full, :store}}
{:error, {:mnemonic_limit_exceeded, limit_name}}
```

Monitor `SpectreMnemonic.health(engine)` and recall diagnostics before enabling
strict consistency. Health and telemetry contain status and counts, never
memory content. Telemetry remains host-owned and optional: add
`{:telemetry, "~> 1.3"}` only when the deployment consumes those events.

## Deployment gate

0.2.0 is single-node. Multiple Engines and partitions may run concurrently in
one VM, but the host must guarantee one active writer for each `storage_id`
across a cluster. There are no distributed locks, distributed ETS, consensus,
or cross-node ownership claims.

Before rollout:

1. test the legacy reader against a copy of production data;
2. retry an operation ID and confirm one logical mutation;
3. simulate primary commit plus replica failure and observe repair;
4. race remember with partition erasure and verify no resurrection;
5. restart both the Engine and, when used, the Spectre Stack Runtime;
6. verify candidate counts stay bounded on a production-sized corpus;
7. confirm no second node can activate the same storage identity.
