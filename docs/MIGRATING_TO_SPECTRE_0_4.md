# Migrating Mnemonic to Spectre core 0.4

This guide describes the implemented `feature/stack-tools-0.4` branch, paired
with core `feature/agent-server-gam`. Core 0.4 is unreleased here; satellite
version numbers remain independent. Use the Git/path dependencies in the
[current README](../README.md), not an assumed published Hex version.

## What changes from core 0.3

| Concern | Existing 0.3 application | Core 0.4 application |
| --- | --- | --- |
| Installation | Stack package configuration | Same package registration plus optional `tools/1` descriptor |
| Recognition | Flows and route strategies | Agent keeps declaration-only routes and classifiers |
| Application behavior | Flow bodies / Instance and Run continuation | `Spectre.Server` callbacks and queued commands |
| Tool entry | Direct call / Action provider | Generated helper schedules a command; no import from package |
| Results | Immediate value or Invocation resumption | `handle_result(tag, result, ctx)` after worker result acquisition |
| Effects | Legacy application policies | Automatic AgentServer GAM lifecycle and registered effect adapter |
| Durability | Legacy Run/Instance projection | Server checkpoint, inbox/outbox and typed portable results |

The migration does **not** remove `SpectreMnemonic.Engine` and the direct signal/remember/recall/search APIs. Direct calls do not acquire
Server semantics merely because the package is installed. Keep standalone
workflows explicitly caller-owned. Historical examples remain in
[the legacy guide](LEGACY_0_3.md).

## Registration and callback lifecycle

The package's existing `Spectre.Stack.Installable` registration contributes
`tools/1`: a versioned descriptor naming the helper, adapter, default operation
and allowed operations. `use Spectre.Server, tools: MyApp.AI` generates private
helper arities 2 and 3 from the immutable Stack. No package-specific import is
needed, and arbitrary public functions are not exposed automatically.

A helper appends a command to `ctx`; it does not synchronously call the library.
Return that context. Pure adapter preparation validates arguments, Spectre
commits the outbox, then a worker runs the selected cognitive operation or
submits the governed proposal. Projected results are acquired before dispatching
`handle_result/3`. `on_result:` selects the callback tag. Unknown operations and
invalid payloads produce typed rejections; declaration/collision mistakes fail
early. Never put PIDs, functions or provider clients into persisted arguments.

Cognitive `:safe` operations can replay after interruption. `:never` operations
return `{:tool_unknown, details}` after uncertain execution and need application
reconciliation. Governed operations require an allowed operation entry in automatic GAM and follow
GAM reconciliation; they are not automatically retried as cognitive calls.
Native GenServer callbacks remain available through the Server behavior; return
commands through that boundary rather than bypassing its bookkeeping.

## Choose automatic or explicit memory

The 0.3 memory port automatically recalled before a turn and persisted committed
turns. Compatibility defaults retain `automatic: true`. For explicit save
consent, install `automatic: false`: the Engine remains installed, but neither
automatic recall nor implicit ingestion runs. Use `mnemonic(ctx, {:recall, cue},
on_result: :recalled)` and bind `remember` explicitly to a host operation.

`isolate_by([:subject])` belongs inside the installation block. Passing
`isolate_by: [:subject]` as an installation option does not declare isolation.
Use a canonical `Spectre.Subject`; the library does not infer identity from an
email address or sender handle. `:instance` refers to the legacy Instance key
and should not be copied into a new AgentServer without deliberately supplying
that compatibility identity.

## Expanded operation catalogue

The generated helper now exposes nine explicit read operations and thirteen
host-bindable writes. Start with `mnemonic(ctx, {:search, cue, limit: 5},
on_result: :found)` for flat active/durable results, and `{:recall, cue}` for a
context packet. See the [operation table and option placement](../README.md#choosing-a-memory-operation-in-an-agentserver).
No additional imports or package-specific macros are needed.

Read helpers now disable reinforcement and secret reveal. Saving, learning,
forgetting and maintenance remain distinct governed operations. Recompile the
Stack and Server together after changing descriptors; review existing checkpoints
instead of bypassing the immutable tool-contract mismatch.

## Authenticated partition

The callback's tool request contains the observation, not authority. Configure
`identity` at AgentServer startup, provide the named Stack runtime and allow the
registered memory operation. Spectre freezes the complete authenticated partition
and normalized arguments in the Candidate. After admission, its registered effect
adapter reconstructs the same execution identity from that committed material.

For `:conversation` isolation, provide the conversation identifier in trusted
identity as well. The model cannot replace subject, conversation or runtime name.
Missing Stack runtime or required partition fails before writing; explicit tools
do not silently use DefaultEngine. Direct legacy `Memory` calls retain their
compatibility behavior.

The adapter projects its result before building GAM evidence. Command identity
is forwarded as `operation_id`, enabling correlation with the persisted batch.
This is not full-ingestion idempotency: reconciliation is still required after
an ambiguous acknowledgement.

## Portable results and engine migration

Recall returns `{:ok, packet_map}` to the Server. New helpers intentionally do
not return native packets: fields are explicitly allowed by record type; unknown
record types fail closed, timestamps are ISO strings and secrets stay locked.
Raw input, arbitrary record metadata, vectors and encryption material are absent.
Standalone calls keep their native structs and full documented APIs.

This branch retains Mnemonic Engine 0.2. Applications migrating the old global
engine also need [the separate Engine 0.2 migration](MIGRATING_TO_0_2.md). Do not
reuse one `storage_id` from multiple active writers or silently change partitions
while expecting the same memory corpus.

## GAM and consent

Follow the [Governed Act Model manifesto](https://spectre.guide/en/governed-act-model).
Evidence informs decisions; a Mandate bounds authority; an admitted Act is
recorded before its capability is released. Unresolved obligations remain
represented by Duties. Package installation and model output are neither a
Mandate nor end-user consent.

Spectre's default cognitive calls do not ask permission for every model or
classifier computation. The host chooses the governed surface, which may include
protected disclosure or resource consumption. Effects requiring consent wait in
the Server's pending lifecycle; application handlers can confirm, reject,
suspend, resume or schedule audited closure. A topic change is not consent.

See [core AgentServer](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/AGENT_SERVER.md),
[pending lifecycle](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/PENDING_LIFECYCLE.md) and
[Stack tools](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md) for host configuration and recovery.

## Migration checklist

1. Pin compatible core and package feature revisions; keep the old dependency
   lockfile available for rollback.
2. Separate Stack installation, Agent routes and Server callbacks.
3. Replace legacy flow effects with explicit helper commands/result handlers;
   retain direct APIs only where caller-owned execution is intentional.
4. Configure named resources and trusted identity required by the package.
5. Configure allowed operations and confirmation in AgentServer; use
   `handle_action/2` for business checks. Spectre constructs GAM records and runs
   the registered executor only after admission.
6. Test refused, uncertain and interrupted paths as well as successful results;
   verify portable snapshots before deploying existing conversations.
7. Review checkpoint/installation changes explicitly; never replay a potentially
   executed effect just to work around a migration error.

## Reusable Skill servers

Use the Stack-generated `mnemonic` helper in a Skill's ordinary
`Spectre.Server` callbacks. The Agent mounts `Spectre.Skill, server: ...`; each
mount then owns its GenServer, state, workers, streams, pending intentions and
checkpoint key. No package-specific Skill adapter or extra installation is needed.

```text
AgentServer ─────┐
Research Skill ──┼──→ one automatic GAM boundary → same Domain / authority ledger
Knowledge Skill ┘
```

The root creates this connection once and passes it to the children. Do not
bootstrap another Domain, copy the ledger, implement a Skill Host or extend
ingress manually. Mounting grants no authority. Governed effects must satisfy
both root `gam:` operations and the mount's `governed:` references; scoped
Kinetic references keep their complete mounted scope. Ledger/Lab inspect the
calling runtime's checkpoint, not a copy of the shared GAM history.

The shared kernel orders admission while workers can run concurrently. Every
proposal retains its Skill invocation provenance. A confirmation belongs to the
originating mount and exact presentation, so it cannot approve a different
Skill's pending request. Timer expiry and closure enter the same lifecycle
ledger without erasing Acts, uncertain Outcomes or Duties. No per-Skill GAM
configuration is required.

See the [core shared/local ownership table and confirmation example](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md),
[automatic GAM contract](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MANAGED_GAM.md)
and [LiveView showcase](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/DEMO.md).
