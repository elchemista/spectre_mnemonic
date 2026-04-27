# SpectreMnemonic

SpectreMnemonic is a small Elixir memory engine for live applications. It keeps
recent working memory in ETS, routes new signals into streams, recalls related
moments, and writes durable memory envelopes through pluggable storage adapters.

The public API is intentionally compact:

```elixir
{:ok, %{signal: signal, moment: moment}} =
  SpectreMnemonic.signal("research found Elixir ETS details",
    stream: :research,
    task_id: "task-a"
  )

{:ok, packet} = SpectreMnemonic.recall("how is task-a going?")
{:ok, results} = SpectreMnemonic.search("ETS details")
{:ok, association} = SpectreMnemonic.link(moment.id, :supports, "other_memory_id")
```

## Features

- Stream-aware ingestion through `SpectreMnemonic.Router` and per-stream workers.
- Active memory in ETS for signals, moments, associations, artifacts, and status.
- Adapter-free recall using keywords, entities, SimHash-style fingerprints, and graph expansion.
- Optional vector recall through embedding adapters or the local Model2Vec provider.
- Durable persistence through `SpectreMnemonic.PersistentMemory` and storage adapters.
- Append-only local file storage with replay, deduplication, tombstones, and compaction.
- Inert Action Language recipes attached to memories for external runtimes such
  as `spectre_kinetic`.

## Installation

Add the dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:spectre_mnemonic, "~> 0.1.0"}
  ]
end
```

Start it under your supervision tree or include it as an OTP application. The
library supervision tree starts ETS ownership, persistent memory, stream
supervision, routing, recall indexing, focus, recall, and consolidation.

## API Overview

`SpectreMnemonic.signal/2` records new input:

```elixir
SpectreMnemonic.signal("implemented disk replay checksum",
  stream: :task_execution,
  task_id: "alpha",
  kind: :task_execution,
  metadata: %{source: :agent}
)
```

`SpectreMnemonic.recall/2` returns a `SpectreMnemonic.RecallPacket` containing
nearby moments, active statuses, associations, artifacts, and confidence:

```elixir
{:ok, packet} = SpectreMnemonic.recall("progress alpha disk replay", limit: 5)
```

`SpectreMnemonic.search/2` merges active recall results with durable storage
results from adapters that advertise search capabilities:

```elixir
{:ok, results} = SpectreMnemonic.search("database search")
```

`SpectreMnemonic.forget/2` removes matching active moments and writes tombstones:

```elixir
SpectreMnemonic.forget({:task, "alpha"})
SpectreMnemonic.forget("mom_123")
```

## Action Language Recipes

Memories and artifacts can carry English-like Action Language (AL) recipes.
SpectreMnemonic stores and recalls these recipes as data only; it never parses
or executes AL during signal, recall, search, replay, or compaction.

```elixir
{:ok, %{moment: moment, action_recipe: recipe}} =
  SpectreMnemonic.signal("cached weather JSON for Rome",
    action_recipe: "When Kinetic asks, refresh JSON from the weather endpoint",
    action_intent: "refresh cached JSON",
    ttl_ms: 60_000,
    refresh_on_recall?: true,
    source_url: "https://api.example.test/weather",
    tags: [:weather, :json]
  )

{:ok, packet} = SpectreMnemonic.recall("weather JSON Rome")
Enum.map(packet.action_recipes, & &1.text)
```

Recipes are stored as `%SpectreMnemonic.ActionRecipe{}` records under the
`:action_recipes` persistent-memory family and linked to their memory through
an `:attached_action` association. Use `SpectreMnemonic.ActionRuntime` only
when you explicitly want to delegate analysis or execution to a configured
adapter:

```elixir
config :spectre_mnemonic,
  action_runtime_adapter: MyApp.KineticRuntime

SpectreMnemonic.ActionRuntime.analyze(recipe)
SpectreMnemonic.ActionRuntime.run(recipe, %{memory: moment})
```

The default runtime is disabled, so both calls return
`{:error, :runtime_not_configured}` unless an adapter is configured or passed in
the call options.

## Project Layout

- `lib/spectre_mnemonic.ex` is the public facade.
- `lib/spectre_mnemonic/focus.ex` owns active ETS memory.
- `lib/spectre_mnemonic/router.ex` chooses streams for incoming signals.
- `lib/spectre_mnemonic/stream_supervisor.ex` and
  `lib/spectre_mnemonic/stream_server.ex` manage per-stream workers.
- `lib/spectre_mnemonic/recall.ex` builds recall packets from active memory.
- `lib/spectre_mnemonic/recall/index.ex` indexes active embeddings.
- `lib/spectre_mnemonic/persistent_memory.ex` coordinates durable stores.
- `lib/spectre_mnemonic/action_runtime.ex` delegates AL analysis/execution to
  an explicitly configured runtime adapter.
- `lib/spectre_mnemonic/store/*` contains storage behaviours and adapters.
- `lib/spectre_mnemonic/embedding/*` contains vector, quantization, and model helpers.
- Struct modules such as `Moment`, `Signal`, `Cue`, and `RecallPacket` live in
  one file per module under `lib/spectre_mnemonic/`.

## Persistence

The default persistence backend is the local append-only file store:

```elixir
config :spectre_mnemonic,
  persistent_memory: [
    write_mode: :all,
    read_mode: :smart,
    failure_mode: :best_effort,
    stores: [
      [
        id: :local_file,
        adapter: SpectreMnemonic.Store.FileStorage,
        role: :primary,
        duplicate: true,
        opts: [data_root: "mnemonic_data"]
      ]
    ]
  ]
```

Storage adapters implement `SpectreMnemonic.Store.Adapter`. Built-in Postgres,
Mongo, and S3 modules advertise intended capabilities but return setup errors
until replaced with app-specific implementations.

## Embeddings

Embeddings are optional. Without an adapter, recall still works through text,
fingerprints, and associations.

Configure a custom adapter:

```elixir
config :spectre_mnemonic, embedding_adapter: MyApp.EmbeddingAdapter
```

Adapters implement `SpectreMnemonic.Embedding.Adapter.embed/2` and return either
`{:ok, vector}`, `{:ok, embedding_map}`, or `{:error, reason}`.

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

Downloads are opt-in. For production, pre-populate the model cache or provide a
known `:model_dir`.

## Development

Format and test before committing:

```bash
mix format
mix test
```
