# Writing and connecting memory

This guide covers memory intake and the structures created around it: signals,
rich memories, scopes, time, plugs, embeddings, graph links, Atlas, artifacts,
action recipes, and secrets.

## `signal/2`: record one immediate event

Use `signal/2` when the caller already knows what the event is and does not
need document chunking or extraction.

```elixir
{:ok, %{signal: signal, moment: moment}} =
  SpectreMnemonic.signal("Deployment completed",
    scope: {:project, "checkout"},
    stream: :task_execution,
    task_id: "deploy-42",
    kind: :tool,
    attention: 1.5,
    metadata: %{source: :deploy_api},
    persist?: true
  )
```

The signal is the original event envelope. The moment is the searchable
projection used by recall.

Common options:

| Option | Purpose |
| --- | --- |
| `:namespace` | Overrides the configured application namespace for this call |
| `:scope` | Selects exactly one caller-owned partition |
| `:stream` | Explicit activity lane |
| `:task_id` | Associates memory with a task and enables task status/forget selectors |
| `:kind` | Describes the event, such as `:chat`, `:tool`, or `:research` |
| `:metadata` | Map or keyword metadata |
| `:attention` | Initial ranking/consolidation importance |
| `:confidence` | Provenance confidence |
| `:persist?` | Writes the generated records durably; defaults to `true` for signals |
| `:embedding`, `:vector` | Caller-provided dense vector |
| `:memory_state` | Initial lifecycle state, for example `:pinned` |
| `:action_recipe` | Inert action-language text or structured recipe |
| `:secret?`, `:label` | Stores encrypted secret memory instead of public text |

If `:stream` is absent, routing tries `:task_id`, metadata stream, selected
event kinds, and finally `:chat`.

## `remember/2`: build rich memory

Use `remember/2` for documents, task descriptions, chat transcripts, research
notes, code notes, tool payloads, maps, and lists.

```elixir
{:ok, packet} =
  SpectreMnemonic.remember(
    %{
      title: "Checkout launch notes",
      text: """
      Marta owns the launch.
      The payment sandbox returns on 2026-08-27.
      Deploy on Friday after the smoke test.
      """,
      metadata: %{source: :project_log}
    },
    scope: {:project, "checkout"},
    stream: :planning,
    task_id: "deploy-42",
    tags: [:checkout, :release],
    persist?: true
  )
```

The returned `SpectreMnemonic.Intake.Packet` exposes what intake created:

| Field | Contents |
| --- | --- |
| `root` | searchable root moment |
| `events` | source signal envelopes |
| `moments` | every generated moment |
| `chunks` | long-input chunks |
| `summaries` | compact summaries |
| `categories` | category nodes |
| `associations` | structural, extracted, and cross-memory graph edges |
| `warnings`, `errors` | non-fatal intake diagnostics |
| `persistence` | active-only or durable status |

### Accepted inputs

Text is stored as text even when it resembles JSON. Structured maps and keyword
lists may provide fields such as `:text`, `:title`, `:kind`, `:task_id`,
`:tags`, and `:metadata`. Other Erlang terms receive a deterministic text
projection.

```elixir
SpectreMnemonic.remember("plain text")

SpectreMnemonic.remember(%{
  title: "Incident decision",
  text: "Use the read replica until the primary recovers.",
  kind: :decision,
  tags: [:database]
})

SpectreMnemonic.remember(
  [event: :build_failed, job: "linux-otp-28", reason: "timeout"],
  kind: :tool
)
```

Empty text returns `{:error, :empty_memory}`.

### Intake controls

| Option | Validation and effect |
| --- | --- |
| `:chunk_words` | positive chunk size; default 180 |
| `:overlap_words` | non-negative overlap; default 40 |
| `:summary_words` | positive summary target; default 36 |
| `:similarity_threshold` | `0.0..1.0` threshold for related chunks |
| `:max_related_edges` | non-negative cap for related-chunk edges |
| `:cross_memory?` | enables partition-local aggregation; default `true` |
| `:cross_memory_similarity_threshold` | `0.0..1.0`; default 0.24 |
| `:max_cross_memory_edges` | non-negative aggregation edge cap; default 20 |
| `:extract_entities?` | enables deterministic extraction; default `true` |
| `:entity_extraction_adapter` | per-call extraction adapter |
| `:sensitive_numbers` | `:classified` default, `:raw`, or `:skip` |
| `:persist?` | immediate durability; default `false` for rich intake |
| `:root_attention` | root attention; default 2.0 |
| `:chunk_attention` | chunk attention; default 1.0 |
| `:summary_attention` | summary attention; default 1.5 |
| `:category_attention` | category attention; default 1.1 |
| `:extraction_attention` | overrides attention on extracted nodes |

Disable selected work when the caller only needs a lightweight root:

```elixir
SpectreMnemonic.remember(document,
  extract_entities?: false,
  cross_memory?: false,
  chunk_words: 400,
  summary_words: 50
)
```

## Scopes and temporal validity

Every write belongs to one scope. Reads must use the same scope:

```elixir
scope = {:tenant, "acme"}

SpectreMnemonic.remember("Payment retry policy is stable",
  scope: scope,
  occurred_at: ~U[2026-05-01 12:00:00Z],
  observed_at: ~U[2026-05-02 08:00:00Z],
  last_verified_at: ~U[2026-05-20 09:00:00Z],
  valid_from: ~U[2026-05-01 00:00:00Z],
  valid_until: ~U[2026-12-31 23:59:59Z],
  persist?: true
)

SpectreMnemonic.recall("payment retry",
  scope: scope,
  valid_at: ~U[2026-05-30 00:00:00Z]
)
```

The timestamps have separate meanings:

- `:occurred_at` — when the event happened;
- `:observed_at` — when the memory layer learned it;
- `:last_verified_at` — when its evidence was last checked;
- `:valid_from`, `:valid_until` — the fact or model's truth window.

`sweep_expired/1` logically forgets moments whose `valid_until` has passed.

## Mission policies

`:mission` is metadata unless a policy plug consumes it:

```elixir
SpectreMnemonic.remember("TODO fix API retry contract",
  scope: {:project, "sdk"},
  mission: :code_agent,
  plugs: [SpectreMnemonic.Intake.MissionPolicy]
)
```

The built-in `:code_agent` policy filters low-value conversational filler and
prioritizes technical decisions, bugs, API contracts, constraints, TODOs, user
preferences, and project state.

## Intake plugs

Plugs can classify, enrich, route, filter, summarize, detect secrets, or return
a final intake result. Global plugs run before per-call plugs.

```elixir
config :spectre_mnemonic,
  plugs: [
    MyApp.Memory.ProjectPlug,
    {MyApp.Memory.SecretRouterPlug, providers: [:github, :stripe]}
  ]
```

Example plug:

```elixir
defmodule MyApp.Memory.ProjectPlug do
  @behaviour SpectreMnemonic.Intake.Plug

  @impl true
  def call(memory, opts) do
    project = Keyword.fetch!(opts, :project)

    {:cont,
     %{
       memory
       | metadata: Map.put(memory.metadata, :project, project),
         tags: Enum.uniq([project | memory.tags])
     }}
  end
end
```

Use it for one call:

```elixir
SpectreMnemonic.remember("Release candidate approved",
  project: :checkout,
  plugs: [{MyApp.Memory.ProjectPlug, project: :checkout}]
)
```

A plug may return:

- the updated memory or `{:cont, memory}` to continue;
- `{:halt, memory}` to store the current draft without later plugs;
- `{:ok, result}` or another value to stop and let intake normalize the final
  result.

`signal/2` is intentionally lower-level and does not run remember plugs.

## Extraction and cross-memory aggregation

The deterministic extractor recognizes useful names, dates, events, e-mail
addresses, ages, numbers, and phone-like values. It creates partition-local
entity and timeline nodes with typed associations.

Phone-like values are classified/redacted by default:

```elixir
SpectreMnemonic.remember(text, sensitive_numbers: :raw)
SpectreMnemonic.remember(text, sensitive_numbers: :skip)
```

Configure richer extraction:

```elixir
config :spectre_mnemonic,
  entity_extraction_adapter: MyApp.MemoryExtractor
```

The adapter implements
`c:SpectreMnemonic.Intake.Extraction.Adapter.extract/2` and returns graph
fragments with entities, events, times, values, and relations.

Cross-memory aggregation compares the new root/chunks/summaries/categories only
with candidates from the same partition. It is bounded by threshold and edge
count:

```elixir
SpectreMnemonic.remember(text,
  cross_memory?: true,
  cross_memory_similarity_threshold: 0.35,
  max_cross_memory_edges: 12
)
```

## Embeddings

Embeddings are optional. Without them, recall and search still use keywords,
entities, fingerprints, graph links, and durable text ranking.

Attach a precomputed vector:

```elixir
SpectreMnemonic.signal("opaque event",
  scope: {:subject, "alice"},
  embedding: [0.12, -0.44, 0.91]
)

SpectreMnemonic.remember("longer input",
  scope: {:subject, "alice"},
  embedding: %{
    vector: [0.12, -0.44, 0.91],
    metadata: %{model: "my-embedding-model", version: 3}
  }
)
```

`vector: [...]` is shorthand. Caller vectors take priority over providers,
are normalized to float32, and receive a binary signature. Empty, malformed,
non-finite, or out-of-range vectors are rejected from the embedding index
without making the text memory unavailable.

Configure an adapter:

```elixir
config :spectre_mnemonic,
  embedding_adapter: MyApp.EmbeddingAdapter
```

```elixir
defmodule MyApp.EmbeddingAdapter do
  @behaviour SpectreMnemonic.Embedding.Adapter

  @impl true
  def embed(input, _opts) do
    MyEmbeddingService.embed(to_string(input))
  end
end
```

The callback returns `{:ok, vector}`, `{:ok, embedding_map}`, or
`{:error, reason}`.

Enable the local Model2Vec provider:

```elixir
config :spectre_mnemonic,
  embedding: [
    fast: [
      enabled: true,
      model_id: "minishlab/potion-base-8M",
      download: true
    ]
  ]
```

Downloads are opt-in. Production deployments can pre-populate the cache or set
`:model_dir`. Optional SHA-256 checksums are verified before installation.

Active vectors are indexed through one Vettore collection per
`{namespace, scope}`:

```elixir
config :spectre_mnemonic,
  embedding: [
    index: [
      backend: :vettore,
      vettore_index: :hnsw,
      strategy: :hybrid,
      vettore_index_options: [
        m: 16,
        m0: 32,
        ef_construction: 100,
        ef_search: 64
      ]
    ]
  ]
```

The hybrid strategy combines HNSW candidates, quantized candidates, and exact
reranking. Failures fall back to deterministic ETS scoring. Consolidation copies
existing vectors and signatures; it does not re-embed text.

## Graph links, entities, and Atlas

Create a typed association between existing records:

```elixir
{:ok, edge} =
  SpectreMnemonic.link(source_id, :supported_by, target_id,
    scope: {:project, "checkout"},
    weight: 0.8,
    metadata: %{source: :operator},
    persist?: true
  )
```

Endpoints must be non-empty ids, the relation must be an atom, and weight must
be between `0.0` and `1.0`. Recall can traverse links to bring related
moments, artifacts, or action recipes into the packet.

Resolve duplicate entity nodes:

```elixir
{:ok, same_as_edge} =
  SpectreMnemonic.merge_entities(winner_id, loser_id,
    scope: {:subject, "alice"}
  )

:ok =
  SpectreMnemonic.unmerge_entities(winner_id, loser_id,
    scope: {:subject, "alice"}
  )
```

Merge is append-only and writes a non-traversable `:same_as` redirect.
Unmerge tombstones the redirect and restores the loser's canonical aliases;
neither operation rewrites historical memories.

Inspect the deterministic mind-map projection:

```elixir
{:ok, atlas} =
  SpectreMnemonic.atlas(
    scope: {:project, "checkout"},
    recluster: true
  )

atlas.nodes
atlas.edges
atlas.clusters
atlas.stats.top_hubs
atlas.stats.orphan_ratio
atlas.truncated
```

Atlas uses bounded partition-local data and materializes Episode clusters.
Active export fails rather than silently omitting data when Atlas reports
truncation.

## Artifacts and action recipes

Register a file reference or binary payload:

```elixir
{:ok, artifact} =
  SpectreMnemonic.artifact("/var/reports/checkout.txt",
    scope: {:project, "checkout"},
    content_type: "text/plain",
    metadata: %{owner: :release_team}
  )
```

Attach an inert action recipe to a signal or artifact:

```elixir
{:ok, %{moment: moment, action_recipe: recipe}} =
  SpectreMnemonic.signal("cached weather JSON for Rome",
    scope: {:project, "travel"},
    action_recipe: "When asked, refresh JSON from the weather endpoint",
    action_intent: "refresh cached JSON",
    ttl_ms: 60_000,
    refresh_on_recall?: true,
    source_url: "https://api.example.test/weather"
  )
```

Mnemonic stores and recalls recipes as data. It never executes them implicitly.
Explicit execution is available only through
`SpectreMnemonic.Actions.Runtime` after configuring:

```elixir
config :spectre_mnemonic,
  action_runtime_adapter: MyApp.KineticRuntime
```

## Secret memory

Secret memory keeps plaintext out of indexed text. Plaintext is encrypted before
the secret enters ETS or persistence.

```elixir
{:ok, %{moment: secret}} =
  SpectreMnemonic.signal("github_pat_...",
    scope: {:subject, "alice"},
    secret?: true,
    label: "GitHub token",
    secret_key: secret_key_32_bytes,
    persist?: true
  )

secret.text
#=> "secret: GitHub token"
```

Configure key lookup and reveal authorization:

```elixir
config :spectre_mnemonic,
  secret_key_fun: fn -> MyApp.Keys.memory_secret_key() end,
  secret_authorization_adapter: MyApp.SecretAuthorization
```

```elixir
defmodule MyApp.SecretAuthorization do
  @behaviour SpectreMnemonic.Secrets.Authorization.Adapter

  @impl true
  def authorize(request, _opts) do
    if MyApp.Permissions.may_reveal?(request.authorization_context) do
      {:ok, %{policy: :memory_secret}}
    else
      {:error, :denied}
    end
  end
end
```

Reveal is always explicit:

```elixir
{:ok, revealed} =
  SpectreMnemonic.reveal(secret,
    secret_key: secret_key_32_bytes,
    authorization_context: %{user_id: current_user.id}
  )
```

If authorization is missing or denied, recall still succeeds and returns a
locked placeholder. Custom crypto adapters can delegate encryption to a KMS,
Vault, keychain, or hardware-backed boundary and may optionally implement
partition key shredding.

## Related guides

- [Retrieval and knowledge](RETRIEVAL_AND_KNOWLEDGE.md)
- [Persistence and operations](PERSISTENCE_AND_OPERATIONS.md)
- [Complete facade API guide](API_GUIDE.md)
