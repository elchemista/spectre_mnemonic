# Memory in AgentServer

[Setup and first example](../README.md) · [Core 0.3 migration](MIGRATING_TO_SPECTRE_0_4.md) · [Public API](PUBLIC_API.md)

## Choosing a memory operation

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

Spectre calls the registered effect adapter only after GAM admission and records
its result as Outcome evidence. Application callbacks return helper commands;
they do not call the executor directly.

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


## Skills and recovery

Use the same Stack and helper in a Skill Server. Enable bound writes in root
`gam.operations` and the mount's `governed:` references. Configure identity and
the shared Stack runtime on the root; a mount does not create a second Engine
or GAM Domain. See the [core Skill guide](https://github.com/elchemista/spectre/blob/0.4.0/docs/SKILLS.md).
