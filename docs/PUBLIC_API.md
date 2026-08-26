# Spectre Mnemonic public API — 0.2.0

This file is the normative public API manifest for Spectre Mnemonic `0.2.0`.
Its package and Stack contracts target Spectre `0.3.3` from Hex.
For task-oriented explanations and examples, start with the
[API guide](API_GUIDE.md); use this manifest to determine compatibility.
Compatibility guarantees apply only to the
modules and callables listed below. Any module, function, macro, or callback
not listed here is an implementation detail even when it is exported or
visible in generated docs.

Default arguments are expanded into every callable arity. For the listed
modules, documented types, opaque types, and documented struct fields are also
public. Modules with no callable row expose only their documented module,
type, and struct contract.

`SpectreMnemonic.Export.read/1,2` and `stream/1,2` decode and verify detached
`.mnemonic` exports. Version `0.2.0` exposes no `.mnemonic` import or live-memory
restore callable; persistent runtime recovery remains the responsibility of the
configured store replay path.

Each explicit Engine requires a stable `:storage_id` and `:namespace`. A global
namespace is no longer required to start the OTP application; configuring one
starts the 0.1.x-compatible DefaultEngine. Calls without `engine:` return
`:mnemonic_engine_required` when no DefaultEngine exists. The runtime is
single-node and the host must enforce one active writer per `storage_id` across
nodes.

JSON-backed features require an explicit `:json_library`. The JSON module must
export `decode/1` and either `encode/1` or `encode!/1`. There is no implicit
adapter fallback. Elixir's built-in `JSON` requires no package; applications
that select Jason must declare it directly. Nx and `tokenizers` remain optional
host dependencies.

## Manifest

- `Spectre.Mnemonic`
  - functions: `config/1`, `erase_instance/1`, `erase_instance/2`, `erasure_plan/1`, `erasure_plan/2`
- `Spectre.Mnemonic.Memory`
  - functions: `options/1`, `options/2`, `remember/4`
- `SpectreMnemonic`
  - functions: `artifact/1`, `artifact/2`, `atlas/0`, `atlas/1`, `compact_knowledge/0`, `compact_knowledge/1`, `consolidate/0`, `consolidate/1`, `consolidate_observations/0`, `consolidate_observations/1`, `erase_partition/1`, `export/1`, `export/2`, `forget/1`, `forget/2`, `health/1`, `knowledge/0`, `knowledge/1`, `learn/1`, `learn/2`, `link/3`, `link/4`, `load_knowledge/0`, `load_knowledge/1`, `merge_entities/2`, `merge_entities/3`, `put_mental_model/1`, `put_mental_model/2`, `recall/1`, `recall/2`, `reflect/1`, `reflect/2`, `remember/1`, `remember/2`, `reveal/1`, `reveal/2`, `search/1`, `search/2`, `search_knowledge/1`, `search_knowledge/2`, `search_mental_models/1`, `search_mental_models/2`, `search_observations/1`, `search_observations/2`, `signal/1`, `signal/2`, `status/1`, `status/2`, `sweep_expired/0`, `sweep_expired/1`, `unmerge_entities/2`, `unmerge_entities/3`, `verify_observation/1`, `verify_observation/2`
- `SpectreMnemonic.Engine`
  - functions: `child_spec/1`, `health/1`, `resolve/1`, `start_link/1`
- `SpectreMnemonic.Engine.Config`
- `SpectreMnemonic.Engine.Ref`
  - functions: `new/1`
- `SpectreMnemonic.Engine.Runtime`
- `SpectreMnemonic.Embedding.Space`
- `SpectreMnemonic.Atlas`
  - functions: `build/0`, `build/1`
- `SpectreMnemonic.Atlas.LabelAdapter`
  - callbacks: `label/2`
- `SpectreMnemonic.Erasure.Report`
- `SpectreMnemonic.Export`
  - functions: `read/1`, `read/2`, `stream/1`, `stream/2`
- `SpectreMnemonic.Actions.Runtime`
  - functions: `analyze/1`, `analyze/2`, `run/2`, `run/3`
- `SpectreMnemonic.Actions.Runtime.Adapter`
  - callbacks: `analyze/2`, `run/3`
- `SpectreMnemonic.Active.Focus`
  - functions: `action_recipes/1`, `action_recipes/2`, `artifact/1`, `artifact/2`, `artifacts/1`, `artifacts/2`, `associations/0`, `associations/1`, `forget/1`, `forget/2`, `link/3`, `link/4`, `moments/0`, `moments/1`, `record_signal/2`, `status/1`, `status/2`
- `SpectreMnemonic.Active.Router`
  - functions: `signal/2`
- `SpectreMnemonic.Application`
- `SpectreMnemonic.ConsolidationScheduler`
  - functions: `child_spec/1`, `start_link/0`, `start_link/1`, `status/0`
- `SpectreMnemonic.Durable.Index`
  - functions: `child_spec/1`, `rebuild/0`, `rebuild/1`, `reset/0`, `search/1`, `search/2`, `start_link/0`, `start_link/1`, `upsert/1`
- `SpectreMnemonic.Embedding.Adapter`
  - callbacks: `embed/2`
- `SpectreMnemonic.Embedding.BinaryQuantizer`
  - functions: `quantize/1`, `quantize/2`
- `SpectreMnemonic.Embedding.EmbeddingGemma`
  - functions: `embed/2`
- `SpectreMnemonic.Embedding.Model2VecStatic`
  - functions: `embed/1`, `embed/2`
- `SpectreMnemonic.Embedding.ModelDownloader`
  - functions: `cache_dir/1`, `cache_dir/2`, `download_model/1`, `ensure_model/1`, `required_files/0`
- `SpectreMnemonic.Embedding.Service`
  - functions: `embed/2`
- `SpectreMnemonic.Embedding.Vector`
  - functions: `cosine/2`, `dimensions/1`, `dot/2`, `hamming_distance/2`, `hamming_similarity/2`, `hamming_similarity/3`, `normalize/1`, `normalize_tensor/1`, `normalize_to_f32_binary/1`, `popcount/1`, `to_f32_binary/1`, `to_list/1`, `to_tensor/1`
- `SpectreMnemonic.Evaluation`
  - functions: `run/0`, `run/1`
- `SpectreMnemonic.Governance`
  - functions: `append_state/3`, `append_state/4`, `append_state/5`, `child_spec/1`, `consolidatable?/1`, `consolidatable?/2`, `decay/0`, `decay/1`, `fact_claim/1`, `forget/1`, `forget/2`, `observe_moment/1`, `observe_moment/2`, `promote_moments/1`, `promote_moments/2`, `search_visible?/1`, `search_visible?/2`, `state_event/3`, `state_event/4`, `state_event/5`, `state_for/1`, `state_for/2`, `states/0`, `with_provenance/1`, `with_provenance/2`
- `SpectreMnemonic.Identity`
  - functions: `configured_namespace/0`, `derived/2`, `derived/3`, `fetch_namespace/0`, `fetch_namespace/1`, `generate/1`, `generate/2`, `namespace/1`, `namespace!/0`, `namespace!/1`, `put_context/2`, `put_namespace/1`, `uuid7/0`
- `SpectreMnemonic.Intake`
  - functions: `remember/1`, `remember/2`
- `SpectreMnemonic.Intake.Extraction`
  - functions: `extract/1`, `extract/2`
- `SpectreMnemonic.Intake.Extraction.Adapter`
  - callbacks: `extract/2`
- `SpectreMnemonic.Intake.Memory`
- `SpectreMnemonic.Intake.MissionPolicy`
  - callbacks: `extraction_profile/1`, `keep?/3`, `priority/3`
- `SpectreMnemonic.Intake.Packet`
- `SpectreMnemonic.Intake.Plug`
  - callbacks: `call/2`
- `SpectreMnemonic.Knowledge.Base`
  - functions: `append/1`, `append/2`, `build_packet/1`, `build_packet/2`, `config/0`, `config/1`, `events/0`, `events/1`, `load/0`, `load/1`, `search/1`, `search/2`
- `SpectreMnemonic.Knowledge.Compact`
  - functions: `compact_knowledge/0`, `compact_knowledge/1`
- `SpectreMnemonic.Knowledge.Compact.Adapter`
  - callbacks: `compact/2`
- `SpectreMnemonic.Knowledge.Consolidation`
- `SpectreMnemonic.Knowledge.Consolidator`
  - functions: `consolidate/0`, `consolidate/1`
- `SpectreMnemonic.Knowledge.Consolidator.Adapter`
  - callbacks: `consolidate/2`
- `SpectreMnemonic.Knowledge.Learning`
  - functions: `learn/1`, `learn/2`
- `SpectreMnemonic.Knowledge.Record`
- `SpectreMnemonic.Knowledge.SMEM`
  - functions: `append/1`, `append/2`, `append_many/1`, `append_many/2`, `child_spec/1`, `data_root/0`, `data_root/1`, `path/0`, `path/1`, `reduce/2`, `reduce/3`, `replace/1`, `replace/2`, `replay/0`, `replay/1`
- `SpectreMnemonic.Memory.ActionRecipe`
- `SpectreMnemonic.Memory.Artifact`
- `SpectreMnemonic.Memory.Association`
- `SpectreMnemonic.Memory.Episode`
- `SpectreMnemonic.Memory.MentalModel`
- `SpectreMnemonic.Memory.Moment`
- `SpectreMnemonic.Memory.Observation`
- `SpectreMnemonic.Memory.Secret`
- `SpectreMnemonic.Memory.Signal`
- `SpectreMnemonic.Memory.Skill`
- `SpectreMnemonic.MentalModels`
  - functions: `put/1`, `put/2`, `search/1`, `search/2`
- `SpectreMnemonic.Migration`
  - functions: `migrate_instance_partition/2`, `migrate_instance_partition/3`, `migrate_partition/2`, `repartition/3`
- `SpectreMnemonic.Migration.Assigner`
  - callbacks: `assign/1`, `destination_options/0`, `source_options/0`
- `SpectreMnemonic.Observations`
  - functions: `consolidate/0`, `consolidate/1`, `search/1`, `search/2`, `verify/1`, `verify/2`
- `SpectreMnemonic.Persistence.Compact.Adapter`
  - callbacks: `compact/2`
- `SpectreMnemonic.Persistence.Manager`
  - functions: `append/2`, `append/3`, `child_spec/1`, `compact/0`, `compact/1`, `config/0`, `get/2`, `get/3`, `put/1`, `put/2`, `replay/0`, `replay/1`, `replay_all/0`, `replay_all/1`, `replay_fold/2`, `replay_fold/3`, `search/1`, `search/2`, `start_link/0`, `start_link/1`
- `SpectreMnemonic.Persistence.WriteReceipt`
- `SpectreMnemonic.Persistence.Store.Adapter`
  - functions: `describe/1`, `describe/2`
  - callbacks: `capabilities/1`, `classify_retry/1`, `contract/1`, `delete_or_tombstone/3`, `erase_partition/4`, `get/3`, `health/1`, `put/2`, `put_batch/2`, `replay/1`, `replay_fold/3`, `replay_page/2`, `search/2`, `semantic_compact/2`, `verify_erased/4`
- `SpectreMnemonic.Persistence.Store.Contract`
  - functions: `validate/1`
- `SpectreMnemonic.Persistence.Store.Conformance`
  - functions: `audit/1`, `audit/2`
- `SpectreMnemonic.Persistence.Store.Codec`
  - functions: `decode_record/1`, `decode_term/1`, `encode_record/1`, `encode_term/1`
- `SpectreMnemonic.Persistence.Store.Disk`
  - functions: `append/2`, `compact/0`, `data_root/0`, `replay/0`, `start_link/1`
- `SpectreMnemonic.Persistence.Store.File`
  - functions: `compact/0`, `compact/1`, `data_root/0`, `data_root/1`
- `SpectreMnemonic.Persistence.Store.FileFrame`
  - functions: `encode/2`, `encode/3`, `read_frames/3`
- `SpectreMnemonic.Persistence.Store.Mongo`
- `SpectreMnemonic.Persistence.Store.Postgres`
- `SpectreMnemonic.Persistence.Store.Record`
- `SpectreMnemonic.Persistence.Store.S3`
- `SpectreMnemonic.QueryContext`
  - functions: `ensure/2`, `new/1`, `new/2`, `text/1`
- `SpectreMnemonic.Recall.Cue`
- `SpectreMnemonic.Recall.Engine`
  - functions: `recall/1`, `recall/2`
- `SpectreMnemonic.Recall.Fingerprint`
  - functions: `build/1`, `hamming_distance/2`, `hamming_similarity/2`
- `SpectreMnemonic.Recall.Index`
  - functions: `child_spec/1`, `delete/1`, `query/1`, `query/2`, `reset/0`, `start_link/0`, `start_link/1`, `upsert/1`
- `SpectreMnemonic.Recall.Packet`
- `SpectreMnemonic.Reflection.Adapter`
  - callbacks: `reflect/2`
- `SpectreMnemonic.Reflection.Packet`
- `SpectreMnemonic.SearchResult`
  - functions: `key/1`, `new/1`, `new/2`
- `SpectreMnemonic.Secrets`
  - functions: `encrypt/3`, `maybe_reveal/2`, `reveal/2`, `reveal_instruction/0`, `shred/1`, `shred/2`, `shred_report/1`, `shred_report/2`, `with_revealed/2`, `with_revealed/3`
- `SpectreMnemonic.Secrets.Authorization.Adapter`
  - callbacks: `authorize/2`
- `SpectreMnemonic.Secrets.Crypto.AESGCM`
- `SpectreMnemonic.Secrets.Crypto.Adapter`
  - callbacks: `decrypt/3`, `encrypt/3`, `shred/2` (optional)
