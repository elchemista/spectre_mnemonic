# Retrieval and knowledge

SpectreMnemonic exposes several read models for different consumers. Recall is
the general context builder; search returns flat candidates; reflection prepares
source-linked reasoning evidence; observations, mental models, and progressive
knowledge provide increasingly curated views.

## `recall/2`: build an evidence packet

```elixir
{:ok, packet} =
  SpectreMnemonic.recall("Why was checkout deployment moved?",
    scope: {:project, "checkout"},
    limit: 8,
    budget: :mid,
    max_tokens: 2_000,
    graph_depth: 2,
    max_graph_nodes: 100,
    min_vector_similarity: 0.5,
    trace: true
  )
```

Recall ranks visible active moments, merges embedding-index candidates, expands
the graph, includes selected durable results, and applies a best-effort token
budget.

The returned `SpectreMnemonic.Recall.Packet` contains:

| Field | Contents |
| --- | --- |
| `moments` | ranked active moments and locked/revealed secrets |
| `search_results` | durable candidates |
| `observations` | derived evidence-grounded claims |
| `mental_models` | curated stable guidance |
| `episodes` | durable or active Atlas clusters containing recalled moments |
| `knowledge` | compact progressive knowledge |
| `artifacts` | attached artifact records |
| `associations` | graph edges relevant to selected evidence |
| `action_recipes` | attached inert recipes |
| `active_status` | stream/task state |
| `trace` | optional graph path explanation |
| `confidence` | packet-level evidence confidence |
| `usage` | estimated budget usage |

Recall gathers evidence and never writes the final prose answer.

### Recall options

| Option | Effect |
| --- | --- |
| `:scope` | selects exactly one partition |
| `:limit` | maximum primary candidates; non-negative |
| `:budget` | `:low`, `:mid`, or `:high` graph/budget preset |
| `:max_tokens` | positive best-effort packet budget |
| `:observation_limit` | cap for observations |
| `:mental_model_limit` | cap for mental models |
| `:include_observations` | include or exclude observations |
| `:include_mental_models` | include or exclude curated models |
| `:include_knowledge` | include or exclude progressive knowledge |
| `:valid_at` | evaluate temporal validity at a specific time |
| `:graph_depth` | maximum graph expansion depth |
| `:max_graph_nodes` | hard graph-node cap, including seeds |
| `:hop_decay` | `0.0..1.0` activation decay by hop |
| `:activation_floor` | `0.0..1.0` minimum activation |
| `:prune_threshold` | `0.0..1.0` edge/path pruning threshold |
| `:relations`, `:relation_types` | allowed relation atoms or `:all` |
| `:exclude_relations` | explicit relation exclusions |
| `:min_vector_similarity` | `0.0..1.0` semantic candidate floor |
| `:overfetch` | extra embedding-index candidates |
| `:trace` | include graph paths and Episode context |
| `:plasticity?` | allow eligible traversed edges to be reinforced |

`:member_of` and `:same_as` are excluded from normal traversal by default.
Request them explicitly only when their structural semantics are useful:

```elixir
SpectreMnemonic.recall("episode context",
  scope: scope,
  relations: [:mentions, :caused_by, :member_of]
)
```

`max_tokens` is best-effort. Recall may keep one oversized primary item when
dropping it would make the packet empty.

### Explain a retrieval

```elixir
{:ok, packet} =
  SpectreMnemonic.recall("What caused the rollback?",
    scope: {:project, "checkout"},
    trace: true
  )

Enum.each(packet.trace, fn {memory_id, path} ->
  IO.inspect(path, label: "retrieval path for #{memory_id}")
end)
```

Trace data is useful for diagnostics and UI explanations. It is not a claim that
every traversed association proves the answer.

## `search/2`: active and durable candidates

```elixir
{:ok, results} =
  SpectreMnemonic.search("payment retry decision",
    scope: {:project, "checkout"},
    limit: 10
  )
```

Every item is a `%SpectreMnemonic.SearchResult{}`:

```elixir
Enum.map(results, fn result ->
  %{
    source: result.source,
    family: result.family,
    id: result.id,
    rank: result.rank,
    score: result.score,
    state: result.state,
    record: result.record
  }
end)
```

Active results come from recall. Durable results come from the local rebuildable
index and configured stores. One `SpectreMnemonic.QueryContext` is built per
request so cue embedding is computed once and reused across ranking paths.

Use search for a flat result list. Use recall when the consumer needs connected
context, artifacts, knowledge, and explanations.

## Observations

Observations are derived claims with source ids, evidence, confidence, temporal
metadata, proof counts, contradiction counts, trend, and lifecycle state.

Derive observations from visible active and durable memory:

```elixir
{:ok, observations} =
  SpectreMnemonic.consolidate_observations(
    scope: {:project, "checkout"},
    include_durable?: true,
    persist?: true
  )
```

The deterministic extractor recognizes:

- facts;
- preferences;
- decisions;
- patterns;
- project state.

Search them:

```elixir
{:ok, matches} =
  SpectreMnemonic.search_observations("release ownership",
    scope: {:project, "checkout"},
    limit: 5
  )
```

Append supporting or negative evidence:

```elixir
{:ok, verified} =
  SpectreMnemonic.verify_observation(hd(matches),
    scope: {:project, "checkout"},
    relation: :supports,
    source_id: "mom_123",
    confidence_delta: 0.08
  )
```

`:relation` accepts `:supports`, `:weakens`, or `:contradicts`. Verification
preserves the prior evidence trail and recomputes confidence, counts, trend, and
state.

## Mental models

Mental models are curated, durable guidance for recurring questions. Store one
from a map:

```elixir
{:ok, model} =
  SpectreMnemonic.put_mental_model(%{
    title: "Payment Retry Policy",
    query: "How should payment retries work?",
    answer: "Use bounded retries with idempotency keys.",
    scope: {:project, "checkout"},
    source_ids: ["mom_123"],
    citations: [%{type: :memory, id: "mom_123"}],
    state: :pinned
  })
```

Or from text:

```elixir
SpectreMnemonic.put_mental_model("""
Incident review
Separate detection, mitigation, and prevention.
""",
  scope: {:team, "reliability"}
)
```

Search curated models:

```elixir
{:ok, models} =
  SpectreMnemonic.search_mental_models("payment retries",
    scope: {:project, "checkout"},
    limit: 3
  )
```

Models default to durable persistence and a promoted lifecycle state. Use
`persist?: false` for an active-only model.

## `reflect/2`: prepare reasoning evidence

Reflection combines curated models first, ranked observations second, and raw
recall evidence last:

```elixir
{:ok, reflection} =
  SpectreMnemonic.reflect("What is the checkout retry policy?",
    scope: {:project, "checkout"},
    mental_model_limit: 3,
    observation_limit: 5,
    max_tokens: 4_096,
    directives: [:prefer_verified_evidence],
    disposition: :answer_with_citations
  )

reflection.mental_models
reflection.observations
reflection.raw_memories
reflection.evidence
reflection.citations
```

`reflect/2` returns a `SpectreMnemonic.Reflection.Packet`. It does not call a
language model or generate prose. Response generation belongs to the calling
Spectre layer or application.

Observation evidence is ranked in this order:

1. decisions;
2. preferences;
3. project state;
4. patterns;
5. facts.

## Governance and contradictions

Durable lifecycle states are append-only records:

```elixir
[
  :candidate,
  :short_term,
  :promoted,
  :pinned,
  :stale,
  :contradicted,
  :forgotten
]
```

Pin a memory when writing it:

```elixir
{:ok, %{moment: moment}} =
  SpectreMnemonic.signal("Payment retry policy is stable",
    scope: {:project, "checkout"},
    memory_state: :pinned,
    persist?: true
  )

SpectreMnemonic.Governance.state_for(moment.id,
  scope: {:project, "checkout"}
)
#=> :pinned
```

Default durable-search visibility:

- `:forgotten` and `:contradicted` are hidden;
- `:stale` is demoted;
- `:promoted` is boosted;
- `:pinned` receives the strongest boost.

### Structured fact replacement

Simple facts such as e-mail, phone, age, status, birthday, deadline, and owner
use `{normalized_subject, attribute}` as their upsert key:

```elixir
{:ok, %{moment: old}} =
  SpectreMnemonic.signal("Alice email is old@example.com",
    scope: {:subject, "alice"},
    persist?: true
  )

{:ok, %{moment: new}} =
  SpectreMnemonic.signal("Alice email is new@example.com",
    scope: {:subject, "alice"},
    persist?: true
  )

SpectreMnemonic.Governance.state_for(old.id, scope: {:subject, "alice"})
#=> :contradicted

SpectreMnemonic.Governance.state_for(new.id, scope: {:subject, "alice"})
#=> :promoted
```

Pinned facts are not replaced automatically.

### Provenance

Generated durable records carry normalized provenance in
`metadata.provenance`:

```elixir
%{
  source_ids: ["mom_123"],
  source_span: nil,
  provider: :consolidator,
  confidence: 1.0,
  occurred_at: occurred_at,
  observed_at: observed_at,
  last_verified_at: last_verified_at,
  valid_from: valid_from,
  valid_until: valid_until
}
```

Applications can use provenance to explain where evidence came from and whether
it was extracted, generated, verified, consolidated, or compacted.

## Progressive knowledge

`knowledge.smem` is a compact append-only log separate from hot ETS memory and
the general persistence families. Supported event types are:

- `:summary`;
- `:skill`;
- `:latest_ingestion`;
- `:fact`;
- `:procedure`;
- `:compaction_marker`.

### Learn a reusable skill

```elixir
{:ok, learned} =
  SpectreMnemonic.learn("""
  Debug local replay
  - inspect active.smem
  - check tombstones
  - compare replayed ids
  """,
    scope: {:team, "platform"}
  )

learned.event.name
learned.event.steps
```

Structured input can provide `:name`, `:steps`, `:rules`, `:examples`,
`:text`, and `:metadata`.

### Search compact knowledge

```elixir
{:ok, matches} =
  SpectreMnemonic.search_knowledge("replay storage",
    scope: {:team, "platform"},
    limit: 5
  )
```

This path scores matching events without building the full knowledge packet.

### Load a bounded packet

```elixir
{:ok, knowledge} =
  SpectreMnemonic.load_knowledge(
    scope: {:team, "platform"},
    max_loaded_bytes: 8_000,
    max_skills: 10,
    max_latest_ingestions: 10,
    max_facts: 20,
    max_procedures: 10
  )
```

`knowledge/1` is the equivalent primary name; `load_knowledge/1` is a
descriptive alias.

### Compact knowledge

```elixir
{:ok, %{events: events, count: count}} =
  SpectreMnemonic.compact_knowledge(
    scope: {:team, "platform"},
    max_loaded_bytes: 8_000,
    max_latest_ingestions: 10
  )
```

Without an adapter, compaction is deterministic. Configure application-specific
or model-backed behavior:

```elixir
config :spectre_mnemonic,
  compact_adapter: MyApp.KnowledgeCompactAdapter
```

The adapter implements
`c:SpectreMnemonic.Knowledge.Compact.Adapter.compact/2`.

Low-level applications can append events through
`SpectreMnemonic.Knowledge.Base.append/2`, but the facade calls above cover the
normal learn/search/load/compact workflow.

## Task status

Signals with a `:task_id` update active status:

```elixir
SpectreMnemonic.signal("Working on durable search",
  scope: {:project, "search"},
  task_id: "search-1"
)

SpectreMnemonic.status("search-1", scope: {:project, "search"})
#=> {:ok, %{status: :active}}
```

`status/2` accepts a task id or stream name.

## Related guides

- [Writing and connecting memory](MEMORY_GUIDE.md)
- [Persistence and operations](PERSISTENCE_AND_OPERATIONS.md)
- [Complete facade API guide](API_GUIDE.md)
