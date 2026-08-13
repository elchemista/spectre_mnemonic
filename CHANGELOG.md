# Changelog

All notable changes to Spectre Mnemonic are documented in this file.

## [Unreleased]

## [0.3.0] - 2026-08-13

### Changed

- Retained GitHub-only distribution with no Hex package metadata.
- Replaced the GitHub Spectre dependency with the published Hex package at
  `~> 0.3.0`.
- Made default Credo analysis part of the required CI quality job.

### Fixed

- Serialized append and compaction operations for durable and progressive
  knowledge logs, preserving unique monotonic sequences under concurrency.
- Contained malformed options and adapter failures across focus, recall,
  governance, consolidation, action execution, embeddings, and secrets.
- Hardened Model2Vec artifact validation, checksum handling, download writes,
  and cache naming so distinct model identifiers cannot collide.

### Security

- Limited both compressed and declared expanded frame payloads to 64 MiB by
  default, configurable through `:max_frame_bytes`, before allocating or
  decoding persisted Erlang terms.
- Bound AES-GCM ciphertext to the current secret context and validated custom
  authorization, cryptography, and key-provider boundaries.

### Performance

- Replaced per-append persistent-term sequence writes with atomic counters.
- Removed repeated indexed list scans and incremental binary copying from
  binary embedding quantization.

## [0.2.0] - 2026-08-01

### Changed

- Raised the package, memory adapter, and Stack compatibility contracts to
  Spectre 0.2.0.
- Verified active memory, durable recall, subject isolation, and Agent memory
  integration against the Spectre 0.2.0 operational runtime.

### Compatibility

- Memory records and runtime handles remain outside canonical Run and
  operational checkpoints.

## [0.1.6] - 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and complete release documentation.
- Added no runtime functionality and made no intentional breaking API change.

[Unreleased]: https://github.com/elchemista/spectre_mnemonic/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/elchemista/spectre_mnemonic/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/elchemista/spectre_mnemonic/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/elchemista/spectre_mnemonic/compare/v0.1.5...v0.1.6
