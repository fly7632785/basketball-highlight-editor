# Documentation Index

[中文](README.md) · **English**

This directory is organized as tutorials → how-to guides → reference contracts → explanations. Start with the root [README.en.md](../README.en.md) for the project overview; use this index for the complete map.

## Find a document by task

| Goal | Start here |
|---|---|
| Install and run for the first time | [GETTING_STARTED.en.md](GETTING_STARTED.en.md) |
| Troubleshoot startup, models, FFmpeg, or candidates | [FAQ.en.md](FAQ.en.md) |
| Change code, write tests, or submit a PR | [DEVELOPMENT.en.md](DEVELOPMENT.en.md) and [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Package macOS/Windows | [RELEASE.en.md](RELEASE.en.md) and [MACOS_PACKAGING_V1.md](MACOS_PACKAGING_V1.md) |
| Understand Flutter and the Python Engine | [architecture/ARCHITECTURE_V1.md](architecture/ARCHITECTURE_V1.md) |
| Debug JSONL commands and events | [architecture/ENGINE_PROTOCOL_V1.md](architecture/ENGINE_PROTOCOL_V1.md) |
| Understand project directories and cache lifetime | [architecture/PROJECT_LAYOUT_V1.md](architecture/PROJECT_LAYOUT_V1.md) |
| Change or migrate SQLite | [architecture/SQLITE_SCHEMA_V1.sql](architecture/SQLITE_SCHEMA_V1.sql) |
| Understand product scope and acceptance | [REQUIREMENTS_V1.md](REQUIREMENTS_V1.md) |
| Follow user and failure flows | [USER_FLOW_V1.md](USER_FLOW_V1.md) |
| Review confirmed product/algorithm decisions | [DECISIONS_V1.md](DECISIONS_V1.md) |
| Understand Fast/Standard analysis | [research/ANALYSIS_MODES_V1.md](research/ANALYSIS_MODES_V1.md) |
| Read the current performance benchmark | [research/ANALYSIS_MODE_BENCHMARK_20260812.md](research/ANALYSIS_MODE_BENCHMARK_20260812.md) |
| Export reviewed training data | [REVIEW_DATASET_EXPORT.md](REVIEW_DATASET_EXPORT.md) |
| Audit models, data, and dependencies | [MODEL_AND_DATA_LICENSES.md](MODEL_AND_DATA_LICENSES.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) |
| Review the public-release audit | [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md) |

## Tutorials and how-to guides

- [GETTING_STARTED.en.md](GETTING_STARTED.en.md): Python, Flutter, FFmpeg, model, runtime checks, first use, and the experimental Windows path.
- [FAQ.en.md](FAQ.en.md): common errors, the macOS SPM warning, empty candidates, long clips, export locks, and data safety.
- [REVIEW_DATASET_EXPORT.md](REVIEW_DATASET_EXPORT.md): commands and fields for exporting reviewed candidates as JSONL/CSV.
- [LOCAL_E2E_V1.md](LOCAL_E2E_V1.md): one local Engine-loop evidence record, not an accuracy promise.

## Development and architecture

- [DEVELOPMENT.en.md](DEVELOPMENT.en.md): code boundaries, tests, debugging, analysis-mode changes, protocol/database changes, and pre-commit checks.
- [architecture/ARCHITECTURE_V1.md](architecture/ARCHITECTURE_V1.md): Flutter UI, Python Engine, algorithms, storage, and job lifecycle.
- [architecture/ENGINE_PROTOCOL_V1.md](architecture/ENGINE_PROTOCOL_V1.md): JSONL requests, responses, events, commands, errors, and compatibility rules.
- [architecture/PROJECT_LAYOUT_V1.md](architecture/PROJECT_LAYOUT_V1.md): source tree, user-project tree, and cache cleanup rules.
- [architecture/SQLITE_SCHEMA_V1.sql](architecture/SQLITE_SCHEMA_V1.sql): project database schema.
- [../engine/python/README.md](../engine/python/README.md): standalone Engine startup and implemented-command overview.
- [../apps/desktop/README.md](../apps/desktop/README.md): Flutter desktop modules and local development.

## Product, decisions, and research

- [DECISIONS_V1.md](DECISIONS_V1.md): current product, algorithm, and engineering decisions; the first reference when sources disagree.
- [REQUIREMENTS_V1.md](REQUIREMENTS_V1.md): V1 scope, acceptance status, and non-blocking items.
- [USER_FLOW_V1.md](USER_FLOW_V1.md): import, analysis, review, export, and failure recovery.
- [research/ANALYSIS_MODES_V1.md](research/ANALYSIS_MODES_V1.md): Fast/Standard rules, caching, inheritance, and quality gates.
- [research/ANALYSIS_MODE_BENCHMARK_20260812.md](research/ANALYSIS_MODE_BENCHMARK_20260812.md): current single-sample cold-start benchmark and limits.
- [research/LICENSE_NOTES.md](research/LICENSE_NOTES.md): third-party repository and license notes from research.
- [research/THIRD_PARTY_MANIFEST.md](research/THIRD_PARTY_MANIFEST.md): origins and fixed commits for research checkouts.

## Open source and release

- [RELEASE.en.md](RELEASE.en.md): source-preview release, dependency rights, macOS runtime, Windows compatibility packaging, and clean-machine acceptance.
- [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md): removed items, remaining work, and binary-release blockers.
- [MODEL_AND_DATA_LICENSES.md](MODEL_AND_DATA_LICENSES.md): rights boundaries for models, training data, videos, and inference dependencies.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): runtime dependencies versus research references.
- [../CONTRIBUTING.md](../CONTRIBUTING.md): issue, PR, test, and privacy requirements.
- [../SECURITY.md](../SECURITY.md): security reporting.
- [../CHANGELOG.md](../CHANGELOG.md): changelog.

## Documentation conventions

- “Currently verified” means there is a recorded test or runtime observation; it does not mean every video will be accurate.
- When source, configuration, and runtime behavior disagree, prefer live runtime, protocol, and database facts.
- When adding a protocol command, database field, algorithm parameter, or release dependency, update both language entry points and the relevant reference document.
- Do not add machine-specific absolute paths, real video paths, secrets, model URLs, or uncleared screenshots to docs.
- Research documents record experiments; product contracts live in `DECISIONS_V1.md` and the relevant architecture document.
