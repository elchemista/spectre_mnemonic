# Spectre Mnemonic for core 0.4

A supervised Elixir memory engine with an explicit AgentServer integration:
recall evidence during cognition; save through an admitted host operation when
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

## Engine ownership, partition and consent

Supervise `Spectre.Stack.Runtime` with a **stable name**, then supply that name
to the Server and to its host executor:

```elixir
children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.MemoryAI, name: MyApp.MemoryRuntime,
   packages: [mnemonic: [data_root: "var/memory", namespace: "notes"]]}
]
```

Start the Server with `agent: MyApp.MemoryAgent`,
`stack_runtime: MyApp.MemoryRuntime`,
`identity: %{subject: Spectre.Subject.new(account_id)}` and the host's
`gam: {Spectre.Server.GAM, gam_config}`. Because `remember` is bound to
`:save_note`, startup checks that this host binding exists. The host's candidate
factory copies the authenticated subject into the candidate consequence; the
executor reconstructs that committed identity. The model cannot select its
own partition. See the [executor example](docs/MIGRATING_TO_SPECTRE_0_4.md#host-executor-and-partition).

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
requesting end-user permission for every computation. The host declares the
governed surface and its bindings; protected disclosure or resource use can
also belong to that surface. GAM records the governed lifecycle and gates the
host executor. Uncertain effects require reconciliation, not a blind retry.

## Memory capabilities and documentation

- [Direct memory APIs and workflows](docs/STANDALONE.md)
- [Writing, embeddings, graphs and secrets](docs/MEMORY_GUIDE.md)
- [Retrieval and knowledge](docs/RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence, operations and erasure](docs/PERSISTENCE_AND_OPERATIONS.md)
- [Public API contract](docs/PUBLIC_API.md)
- [Engine 0.2 migration](docs/MIGRATING_TO_0_2.md)
- [Historical Instance integration](docs/LEGACY_0_3.md)
