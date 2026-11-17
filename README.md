# Spectre Mnemonic

Supervised working and durable memory for Elixir applications. Ingest text,
structured data and events; recall relevant context, search stored knowledge,
and connect memories through graphs and optional embeddings.

Use the standalone `SpectreMnemonic` API in any Elixir application. An optional
integration adds memory tools to [Spectre 0.4](https://github.com/elchemista/spectre).

[Standalone quickstart](#use-mnemonic-without-spectre) ·
[Spectre 0.4 integration](#integrate-with-spectre-04) ·
[Documentation](#documentation)

## Use Mnemonic without Spectre

### Install

Add only Mnemonic to your application:

```elixir
defp deps do
  [
    {:spectre_mnemonic, "~> 0.2.0"}
  ]
end
```

### Supervise an Engine

Add an Engine to your application's supervision tree:

```elixir
children = [
  {SpectreMnemonic.Engine,
   name: MyApp.Memory,
   storage_id: "my-app-memory",
   namespace: "my_app",
   data_root: "data/memory"}
]
```

Each Engine owns its memory, indexes, persistence and maintenance lifecycle.
Keep `storage_id` stable across restarts. Use `scope` to select an
application-defined partition, such as one customer or project.

### Remember, recall and search

After starting the supervised Engine:

```elixir
scope = {:project, "checkout"}

{:ok, _intake} =
  SpectreMnemonic.remember("The checkout release moved to Friday.",
    engine: MyApp.Memory,
    scope: scope,
    persist?: true
  )

{:ok, packet} =
  SpectreMnemonic.recall("When is the checkout release?",
    engine: MyApp.Memory,
    scope: scope
  )

Enum.map(packet.moments, & &1.text)

{:ok, hits} =
  SpectreMnemonic.search("checkout release",
    engine: MyApp.Memory,
    scope: scope,
    limit: 5
  )
```

`remember/2` ingests the information; `persist?: true` writes it durably.
`recall/2` returns a context packet with ranked memories and related evidence.
`search/2` returns a flat list of active and durable hits. Your application
chooses how to display these results or pass them to a model.

These calls require neither an agent nor GAM approval. Text retrieval works
without an embedding model; add caller-provided vectors or configure an
embedding adapter when you need vector similarity.

### Memory operations

| Goal | API |
| --- | --- |
| Record one immediate event | `signal/2` |
| Ingest text or structured information | `remember/2` |
| Build a context packet | `recall/2` |
| Search active and durable memory | `search/2` |
| Gather source-linked reasoning evidence | `reflect/2` |
| Promote selected active memories to durable knowledge | `consolidate/1` |
| Logically suppress selected memories | `forget/2` |
| Physically erase a partition | `erase_partition/1` |

The [standalone guide](docs/STANDALONE.md) covers complete workflows. See
[writing and connecting memory](docs/MEMORY_GUIDE.md) for ingestion, graphs,
embeddings and encrypted secrets, and [persistence and operations](docs/PERSISTENCE_AND_OPERATIONS.md)
for storage adapters, recovery and erasure.

## Integrate with Spectre 0.4

Add Spectre when your application uses its Stack → Agent → Server runtime:

```elixir
defp deps do
  [
    {:spectre, "~> 0.4.0"},
    {:spectre_mnemonic, "~> 0.2.0"}
  ]
end
```

The integration module is `Spectre.Mnemonic`; the standalone API remains
`SpectreMnemonic`. Mnemonic's version is independent of the Spectre core version.

![Optional Spectre 0.4 memory integration](docs/assets/readme-architecture.svg)

[Diagram source](docs/assets/readme-architecture.mmd).

Here the Stack runtime owns the Engine. The host supplies the authenticated
memory partition. Registered writes pass through GAM, the Governed Act Model;
the host configures which operations require human consent.

### Stack → Agent → Server

```elixir
defmodule MyApp.MemoryAI do
  use Spectre.Stack
  install Spectre.Mnemonic, automatic: false, bind: [remember: :save_note] do
    isolate_by([:subject])
  end
end

defmodule MyApp.MemoryAgent do
  use Spectre.Agent, stack: MyApp.MemoryAI, server: MyApp.MemoryServer
  flow :notes do
    on(:remember, regex: ~r/^remember /i)
    on(:recall, regex: ~r/^recall /i)
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
```

`mnemonic/3` is generated from `tools/1`; the package does not export a helper
that you should import. `automatic: false` removes the automatic recall/persist
port while retaining the Engine resource and explicit tools. This prevents
implicit ingestion before your save-consent flow. The compatibility default is
`automatic: true`; changing it requires reviewing the application's behavior.

### Engine ownership, partition and consent

Supervise `Spectre.Stack.Runtime` with a **stable name**, then supply that name
to the Server; Spectre passes it to the admitted effect adapter:

```elixir
children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.MemoryAI, name: MyApp.MemoryRuntime,
   packages: [mnemonic: [data_root: "var/memory", namespace: "notes"]]}
]
```

Start the Server after supervising the Stack runtime. Supply the authenticated
account identifier from your host:

```elixir
{:ok, server} = Spectre.Server.start_link(
  agent: MyApp.MemoryAgent,
  stack_runtime: MyApp.MemoryRuntime,
  identity: %{subject: account_id},
  consumer: self(),
  gam: [operations: %{save_note: [confirm: true]}])

{:ok, interaction} = Spectre.Server.input(server, "recall release notes")
```

The bound `:save_note` operation is enabled here with confirmation. Spectre
freezes the authenticated partition and runs the registered executor after admission.
The model cannot select its own partition. See the
[partition guide](docs/MIGRATING_TO_SPECTRE_0_4.md#authenticated-partition).

Use the **block DSL** `isolate_by([:subject])`; it is not an installation keyword
option. Missing `stack_runtime` or required subject fails closed. Explicit tools
do not fall back to the compatibility DefaultEngine. Multiple Engines can run
in one VM, but one durable `storage_id` must have only one writer across nodes.

### More AgentServer operations

Use `{:search, cue, limit: 5}` for ranked hits, `{:recall, cue}` for a context
packet and `{:reflect, cue}` for source-linked evidence. Put memory options inside
the operation tuple and Server options such as `on_result:` outside it.
See the [AgentServer memory guide](docs/AGENT_SERVER.md) for all reads, bound writes,
portable results and recovery. Reads do not reinforce memory or reveal secrets.

## Documentation

- [Standalone APIs and workflows](docs/STANDALONE.md)
- [Getting started and Engine configuration](docs/GETTING_STARTED.md)
- [Writing, embeddings, graphs and secrets](docs/MEMORY_GUIDE.md)
- [Retrieval and knowledge](docs/RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence, operations and erasure](docs/PERSISTENCE_AND_OPERATIONS.md)
- [Public API contract](docs/PUBLIC_API.md)
- [Engine 0.2 migration](docs/MIGRATING_TO_0_2.md)
- [Spectre 0.4 AgentServer integration](docs/AGENT_SERVER.md)
- [Migration from Spectre core 0.3](docs/MIGRATING_TO_SPECTRE_0_4.md)
- [Historical Instance integration](docs/LEGACY_0_3.md)
- [Full documentation index](docs/INDEX.md)

The generated `mnemonic` helper also works in [Skill Server callbacks](https://github.com/elchemista/spectre/blob/0.4.0/docs/SKILLS.md).
Skills share the root's GAM Domain; enable governed operations on the root and
allow them in the mount's `governed:` references. The
[core tool guide](https://github.com/elchemista/spectre/blob/0.4.0/docs/STACK_TOOLS.md) covers scheduling and recovery;
[Managed GAM](https://github.com/elchemista/spectre/blob/0.4.0/docs/MANAGED_GAM.md) covers consent and registered execution.

For sibling checkouts, use `path: "../spectre_mnemonic"` and, when integrating,
`path: "../spectre"`. Package integration tests use `SPECTRE_PATH=../spectre mix test`.

See the [LiveView demo](https://github.com/elchemista/demo_spectre) for an application,
the [Spectre guides](https://spectre.guide) for articles, and the
[release audit](https://github.com/elchemista/spectre/blob/0.4.0/docs/RELEASE_0_4.md) for verified revisions.
