# Documentation Index

[中文](README.md) · **English**

The root [`README.en.md`](../README.en.md) is the product overview and shortest run path. This directory keeps only the core entries needed to use the product, understand its workflow, develop it, and package it.

## Find a document by task

| Goal | Start here |
|---|---|
| Install and run the desktop app | [`GETTING_STARTED.en.md`](GETTING_STARTED.en.md) |
| Troubleshoot candidates, models, FFmpeg, or plugin warnings | [`FAQ.en.md`](FAQ.en.md) |
| Change code or add tests | [`DEVELOPMENT.en.md`](DEVELOPMENT.en.md) |
| Package macOS/Windows | [`RELEASE.en.md`](RELEASE.en.md) |
| Understand the desktop architecture | [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md) |
| Debug the Flutter ↔ Engine protocol | [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md) |
| Understand project folders and caches | [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md) |
| Understand the mobile native runtime | [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) |

## User documentation

- [`GETTING_STARTED.en.md`](GETTING_STARTED.en.md): Python, Flutter, FFmpeg, model, runtime checks, first use, and the experimental Windows path.
- [`FAQ.en.md`](FAQ.en.md): startup, candidate, video, export, mobile, and macOS Swift Package Manager questions.

## Development and architecture

- [`DEVELOPMENT.en.md`](DEVELOPMENT.en.md): module boundaries, tests, debugging, protocol/database changes, and pre-commit checks.
- [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md): desktop UI, Python Engine, algorithms, storage, and job lifecycle.
- [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md): JSONL requests, responses, events, commands, and errors.
- [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md): source tree, user-project tree, and cache cleanup rules.
- [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md): Android/iOS media and Rust/ONNX integration boundaries.
- [`../engine/python/README.md`](../engine/python/README.md): standalone Engine startup and implemented commands.
- [`../apps/desktop/README.md`](../apps/desktop/README.md): desktop Flutter modules.
- [`../apps/mobile/README.md`](../apps/mobile/README.md): mobile development and native-runtime preparation.

## Product docs

- [`DECISIONS_V1.md`](DECISIONS_V1.md): current product, algorithm, and engineering decisions; check this and runtime behavior when records disagree.
- [`REQUIREMENTS_V1.md`](REQUIREMENTS_V1.md): V1 scope and implemented/partial/pending status.
- [`USER_FLOW_V1.md`](USER_FLOW_V1.md): import, analysis, review, export, and failure paths.
- [`SCREENSHOTS.en.md`](SCREENSHOTS.en.md): key screens and the user actions shown in each one.

## Release

- [`RELEASE.en.md`](RELEASE.en.md): source-preview release, desktop runtime, signing, notarization, and license checks.

## Documentation conventions

- “Implemented” means that the current code has the path; it does not mean every platform, video, or model is release-validated.
- “Verified” must point to a test, runtime observation, or reproducible experiment; one video's timing is not a universal guarantee.
- When source, documentation, and runtime disagree, check live runtime, protocol, and database facts before updating the docs.
- Do not put personal absolute paths, real video paths, secrets, unverified model URLs, or unsanitized screenshots in documentation.
- When protocol commands, database fields, analysis parameters, or release dependencies change, update this index and the relevant language entry points.

Database schema, model rights, and low-level performance records are development/release materials rather than product navigation entries; consult them only from the related documents when needed.
