# SpectreMnemonic

SpectreMnemonic is an Elixir memory engine for live applications and agents. It
keeps recent memory in ETS, links related moments into a graph, persists durable
records through append-only stores, and retrieves context with text ranking,
graph expansion, optional embeddings, and hybrid durable search.

It is a memory layer, not an application database. Use it to remember events,
preferences, decisions, facts, documents, and tool output; then retrieve the
evidence an application or agent needs for its next action.

```elixir
{:ok, _memory} =
  SpectreMnemonic.remember("Alice's email is alice@example.com",
    scope: {:subject, "alice"},
    kind: :personal_fact,
    persist?: true
  )

{:ok, packet} =
  SpectreMnemonic.recall("How can I contact Alice?",
    scope: {:subject, "alice"}
  )

Enum.map(packet.moments, & &1.text)
```

## Choose the right entry point

| Goal | Call | Returns |
| --- | --- | --- |
| Store one immediate event | `signal/2` | signal and searchable moment |
| Ingest richer text or structured input | `remember/2` | intake packet with root, chunks, summaries, entities, and links |
| Build an active-memory context packet | `recall/2` | ranked evidence and related graph context |
| Search active and durable memory | `search/2` | flat list of search results |
| Build source-linked reasoning evidence | `reflect/2` | mental models, observations, raw memories, and citations |
| Persist selected active memory | `consolidate/1` | durable knowledge records |
| Suppress selected memory logically | `forget/2` | number of forgotten records |
| Physically erase one partition | `erase_partition/1` | verified erasure report |

The complete high-level call index is in the
[API guide](docs/API_GUIDE.md). The exact compatibility surface is defined by
the [public API manifest](docs/PUBLIC_API.md).

## Installation

SpectreMnemonic is distributed from GitHub:

```elixir
def deps do
  [
    {:spectre, "~> 0.3.3"},
    {:spectre_mnemonic, github: "elchemista/spectre_mnemonic", branch: "main"}
  ]
end
```

Configure a stable namespace. It identifies the owning application and must
remain unchanged across deployments:

```elixir
config :spectre_mnemonic,
  namespace: "my_app_memory",
  hot_memory: [
    max_moments_per_scope: 1_000,
    max_moments_per_namespace: 10_000
  ]
```

The OTP application starts the ETS owner, active focus, persistence manager,
durable index, recall engine, and progressive-knowledge writer.

See [Getting started](docs/GETTING_STARTED.md) for supervision, scopes,
configuration, and a complete first workflow.

## Five-minute workflow

### 1. Remember durable information

```elixir
scope = {:project, "checkout"}

{:ok, intake} =
  SpectreMnemonic.remember(
    "The checkout deploy moved to Friday because the payment sandbox is unavailable.",
    scope: scope,
    stream: :planning,
    task_id: "deploy-42",
    tags: [:checkout, :release],
    persist?: true
  )

intake.root
intake.associations
```

`remember/2` can chunk long input, create summaries and categories, extract an
entity/timeline graph, and aggregate related memory inside the same partition.
Use `signal/2` when you only need one immediate event.

### 2. Recall a bounded evidence packet

```elixir
{:ok, packet} =
  SpectreMnemonic.recall("Why did the checkout deploy move?",
    scope: scope,
    budget: :mid,
    max_tokens: 2_000,
    graph_depth: 2,
    trace: true
  )

packet.moments
packet.observations
packet.mental_models
packet.knowledge
packet.trace
```

Recall gathers evidence; it does not generate a final prose answer. The caller
can inspect the packet, render it, or pass it to an agent or language model.

### 3. Search durable history

```elixir
{:ok, results} =
  SpectreMnemonic.search("payment sandbox deploy",
    scope: scope,
    limit: 10,
    min_vector_similarity: 0.45
  )

Enum.map(results, &{&1.source, &1.family, &1.id, &1.score})
```

Search combines active candidates with the rebuildable durable index. It works
without embeddings and adds vector/signature ranking when embeddings exist.

### 4. Consolidate or forget

```elixir
{:ok, _knowledge} =
  SpectreMnemonic.consolidate(scope: scope, min_attention: 1.0)

{:ok, _count} =
  SpectreMnemonic.forget({:task, "deploy-42"}, scope: scope)
```

Forgetting is logical suppression. Physical partition erasure is a separate,
explicit operation described in
[Persistence and operations](docs/PERSISTENCE_AND_OPERATIONS.md).

## Spectre Agent integration

Install Mnemonic in a Spectre Stack:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack, id: :my_app

  install Spectre.Mnemonic do
    store MyApp.MemoryStore
    isolate_by [:agent, :subject, :conversation]
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end
```

Spectre then calls Mnemonic through its normal memory lifecycle. Subject
isolation requires an explicit canonical `%Spectre.Subject{}`; channel sender
ids are never treated as cross-channel identity.

The full setup, isolation behavior, and direct adapter calls are documented in
[Getting started](docs/GETTING_STARTED.md#spectre-agent-integration).

## Main capabilities

- Active ETS memory with scoped bounds, streams, tasks, temporal validity, and
  attention.
- Rich intake for text, maps, lists, documents, chats, tasks, and tool events.
- Partition-local entity resolution, typed graph links, reversible merges,
  Episodes, and deterministic Atlas projections.
- Optional caller-provided or adapter-generated embeddings normalized, pooled,
  and indexed through Vettore without requiring Nx.
- BM25-style durable search with text, entity, vector, binary-signature, and
  lifecycle signals.
- Evidence-grounded observations, curated mental models, and structured
  reflection packets.
- Governance states, contradiction tracking, provenance, freshness decay, and
  retention sweeps.
- Compact progressive knowledge and reusable learned skills in
  `knowledge.smem`.
- Encrypted secret memory with explicit authorization before reveal.
- Verified `.mnemonic` exports and durable-first physical partition erasure.
- Plugs and adapters for extraction, embeddings, persistence, compaction,
  labels, secrets, and action runtimes.

## Documentation map

- [Getting started](docs/GETTING_STARTED.md) — installation, namespace, scopes,
  first workflow, and Spectre integration.
- [Writing and connecting memory](docs/MEMORY_GUIDE.md) — `signal`, `remember`,
  temporal data, plugs, embeddings, graphs, artifacts, actions, and secrets.
- [Retrieval and knowledge](docs/RETRIEVAL_AND_KNOWLEDGE.md) — recall, search,
  reflection, observations, mental models, governance, and progressive
  knowledge.
- [Persistence and operations](docs/PERSISTENCE_AND_OPERATIONS.md) — stores,
  compaction, scheduler, export, erasure, evaluation, and operational limits.
- [API guide](docs/API_GUIDE.md) — every `SpectreMnemonic` facade call grouped by
  use case, with return values and examples.
- [`.mnemonic` format](docs/MNEMONIC_FORMAT.md) — normative container, privacy,
  validation, and reader contract.
- [Public API manifest](docs/PUBLIC_API.md) — normative compatibility surface.

## Important boundaries

- Every operation addresses exactly one `{namespace, scope}` partition.
  Omitting `scope:` selects only the unscoped partition.
- `recall/2` and `reflect/2` return evidence, not generated prose.
- `forget/2` hides memory logically; `erase_partition/1` performs verified
  physical erasure for supported stores.
- `.mnemonic` read and stream calls validate detached exports. Format version 1
  does not import or restore data into live memory.
- Embeddings are optional. Text, fingerprints, graph traversal, and durable
  scoring continue to work without a model.
- Action recipes are inert data unless an application explicitly configures an
  action runtime adapter.

## Example and development

Run the local end-to-end demonstration:

```bash
mix run example/demo.exs
```

Run the standard quality checks:

```bash
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test
```

The default test suite is offline. Real local embedding and Spectre Agent test
commands are listed in
[Persistence and operations](docs/PERSISTENCE_AND_OPERATIONS.md#evaluation-and-development).
