# Spectre Mnemonic for core 0.4

A supervised Elixir memory engine with an explicit AgentServer integration:
search and recall evidence during cognition; write through an admitted host operation when
the application requires consent. The existing standalone Engine 0.2 APIs,
text retrieval, embeddings, graph search and persistence remain
available. Core 0.4 does not change the satellite's independent version number.

[Documentation index](docs/INDEX.md) · [Migrate from core 0.3](docs/MIGRATING_TO_SPECTRE_0_4.md)

## Installation on this development branch

This is the **unreleased Spectre core 0.4 integration**. Satellite package
versions are independent; no published Hex 0.4 release is assumed here. Pin
reviewed Git commits for deployment. During development use:

```elixir
defp deps do
  [
    {:spectre, github: "elchemista/spectre",
     branch: "feature/agent-server-gam", override: true},
    {:spectre_mnemonic, github: "elchemista/spectre_mnemonic",
     branch: "feature/stack-tools-0.4"}
  ]
end
```

For sibling checkouts, replace these with `path: "../spectre"` and
`path: "../spectre_mnemonic"` dependencies. Package integration tests use
`SPECTRE_PATH=../spectre mix test`.

Spectre remains optional for standalone `SpectreMnemonic` use. Supervise an
explicit `SpectreMnemonic.Engine` when calling those APIs directly; see the
[standalone guide](docs/STANDALONE.md).

## Explicit memory in Stack → Agent → Server

```elixir
defmodule MyApp.MemoryAI do
  use Spectre.Stack
  install Spectre.Mnemonic, automatic: false, bind: [remember: :save_note] do
    isolate_by([:subject])
  end
end

defmodule MyApp.MemoryServer do
  use Spectre.Server, tools: MyApp.MemoryAI

  def handle_flow({:notes, :recall}, input, ctx),
    do: mnemonic(ctx, {:recall, input.text}, on_result: :recalled)

  def handle_flow({:notes, :remember}, input, ctx),
    do: mnemonic(ctx, {:remember, input.text}, on_result: :saved)

  def handle_result(:recalled, {:ok, packet}, ctx),
    do: respond(ctx, Enum.map_join(packet.moments, "\n", &Map.get(&1, :text, "[locked memory]")))

  def handle_result(:saved, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "The note was saved.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end

defmodule MyApp.MemoryAgent do
  use Spectre.Agent, stack: MyApp.MemoryAI, server: MyApp.MemoryServer
  flow :notes do
    on(:remember, regex: ~r/^remember /i)
    on(:recall, regex: ~r/^recall /i)
  end
end
```

`mnemonic/3` is generated from `tools/1`; the package does not export a helper
that you should import. `automatic: false` removes the automatic recall/persist
port while retaining the Engine resource and explicit tools. This prevents
implicit ingestion before your save-consent flow. The compatibility default is
`automatic: true`; changing it requires reviewing the application's behavior.

## Choosing a memory operation in an AgentServer

The helper name identifies the package; the tuple identifies the operation.
There is intentionally no ambiguous default for `mnemonic(ctx, text)`:

```elixir
# Flat ranked hits from active memory and durable stores, including source/id.
mnemonic(ctx, {:search, "Elixir contacts", limit: 5}, on_result: :found)
# A richer context packet, with related observations/models/knowledge.
mnemonic(ctx, {:recall, "Elixir contacts", max_tokens: 1200}, on_result: :context)
# Source-linked evidence arranged for reasoning, without generating prose.
mnemonic(ctx, {:reflect, "release risks", limit: 5}, on_result: :evidence)
mnemonic(ctx, {:atlas, max_nodes: 20}, on_result: :map)
mnemonic(ctx, {:knowledge}, on_result: :knowledge)
```

Request options go **inside the tuple**. Server scheduling options (`on_result`,
`timeout`, `confirmation`) go outside. A helper queues a command: return the
resulting context and receive the result in `handle_result/3`.

```elixir
def handle_result(:found, {:ok, hits}, ctx) do
  text = Enum.map_join(hits, "\n", &Map.get(&1.record, :text, "[locked memory]"))
  respond(ctx, text)
end
```

| Available read | Returned data |
| --- | --- |
| `{:search, cue}` | Flat ranked list with `id`, `source`, `record`, score |
| `{:recall, cue}` | Context packet, including `moments` and related evidence |
| `{:reflect, cue}` | Evidence packet with `raw_memories`, observations, models and citations |
| `{:search_observations, cue}` | Derived observations |
| `{:search_mental_models, cue}` | Curated mental models |
| `{:search_knowledge, cue}` | Matches in compact progressive knowledge |
| `{:knowledge}` | Compact knowledge packet |
| `{:status, stream_or_task_id}` | Task/stream state, or `{:error, :not_found}` |
| `{:atlas}` | Bounded memory graph projection |

Read tools keep the Stack's authenticated partition. They disable attention/graph
reinforcement, reclustering and secret reveal; retries must not write memory.
The standalone API keeps its original reinforcement/reveal behavior and returns
native structs. Configure embedding providers on the Engine to test vector
retrieval quality; lexical retrieval also works without a provider.

All write tools require an explicit installation binding, an allowed GAM operation and,
when used in a Skill, a matching `governed:` allowance:

```elixir
install Spectre.Mnemonic, automatic: false,
  bind: [remember: :save_note, forget: :forget_note, learn: :save_knowledge] do
  isolate_by([:agent, :subject])
end

# These produce governed proposals; they do not write in the callback.
mnemonic(ctx, {:remember, text, kind: :research}, on_result: :saved)
mnemonic(ctx, {:forget, memory_id}, on_result: :forgotten)
mnemonic(ctx, {:learn, "Release checklist\n- Run tests"}, on_result: :learned)
```

The closed write catalogue also supports `signal`, `put_mental_model`,
`verify_observation`, `link`, `merge_entities`, `unmerge_entities`, `consolidate`,
`consolidate_observations`, `compact_knowledge` and `sweep_expired`. Bind only the
operations the application needs. `link` takes source ID, relation and target ID;
merge/unmerge take winner and loser IDs; verification takes an observation ID.
Maintenance operations take a one-element tuple, e.g. `{:consolidate}`.

Allowed request options are deliberately operation-specific: search/recall/reflect
accept bounded limits and query budgets; the three specialized searches accept
`limit`; atlas accepts `max_nodes`/`max_edges`; remember/signal accept `kind`,
`stream`, `task_id`, `tags`, `metadata`, `extract_entities?`; learn accepts `name`
and `metadata`; verification accepts `relation`, `source_id`, `confidence_delta`;
consolidate accepts `min_attention`. Other operations accept no request options.
Unsupported/duplicate options fail before execution. Requests cannot override
`scope`, subject, engine, runtime, namespace, adapters, authorization or command ID.

`forget` hides the selected record from normal retrieval; it is not physical
partition erasure and does not imply deletion of every related entity. The native
`erase_partition`, `export`, `artifact`, `reveal`, and engine `health` APIs remain
host/admin integrations, not automatically exposed tools. `load_knowledge` is
available natively as an alias; the helper uses the single name `knowledge`.

An admitted executor calls `ServerTool.execute(operation, prepared_args, context)`
with the same frozen operation/options/identity it reviewed. The resulting
receipt must become GAM Outcome evidence. Installation does not authorize it;
see the [GAM manifesto](https://spectre.guide/en/governed-act-model).

## Engine ownership, partition and consent

Supervise `Spectre.Stack.Runtime` with a **stable name**, then supply that name
to the Server; Spectre passes it to the admitted effect adapter:

```elixir
children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.MemoryAI, name: MyApp.MemoryRuntime,
   packages: [mnemonic: [data_root: "var/memory", namespace: "notes"]]}
]
```

Start the Server with `agent: MyApp.MemoryAgent`,
`stack_runtime: MyApp.MemoryRuntime`,
`identity: %{subject: account_id}` and
`gam: [operations: %{save_note: [confirm: true]}]`. Because `remember` is bound to
`:save_note`, that operation must be allowed. Spectre freezes the authenticated
partition into the Candidate and reconstructs it for the registered executor.
The model cannot select its own partition. See the
[partition guide](docs/MIGRATING_TO_SPECTRE_0_4.md#authenticated-partition).

Use the **block DSL** `isolate_by([:subject])`; it is not an installation keyword
option. Missing `stack_runtime` or required subject fails closed. Explicit tools
do not fall back to the compatibility DefaultEngine. Multiple Engines can run
in one VM, but one durable `storage_id` must have only one writer across nodes.

## Results and persistence

Recall delivers `{:ok, packet_map}`; a successful governed save delivers the
core's `{:governed, result}`. Packet maps use explicit per-record field
allowlists, ISO timestamps and locked secret placeholders. Runtime options,
raw input, generic record metadata, vectors and encryption material are not
copied to checkpoints. Direct standalone calls retain native structs.

The executor uses `Spectre.Mnemonic.ServerTool.execute/3` only after admission.
A trusted command ID becomes `operation_id` for durable correlation; a host
explicit override takes precedence. This is **not whole-ingestion idempotency**:
an uncertain write must be reconciled, not blindly retried. The Server owns
pending consent, expiry/resumption and result delivery; the Engine owns memory.

## Where GAM participates

The [Governed Act Model manifesto](https://spectre.guide/en/governed-act-model)
distinguishes evidence, bounded authority, admitted Acts and unresolved duties.
An installed tool or a model proposal is not user consent. Spectre's default
cognitive path can classify, select, observe and prepare proposals without
requesting end-user permission for every computation. The application configures
the governed operations and their bindings; protected disclosure or resource use
can also belong to that surface. AgentServer automatically coordinates GAM and
registered effect adapters, including consent when required. Root and Skill
Servers share one Domain; no application GAM Host is needed. Uncertain effects
require reconciliation, not a blind retry.

## Memory capabilities and documentation

- [Direct memory APIs and workflows](docs/STANDALONE.md)
- [Writing, embeddings, graphs and secrets](docs/MEMORY_GUIDE.md)
- [Retrieval and knowledge](docs/RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence, operations and erasure](docs/PERSISTENCE_AND_OPERATIONS.md)
- [Public API contract](docs/PUBLIC_API.md)
- [Engine 0.2 migration](docs/MIGRATING_TO_0_2.md)
- [Historical Instance integration](docs/LEGACY_0_3.md)

## Use inside a reusable Skill

The `mnemonic` helper is generated in a Skill callback module with
`use Spectre.Server, tools: MyApp.AI`, using the same installed Stack. A
`Spectre.Skill` with `server:` has a separate GenServer, local assigns, workers,
streams, pending intentions and checkpoint key.

**It uses the root AgentServer's same automatic GAM integration, Domain and
authority ledger.** Configure `gam:` once on the root. Mounting a Skill creates
no new Domain or grant and needs no additional Host or consent ingress. Shared
Stack resources stay in their existing supervised runtime.

Agent and Skill workers can run concurrently; the shared kernel orders admission.
A governed effect must be enabled in root `operations` and permitted by the
mount's `governed:` references. Each Skill proposal records its mount and
invocation provenance. Consent identifies the originating Skill and exact
presentation: approving an email cannot approve another Skill's memory write.
Timer closure is recorded in the same Domain and does not erase a Duty.
Ordinary cognitive operations retain their configured provider boundary.

See the [core Skill ownership and consent guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md),
[automatic GAM responsibilities](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MANAGED_GAM.md)
and [two-Skill LiveView showcase](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/DEMO.md).

## Managed GAM execution registration

The optional `c:Spectre.Stack.Installable.effects/1` callback registers immutable
execution adapters for Spectre 0.4 managed GAM. Mnemonic registers only writes selected by `bind:`. The admitted execution uses the authenticated memory partition; reads keep their cognitive, non-mutating path.

The effect registration is included in the compiled installation digest and is
checked again before execution. It grants no authority: the application enables
operations and the GAM kernel admits each concrete consequence before the adapter
runs. AgentServer owns GAM automatically in every environment. Native package
APIs remain available outside the AgentServer loop; their caller owns that boundary.
Adapters implement `execute_effect/3` and distinguish successful observations,
definitive no-effect and uncertain outcomes; uncertain effects are not retried.
