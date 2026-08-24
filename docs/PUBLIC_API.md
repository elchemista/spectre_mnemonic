# Spectre Mnemonic public API — 0.4.0

This file is the normative public API manifest for Spectre Mnemonic `0.4.0`.
Its package and Stack contracts target Spectre `0.3.3` from Hex.
Compatibility guarantees apply only to the
modules and callables listed below. Any module, function, macro, or callback
not listed here is an implementation detail even when it is exported or
visible in generated docs.

Default arguments are expanded into every callable arity. For the listed
modules, documented types, opaque types, and documented struct fields are also
public. Modules with no callable row expose only their documented module,
type, and struct contract.

`SpectreMnemonic.Export.read/1,2` and `stream/1,2` decode and verify detached
`.mnemonic` exports. Version `0.4.0` exposes no `.mnemonic` import or live-memory
restore callable; persistent runtime recovery remains the responsibility of the
configured store replay path.

## Manifest

- `Spectre.Mnemonic`
  - functions: `config/1`
- `Spectre.Mnemonic.Memory`
  - functions: `options/1`, `options/2`, `remember/4`
- `SpectreMnemonic`
  - functions: `artifact/1`, `artifact/2`, `atlas/0`, `atlas/1`, `compact_knowledge/0`, `compact_knowledge/1`, `consolidate/0`, `consolidate/1`, `consolidate_observations/0`, `consolidate_observations/1`, `erase_partition/1`, `export/1`, `export/2`, `forget/1`, `forget/2`, `knowledge/0`, `knowledge/1`, `learn/1`, `learn/2`, `link/3`, `link/4`, `load_knowledge/0`, `load_knowledge/1`, `merge_entities/2`, `merge_entities/3`, `put_mental_model/1`, `put_mental_model/2`, `recall/1`, `recall/2`, `reflect/1`, `reflect/2`, `remember/1`, `remember/2`, `reveal/1`, `reveal/2`, `search/1`, `search/2`, `search_knowledge/1`, `search_knowledge/2`, `search_mental_models/1`, `search_mental_models/2`, `search_observations/1`, `search_observations/2`, `signal/1`, `signal/2`, `status/1`, `status/2`, `sweep_expired/0`, `sweep_expired/1`, `verify_observation/1`, `verify_observation/2`
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
- `SpectreMnemonic.Active.ETSOwner`
  - functions: `child_spec/1`, `member?/2`, `start_link/1`
- `SpectreMnemonic.Active.Focus`
  - functions: `action_recipes/1`, `action_recipes/2`, `artifact/1`, `artifact/2`, `artifacts/1`, `artifacts/2`, `associations/0`, `associations/1`, `child_spec/1`, `forget/1`, `forget/2`, `link/3`, `link/4`, `moments/0`, `moments/1`, `record_signal/2`, `start_link/1`, `status/1`, `status/2`
- `SpectreMnemonic.Active.Router`
  - functions: `child_spec/1`, `signal/2`, `start_link/1`
- `SpectreMnemonic.Active.Stream`
- `SpectreMnemonic.Active.StreamServer`
  - functions: `child_spec/1`, `signal/3`, `start_link/1`
- `SpectreMnemonic.Active.StreamSupervisor`
  - functions: `child_spec/1`, `ensure_stream/1`, `start_link/1`
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
  - functions: `child_spec/1`, `consolidate/0`, `consolidate/1`, `start_link/1`
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
- `SpectreMnemonic.Observations`
  - functions: `consolidate/0`, `consolidate/1`, `search/1`, `search/2`, `verify/1`, `verify/2`
- `SpectreMnemonic.Persistence.Compact.Adapter`
  - callbacks: `compact/2`
- `SpectreMnemonic.Persistence.Manager`
  - functions: `append/2`, `append/3`, `child_spec/1`, `compact/0`, `compact/1`, `config/0`, `get/2`, `get/3`, `put/1`, `put/2`, `replay/0`, `replay/1`, `search/1`, `search/2`, `start_link/0`, `start_link/1`
- `SpectreMnemonic.Persistence.Store.Adapter`
  - callbacks: `capabilities/1`, `delete_or_tombstone/3`, `get/3`, `put/2`, `replay/1`, `replay_fold/3`, `search/2`, `semantic_compact/2`
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
  - functions: `child_spec/1`, `recall/1`, `recall/2`, `start_link/1`
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
  - functions: `encrypt/3`, `maybe_reveal/2`, `reveal/2`, `reveal_instruction/0`, `shred/1`, `shred/2`
- `SpectreMnemonic.Secrets.Authorization.Adapter`
  - callbacks: `authorize/2`
- `SpectreMnemonic.Secrets.Crypto.AESGCM`
- `SpectreMnemonic.Secrets.Crypto.Adapter`
  - callbacks: `decrypt/3`, `encrypt/3`, `shred/2` (optional)
