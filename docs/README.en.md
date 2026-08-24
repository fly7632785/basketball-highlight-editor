# Documentation Index

[中文](README.md) · **English**

The root [`README.en.md`](../README.en.md) is the project overview and shortest run path. This directory is organized as getting started → troubleshooting → development → architecture → release. Product contracts and research notes are maintained for contributors who need to change the corresponding behavior.

## Find a document by task

| Goal | Start here |
|---|---|
| Install and run the desktop app | [`GETTING_STARTED.en.md`](GETTING_STARTED.en.md) |
| Troubleshoot candidates, models, FFmpeg, or plugin warnings | [`FAQ.en.md`](FAQ.en.md) |
| Change code, add tests, or submit a PR | [`DEVELOPMENT.en.md`](DEVELOPMENT.en.md) and [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |
| Package macOS/Windows | [`RELEASE.en.md`](RELEASE.en.md) |
| Understand the desktop architecture | [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md) |
| Debug the Flutter ↔ Engine protocol | [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md) |
| Understand project folders and caches | [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md) |
| Understand the mobile native runtime | [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) |
| Change the SQLite schema | [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql) |
| Export reviewed data | [`REVIEW_DATASET_EXPORT.md`](REVIEW_DATASET_EXPORT.md) |
| Understand Fast/Standard analysis | [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md) |
| Read the recorded performance sample | [`benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md`](benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md) |
| Audit model, data, and dependency rights | [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) |
| Review the source-publication gate | [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md) |

## User documentation

- [`GETTING_STARTED.en.md`](GETTING_STARTED.en.md): Python, Flutter, FFmpeg, model, runtime checks, first use, and the experimental Windows path.
- [`FAQ.en.md`](FAQ.en.md): startup, candidate, video, export, mobile, and macOS Swift Package Manager questions.
- [`REVIEW_DATASET_EXPORT.md`](REVIEW_DATASET_EXPORT.md): commands and fields for exporting reviewed candidates as JSONL/CSV.

## Development and architecture

- [`DEVELOPMENT.en.md`](DEVELOPMENT.en.md): module boundaries, tests, debugging, protocol/database changes, and pre-commit checks.
- [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md): desktop UI, Python Engine, algorithms, storage, and job lifecycle.
- [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md): JSONL requests, responses, events, commands, and errors.
- [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md): source tree, user-project tree, and cache cleanup rules.
- [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md): Android/iOS media and Rust/ONNX integration boundaries.
- [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql): project database schema.
- [`../engine/python/README.md`](../engine/python/README.md): standalone Engine startup and implemented commands.
- [`../apps/desktop/README.md`](../apps/desktop/README.md): desktop Flutter modules.
- [`../apps/mobile/README.md`](../apps/mobile/README.md): mobile development and native-runtime preparation.

## Product contracts and research

- [`DECISIONS_V1.md`](DECISIONS_V1.md): current product, algorithm, and engineering decisions; check this and runtime behavior when records disagree.
- [`REQUIREMENTS_V1.md`](REQUIREMENTS_V1.md): V1 scope and implemented/partial/pending status.
- [`USER_FLOW_V1.md`](USER_FLOW_V1.md): import, analysis, review, export, and failure paths.
- [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md): mode rules, caching, inheritance, and quality gates.
- [`benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md`](benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md): one cold-start timing record, not an accuracy promise.

## Open source and release

- [`RELEASE.en.md`](RELEASE.en.md): source-preview release, desktop runtime, signing, notarization, and license checks.
- [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md): current source-tree blockers.
- [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md): rights boundaries for models, training data, videos, and inference dependencies.
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md): consolidated runtime-dependency and research-reference list.
- Root [`CONTRIBUTING.md`](../CONTRIBUTING.md), [`SECURITY.md`](../SECURITY.md), [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md), [`CHANGELOG.md`](../CHANGELOG.md), and [`LICENSE`](../LICENSE).

## Documentation conventions

- “Implemented” means that the current code has the path; it does not mean every platform, video, or model is release-validated.
- “Verified” must point to a test, runtime observation, or reproducible experiment; one video's timing is not a universal guarantee.
- When source, documentation, and runtime disagree, check live runtime, protocol, and database facts before updating the docs.
- Do not put personal absolute paths, real video paths, secrets, unverified model URLs, or unsanitized screenshots in documentation.
- When protocol commands, database fields, analysis parameters, or release dependencies change, update this index and the relevant language entry points.

One-off local E2E records, license research notes, and research checkout manifests are no longer maintained as primary documents. Stable conclusions are consolidated into the product contracts and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md); the old files remain recoverable from Git history.
