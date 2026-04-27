# Unified Plan: Embeddings, Models, and Search

## Summary
Spectre Mnemonic is both an agent-first memory mechanism and a database-capable
memory store. The first design priority is agent use: live focus, recall,
streams, task status, associations, and consolidation. The database role remains
core: durable append/replay, lookup, search dispatch, tombstones, compaction,
and multi-store persistence stay intact.

Add dense embeddings for semantic search, packed binary signatures for fast
Hamming reranking, and optional `hnswlib` for dense ANN candidate retrieval.
Current keyword/entity/status/graph recall and fingerprint Hamming fallback
remain available when embeddings or models are missing.

## Public Interfaces
- Keep `SpectreMnemonic.signal/2`, `recall/2`, `consolidate/1`, `forget/2`,
  and persistent-memory APIs stable.
- Add `SpectreMnemonic.search/2` for DB-style querying across active memory and
  durable stores.
- Keep legacy `:embedding_adapter` as a compatibility override.
- Configure embeddings with:

  ```elixir
  config :spectre_mnemonic, :embedding,
    fast: [
      enabled: true,
      provider: SpectreMnemonic.Embedding.Model2VecStatic,
      model_dir: nil,
      model_id: "minishlab/potion-multilingual-128M",
      dimensions: 256,
      signature_bits: 256
    ],
    index: [
      enabled: true,
      backend: :hnsw,
      space: :cosine,
      max_elements: 10_000,
      overfetch: 40
    ],
    deep: [
      enabled: false,
      provider: SpectreMnemonic.Embedding.EmbeddingGemma
    ]
  ```

- Store embeddings on `Moment`, `Knowledge`, and query cues as:

  ```elixir
  %{
    vector: binary() | nil,
    binary_signature: binary() | nil,
    metadata: %{format: :f32_binary, dimensions: integer(), model: binary(), normalized: true},
    error: term() | nil
  }
  ```

## Implementation Changes
- Add deps: `:jason`, `:tokenizers`, keep `:nx`, and add optional `:hnswlib`.
  Deep runtime deps stay optional and disabled.
- Add `SpectreMnemonic.Embedding.Vector` for f32 binary conversion,
  normalization, cosine/dot scoring, popcount, and Hamming helpers.
- Add `SpectreMnemonic.Embedding.BinaryQuantizer` to produce packed signatures
  from dense vectors.
- Add `SpectreMnemonic.Embedding.Model2VecStatic` to load local Model2Vec files,
  tokenize, mean-pool, normalize, and return dense vector plus binary signature.
- Update `SpectreMnemonic.Embedding.embed/2` precedence: legacy adapter,
  configured fast provider, then nil embedding fallback.
- Add `SpectreMnemonic.Recall.Index` to own optional HNSW state, ETS label
  mappings, dense vectors, and binary signatures. HNSW uses dense `:cosine`;
  binary Hamming is a rerank layer because current Elixir `hnswlib` supports
  `:cosine`, `:ip`, and `:l2`, not native Hamming.
- Update `Focus` to index moments after successful ingestion and remove index
  entries on forget/tombstone.
- Update `Recall` to use indexed overfetch plus binary Hamming/cosine rerank,
  then existing keyword/entity/status/graph scoring. Without embeddings, keep
  fingerprint Hamming fallback.
- Keep `PersistentMemory.search/2` store-dispatched, while
  `SpectreMnemonic.search/2` merges active indexed recall with durable adapter
  results.

## Test Plan
- Keep existing tests for recall, persistence, adapters, tombstones,
  graph/status/artifacts, and adapter-free fallback passing.
- Add unit tests for f32 binary conversion, packed signatures, Hamming distance,
  cosine scoring, and adapter result normalization.
- Add Model2Vec fixture tests for local model loading and expected embedding
  shape.
- Add index tests for brute-force fallback, overfetch reranking, and
  forget/tombstone removal.
- Add DB-style search tests for active plus durable results, result source
  tagging, replayed vector metadata, and persistence compatibility.

## Assumptions
- "Binary distance" means embedding-derived binary signatures with Hamming
  distance, separate from legacy fingerprint Hamming.
- `hnswlib` is optional dense ANN only; true Hamming-space HNSW is out of scope
  unless the library adds support. Reference:
  https://hexdocs.pm/hnswlib/HNSWLib.Index.html
- `vettore` and `ex_fastembed` remain references only.
- Model files are supplied locally by the host app.
