# Release checklist

Use this checklist for the next SpectreMnemonic release. The repository remains
GitHub-distributed; a release tag is a compatibility declaration even when no
Hex package is published.

## 1. Freeze the release scope

- Move completed entries from `[Unreleased]` into a dated release section in
  `CHANGELOG.md`.
- Decide the public version before changing files. Do not derive it from the
  internal development-milestone headings.
- Confirm the public API additions, removals, deprecations, storage changes,
  and `.mnemonic` format compatibility.
- Record any required host migration for JSON, embeddings, persistence,
  privacy, or GPU configuration.

## 2. Align versioned surfaces

Update and review every intentional occurrence:

- `@version` in `mix.exs`;
- the Spectre package manifest in `lib/spectre/mnemonic.ex`;
- the heading and text in `docs/PUBLIC_API.md`;
- exact version assertions in `test/stack_installable_test.exs`;
- fixed `library_version` fixtures in export tests;
- `CHANGELOG.md` and the Git tag.

Keep `.mnemonic` container version 1, persistence codec versions, and extension
API versions unchanged unless their actual wire or behavior contracts change.
The export writer reads its library version from the OTP application.

## 3. Lock dependency and native compatibility

- Ensure the release dependency is `{:vettore, "~> 0.3.5"}` with
  `VETTORE_PATH` unset.
- Ensure Spectre resolves to the supported `~> 0.3.3` line with
  `SPECTRE_PATH` unset.
- Run `mix deps.get --check-locked` and confirm it does not modify `mix.lock`.
- Confirm the Vettore 0.3.5 package checksum and precompiled NIF download on
  every supported CI target.
- Inspect `Vettore.Compute.info/0` on a CPU-only host and a GPU-capable host.
  `gpu: :auto, gpu_fallback: :cpu` must preserve availability on both.

Vettore GPU support is native through `wgpu`. Nx is only a runtime interchange
format and must not reappear as a SpectreMnemonic dependency.

## 4. Exercise optional dependency combinations

At minimum, test these host-owned configurations:

| Consumer | Host dependencies and config | Expected result |
| --- | --- | --- |
| Minimal JSON | `json_library: JSON` | export/read and Model2Vec JSON parsing work without adding a JSON package |
| Jason | `{:jason, "~> 1.4"}` and `json_library: Jason` | canonical exports interchange with built-in `JSON` |
| No JSON config | none | non-JSON memory works; JSON-backed features return explicit configuration errors |
| Local Model2Vec | `{:tokenizers, "~> 0.5"}` | Hugging Face tokenization and Vettore pooling work |
| Model2Vec fallback | no `tokenizers` | bounded lexical fallback works without loading a Tokenizers NIF |
| Tensor interop | `{:nx, "~> 0.11"}` | Vettore `to_nx` and tensor normalization compatibility work |
| No Nx | none | list and f32-binary vector paths work; tensor helpers return `:nx_not_available` |

Do not rely on Jason being pulled transitively by Spectre. The application that
selects a third-party JSON library must declare it directly.

## 5. Run release gates

Run each command from a clean checkout with path overrides unset:

```bash
env -u VETTORE_PATH -u SPECTRE_PATH mix deps.get --check-locked
mix hex.audit
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix docs --warnings-as-errors
mix run --no-start example/demo.exs
```

Then run the opt-in real embedding and Spectre Agent scenarios documented in
[Persistence and operations](docs/PERSISTENCE_AND_OPERATIONS.md#evaluation-and-development).
Review failures rather than weakening a strict gate for the release.

## 6. Review security and privacy

- Re-run malformed frame, export schema, privacy-mode, secret, retention,
  erasure, stale-restore, and partition-isolation tests.
- Re-run torn-tail recovery for both logs, CRC-corruption refusal, concurrent
  append ordering, and `:always` sync/rename/unlink failure injection. Do not
  market `sync: :none` as power-loss durable.
- Verify `full`, `structure`, and a deterministic redactor against realistic
  records.
- Confirm exports are handled as unencrypted personal-data artifacts and that
  temporary files have an owner and retention rule.
- Confirm `valid_until` sweeps are scheduled by the host.
- Test whole-partition erasure, post-erasure verification, sealing, compaction,
  backup handling, provider deletion, and resurrection prevention.
- Verify forgotten PII is absent from lifecycle metadata, knowledge search,
  durable indexes, exports, and Vettore collections; document that unlink is
  not forensic media sanitization.
- Review the responsibility boundary and data-subject request runbook in
  [Privacy, data protection, and GDPR operations](docs/PRIVACY_AND_GDPR.md).
- Reassess the DPIA and processor inventory when models, purposes, data
  categories, regions, or automated-decision effects changed.

## 7. Review documentation and examples

- Build ExDoc with warnings as errors and inspect all extra pages and links.
- Run the demo with the built-in `JSON` adapter.
- Verify README installation snippets contain `namespace` and
  `json_library`.
- Confirm CPU/GPU guidance distinguishes Flat search, HNSW traversal, exact
  reranking, thresholds, fallback, mutation invalidation, and GPU memory cost.
- Confirm public functions are either listed in `docs/PUBLIC_API.md` or
  intentionally documented as implementation details.

## 8. Publish and verify

1. Merge only after all required CI jobs pass on the release commit.
2. Create the signed or annotated `vX.Y.Z` tag matching `mix.exs`.
3. Publish GitHub release notes from the matching changelog section.
4. Verify a fresh GitHub dependency checkout resolves the tag and starts.
5. Re-run a small remember/recall/export/read smoke test from a consumer app.
6. Keep the previous tag and migration notes available for rollback.

Do not run `mix hex.publish` unless distribution policy and package metadata
are intentionally changed in a separately reviewed release.
