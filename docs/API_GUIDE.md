# API guide

This guide explains every call on the SpectreMnemonic facade and the companion
calls needed to read exports or integrate with Spectre. It is organized by job
rather than by internal module.

The exact versioned compatibility surface, including lower-level modules and
adapter callbacks, is the [public API manifest](PUBLIC_API.md).

## Conventions

Most calls accept a keyword list and return:

~~~elixir
{:ok, value}
{:error, reason}
~~~

Common options across the API:

| Option | Meaning |
| --- | --- |
| namespace | owning application identity; normally configured globally |
| scope | exactly one caller-owned memory partition |
| metadata | application context stored with created records |
| persist? | whether a newly created projection is immediately durable |
| occurred_at | when an event happened |
| observed_at | when memory learned it |
| last_verified_at | when evidence was last checked |
| valid_from, valid_until | temporal truth window |

Omitting scope selects only the unscoped partition. It is never a wildcard.

## Write memory

### signal/1 and signal/2

Records one immediate event and creates one searchable moment.

~~~elixir
{:ok, %{signal: signal, moment: moment}} =
  SpectreMnemonic.signal("Build passed",
    scope: {:project, "sdk"},
    task_id: "ci-42",
    kind: :tool,
    persist?: true
  )
~~~

Use it for chat turns, task updates, tool output, facts, or events whose shape is
already known.

### remember/1 and remember/2

Runs rich intake over text or structured input.

~~~elixir
{:ok, packet} =
  SpectreMnemonic.remember(document,
    scope: {:project, "sdk"},
    chunk_words: 180,
    extract_entities?: true,
    persist?: true
  )
~~~

Returns SpectreMnemonic.Intake.Packet with root, chunks, summaries, categories,
extracted nodes, graph associations, warnings, and persistence status.

### artifact/1 and artifact/2

Stores an artifact reference or binary payload.

~~~elixir
{:ok, artifact} =
  SpectreMnemonic.artifact("/tmp/report.txt",
    scope: {:project, "sdk"},
    content_type: "text/plain"
  )
~~~

When action_recipe is supplied, the result is a map containing both artifact
and action_recipe.

### learn/1 and learn/2

Stores a reusable skill in progressive knowledge.

~~~elixir
{:ok, %{event: event, seq: sequence}} =
  SpectreMnemonic.learn("Triage CI\n- inspect logs\n- isolate the failure",
    scope: {:team, "platform"}
  )
~~~

Text uses its first line as the skill name. Structured input may provide name,
steps, rules, examples, text, and metadata.

### put_mental_model/1 and put_mental_model/2

Stores curated stable guidance.

~~~elixir
{:ok, model} =
  SpectreMnemonic.put_mental_model(%{
    title: "Retry policy",
    query: "How should retries work?",
    answer: "Use bounded retries and idempotency keys.",
    scope: {:project, "checkout"},
    source_ids: ["mom_123"]
  })
~~~

Text, maps, and keyword lists are accepted. Models are durable by default.

## Retrieve memory

### recall/1 and recall/2

Builds a structured active-context packet.

~~~elixir
{:ok, packet} =
  SpectreMnemonic.recall("Why did deploy move?",
    scope: {:project, "checkout"},
    budget: :mid,
    max_tokens: 2_000,
    trace: true
  )
~~~

Use packet fields to access moments, durable candidates, observations, mental
models, Episodes, knowledge, artifacts, graph edges, action recipes, trace,
confidence, and token usage.

### search/1 and search/2

Returns a flat list across active and durable memory.

~~~elixir
{:ok, results} =
  SpectreMnemonic.search("deploy decision",
    scope: {:project, "checkout"},
    limit: 10
  )
~~~

Each SpectreMnemonic.SearchResult identifies source, family, id, rank, score,
lifecycle state, original record, namespace, and scope.

### reflect/1 and reflect/2

Builds source-linked reasoning evidence.

~~~elixir
{:ok, packet} =
  SpectreMnemonic.reflect("What is our retry policy?",
    scope: {:project, "checkout"},
    mental_model_limit: 3,
    observation_limit: 5
  )
~~~

Returns curated models, ranked observations, raw memory, evidence entries, and
citations. It does not generate prose.

### search_observations/1 and search_observations/2

Searches derived observations only.

~~~elixir
{:ok, observations} =
  SpectreMnemonic.search_observations("project owner",
    scope: {:project, "checkout"},
    limit: 5
  )
~~~

### search_mental_models/1 and search_mental_models/2

Searches curated mental models only.

~~~elixir
{:ok, models} =
  SpectreMnemonic.search_mental_models("retry policy",
    scope: {:project, "checkout"},
    limit: 3
  )
~~~

### knowledge/0 and knowledge/1

Loads one bounded progressive-knowledge packet.

~~~elixir
{:ok, knowledge} =
  SpectreMnemonic.knowledge(
    scope: {:team, "platform"},
    max_loaded_bytes: 8_000,
    max_skills: 10
  )
~~~

### load_knowledge/0 and load_knowledge/1

Descriptive alias for knowledge/1.

~~~elixir
{:ok, knowledge} =
  SpectreMnemonic.load_knowledge(scope: {:team, "platform"})
~~~

### search_knowledge/1 and search_knowledge/2

Searches compact knowledge events without loading the complete packet.

~~~elixir
{:ok, matches} =
  SpectreMnemonic.search_knowledge("replay storage",
    scope: {:team, "platform"},
    limit: 5
  )
~~~

### status/1 and status/2

Reads active status for a stream name or task id.

~~~elixir
{:ok, status} =
  SpectreMnemonic.status("deploy-42",
    scope: {:project, "checkout"}
  )
~~~

### atlas/0 and atlas/1

Returns the deterministic graph and Episode projection for one partition.

~~~elixir
{:ok, atlas} =
  SpectreMnemonic.atlas(
    scope: {:project, "checkout"},
    recluster: true
  )
~~~

The result contains nodes, edges, clusters, layout hints, statistics, and
explicit truncation flags.

## Derive and maintain knowledge

### consolidate/0 and consolidate/1

Promotes important active memory into durable knowledge.

~~~elixir
{:ok, records} =
  SpectreMnemonic.consolidate(
    scope: {:project, "checkout"},
    min_attention: 1.0,
    graph_depth: 1
  )
~~~

### consolidate_observations/0 and consolidate_observations/1

Derives evidence-grounded observations from active and durable memory.

~~~elixir
{:ok, observations} =
  SpectreMnemonic.consolidate_observations(
    scope: {:project, "checkout"},
    include_durable?: true,
    persist?: true
  )
~~~

### verify_observation/1 and verify_observation/2

Adds supporting, weakening, or contradicting evidence.

~~~elixir
{:ok, observation} =
  SpectreMnemonic.verify_observation(observation_id,
    scope: {:project, "checkout"},
    relation: :supports,
    source_id: "mom_123"
  )
~~~

### compact_knowledge/0 and compact_knowledge/1

Replaces progressive knowledge with a compact event set.

~~~elixir
{:ok, %{events: events, count: count}} =
  SpectreMnemonic.compact_knowledge(
    scope: {:team, "platform"},
    max_loaded_bytes: 8_000,
    max_latest_ingestions: 10
  )
~~~

Without an adapter, the strategy is deterministic. A configured compact
adapter can provide application-specific behavior.

## Connect graph records

### link/3 and link/4

Creates a typed weighted association between existing ids.

~~~elixir
{:ok, edge} =
  SpectreMnemonic.link(source_id, :supported_by, target_id,
    scope: {:project, "checkout"},
    weight: 0.8,
    persist?: true
  )
~~~

The weight range is 0.0 through 1.0.

### merge_entities/2 and merge_entities/3

Redirects a duplicate entity to a partition-local winner.

~~~elixir
{:ok, same_as_edge} =
  SpectreMnemonic.merge_entities(winner_id, loser_id,
    scope: {:subject, "alice"}
  )
~~~

Historical records are not rewritten.

### unmerge_entities/2 and unmerge_entities/3

Reverses one merge by tombstoning its same_as edge and restoring aliases.

~~~elixir
:ok =
  SpectreMnemonic.unmerge_entities(winner_id, loser_id,
    scope: {:subject, "alice"}
  )
~~~

## Secrets

### reveal/1 and reveal/2

Requests authorization and decrypts one locked secret.

~~~elixir
{:ok, revealed} =
  SpectreMnemonic.reveal(secret,
    secret_key: secret_key,
    authorization_context: %{user_id: current_user.id}
  )
~~~

Recall may return locked placeholders, but plaintext is available only after the
configured authorization adapter grants the explicit request.

Lower-level secret operations are available through SpectreMnemonic.Secrets:

| Call | Purpose |
| --- | --- |
| encrypt/3 | encrypt plaintext through the configured crypto adapter |
| reveal/2 | authorize and decrypt |
| maybe_reveal/2 | return a locked placeholder on denial |
| reveal_instruction/0 | describe the public reveal call |
| shred/1 and shred/2 | request optional partition-key destruction |

## Forget and erase

### forget/1 and forget/2

Logically suppresses matching memory.

~~~elixir
SpectreMnemonic.forget("mom_123", scope: scope)
SpectreMnemonic.forget({:task, "deploy-42"}, scope: scope)
SpectreMnemonic.forget({:stream, :planning}, scope: scope)
SpectreMnemonic.forget(fn moment -> expired?(moment) end, scope: scope)
~~~

Returns the number of affected records. Physical bytes can remain until
compaction.

### sweep_expired/0 and sweep_expired/1

Forgets moments whose valid_until has passed.

~~~elixir
{:ok, count} =
  SpectreMnemonic.sweep_expired(
    scope: {:project, "checkout"},
    now: DateTime.utc_now()
  )
~~~

### erase_partition/1

Physically erases one explicit namespace/scope partition.

~~~elixir
{:ok, report} =
  SpectreMnemonic.erase_partition(
    namespace: "my_app_memory",
    scope: {:subject, "alice"},
    sealed: true
  )
~~~

Every configured store must support and verify physical erasure. sealed: true
rejects future writes.

## Export and read

### export/1 and export/2

Writes one partition to a verified .mnemonic file.

~~~elixir
{:ok, report} =
  SpectreMnemonic.export("alice.mnemonic",
    scope: {:subject, "alice"},
    mode: :structure,
    embeddings?: false
  )
~~~

### SpectreMnemonic.Export.read/1 and read/2

Fully verifies and decodes a detached export.

~~~elixir
{:ok, decoded} = SpectreMnemonic.Export.read("alice.mnemonic")
~~~

### SpectreMnemonic.Export.stream/1 and stream/2

Verifies the file and returns a lazy frame stream.

~~~elixir
{:ok, frames} = SpectreMnemonic.Export.stream("alice.mnemonic")

Enum.each(frames, fn
  {:error, reason} -> handle_error(reason)
  frame -> consume(frame)
end)
~~~

Read and stream never insert data into active or durable memory. Format version
1 has no import/restore call.

## Action runtime

Action recipes are inert until an application configures
action_runtime_adapter. The explicit runtime surface is:

~~~elixir
{:ok, analysis} = SpectreMnemonic.Actions.Runtime.analyze(recipe)
{:ok, result} = SpectreMnemonic.Actions.Runtime.run(recipe, runtime_context)
~~~

The configured SpectreMnemonic.Actions.Runtime.Adapter implements analyze/2 and
run/3.

## Spectre integration calls

### Spectre.Mnemonic.config/1

Returns the immutable Stack installation for an Agent.

~~~elixir
{:ok, config} = Spectre.Mnemonic.config(MyApp.Agent)
~~~

### Spectre.Mnemonic.Memory.options/1 and options/2

Resolves namespace, store, canonical identities, and isolation scope.

~~~elixir
{:ok, opts} =
  Spectre.Mnemonic.Memory.options(MyApp.Agent,
    agent: MyApp.Agent,
    subject: Spectre.Subject.new(account.id),
    input: input,
    state: state
  )
~~~

### Spectre.Mnemonic.Memory.remember/4

Persists the compact logical projection of a committed Spectre turn. Spectre
normally invokes this callback; application code rarely calls it directly.

## Operational calls

These are public but lower-level than the facade:

| Call | Use |
| --- | --- |
| SpectreMnemonic.Persistence.Manager.replay/1 | replay live durable envelopes |
| SpectreMnemonic.Persistence.Manager.compact/1 | physical, semantic, or combined compaction |
| SpectreMnemonic.Durable.Index.rebuild/1 | rebuild the derived durable index |
| SpectreMnemonic.ConsolidationScheduler.status/0 | inspect maintenance status |
| SpectreMnemonic.Evaluation.run/1 | run deterministic retrieval evaluation |

See [Persistence and operations](PERSISTENCE_AND_OPERATIONS.md) before using
these calls in production.

## Where to find more detail

- [Writing and connecting memory](MEMORY_GUIDE.md)
- [Retrieval and knowledge](RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence and operations](PERSISTENCE_AND_OPERATIONS.md)
- [Privacy, data protection, and GDPR operations](PRIVACY_AND_GDPR.md)
- [.mnemonic format](MNEMONIC_FORMAT.md)
- [Exact public API manifest](PUBLIC_API.md)
