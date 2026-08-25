# Development Guide

[中文](DEVELOPMENT.md) · **English**

This guide is for contributors changing code, protocols, algorithms, or UI. Read the root [`CONTRIBUTING.md`](../CONTRIBUTING.md) first, then the product contracts and architecture documents for the affected area.

## 1. Development environment

Recommended:

- macOS Apple Silicon or Intel;
- Python 3.11;
- Flutter stable (the current development baseline is 3.44.8);
- FFmpeg/FFprobe;
- a local model and test video whose use is authorized;
- Git.

Create the Python environment:

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

Prepare desktop Flutter:

```bash
cd apps/desktop
flutter pub get
```

Prepare mobile Flutter:

```bash
cd apps/mobile
flutter pub get
```

Local models, videos, labels, screenshots, and build artifacts must stay out of Git. See [`../models/README.md`](../models/README.md), [`../data/README.md`](../data/README.md), and `.gitignore`.

## 2. Code boundaries

```text
apps/desktop/                 Flutter desktop UI and project state
apps/mobile/                  independent Flutter mobile app
packages/bhe_core/            shared mobile models, project package, engine interfaces
packages/bhe_runtime/         Rust/ONNX mobile native runtime
engine/python/                JSONL Engine, jobs, and storage adapters
engine/python/adapters/       algorithm and export adapters
src/basketball_highlight/     detection, event, trajectory, and review rules
scripts/                      analysis, export, runtime, and mobile build scripts
docs/architecture/            architecture, protocol, and database contracts
design-system/                UI design system
tests/                        Python tests
apps/desktop/test/            desktop Flutter tests
apps/mobile/test/             mobile Flutter tests
```

Key constraints:

- Desktop UI does not access SQLite, detection JSON, or FFmpeg directly.
- The desktop Engine exposes capabilities through JSONL.
- Mobile does not launch the desktop Python Engine; platform channels call media and native runtime code.
- The database stores facts; intermediate media and detection files live under the user's `artifacts/`.
- Source videos are referenced rather than copied, moved, or deleted by default.
- Export uses current database review state, not a UI cache.
- Previous candidates cannot be cleared before a new analysis succeeds.
- Update contracts and tests before changing protocols or the database.

## 3. Recommended workflow

### 3.1 Check the worktree and call chain first

```bash
git status --short --branch
git diff --stat
rg -n "command_name|handler_name|table_name" apps engine src scripts tests
```

Check for uncommitted work from another agent or developer. Do not overwrite, format, reset, or delete unrelated changes; use an independent worktree when isolation is needed.

### 3.2 Write acceptance criteria before implementation

Record reproducible input, expected output, and failure boundaries. Add a minimal Python test in `tests/` first; for Flutter interactions, cover state changes, disabled buttons, and error feedback.

### 3.3 Keep commits focused

```bash
git add path/to/changed/files
git diff --cached --check
git commit -m "docs: update runtime guide"
```

Do not add videos, models, build directories, `.venv`, screenshots, or machine-specific absolute paths.

## 4. Test commands

Source-publication check:

```bash
python3 scripts/check_open_source.py
```

Python:

```bash
.venv/bin/python -m pytest -q
.venv/bin/python -m pytest -q tests/test_engine.py tests/test_export_adapter.py
```

Desktop Flutter:

```bash
cd apps/desktop
flutter analyze
flutter test
flutter build macos --debug
```

Mobile Flutter:

```bash
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
```

Real-video analysis, Android/iOS native libraries, model outputs, and final exports still require target-platform manual acceptance; unit tests do not replace those checks.

## 5. Debug the desktop analysis pipeline

```text
validate_input
→ prepare_proxy
→ coarse_scan
→ generate_candidates
→ refine_candidates (Standard mode)
→ persist_candidates
→ prepare_review_previews
→ completed
```

Script help:

```bash
.venv/bin/python scripts/create_proxy.py --help
PYTHONPATH=src:scripts .venv/bin/python scripts/scan_video.py --help
.venv/bin/python scripts/generate_candidates.py --help
.venv/bin/python scripts/refine_dynamic_candidates.py --help
```

`--help` does not validate a real video, model, or ROI. Write debug output to a temporary directory, not the repository.

## 6. Analysis-mode changes

Fast and Standard are not separate products. Preserve:

- identical review, manual-range, keep/exclude, and export semantics;
- cache keys bound to video fingerprint, proxy parameters, model, and algorithm version;
- parameter snapshots and stage timings per analysis batch;
- previous results when a new batch fails or is cancelled;
- no artificial speedup by limiting candidate count;
- separate measurement of speed, recall, and error types on fixed videos.

After changing parameters, add a dated benchmark and update [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md). Do not turn one sample's timing into a universal promise.

## 7. UI changes

The desktop UI source of truth is [`../design-system/courtside/MASTER.md`](../design-system/courtside/MASTER.md). For review-workspace changes, preserve:

- the video as the primary area;
- clear feedback for navigation, playback, and review state;
- understandable export locking;
- responsive layouts that do not cover the video or timeline;
- keyboard focus, reduced motion, and light/dark themes.

Attach screenshots only when they are cleared for public use. Do not submit screenshots with local paths, real players, or real game footage.

## 8. Protocol, database, and mobile-runtime changes

When changing an Engine command, update:

1. [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md);
2. the Engine handler and Flutter client;
3. protocol and error-path tests;
4. compatibility notes.

When changing SQLite, update:

1. [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql);
2. storage initialization and reads/writes;
3. legacy-project, null, and migration tests;
4. lifecycle notes in [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md).

When changing mobile channels, the Rust C ABI, ONNX inputs/outputs, or ABIs, update [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md), Android/iOS build notes, and target-platform tests.

## 9. Pre-submit checks

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../mobile
flutter analyze
flutter test
cd ../..
git diff --check
git status --short --branch
```

Confirm:

- [ ] All changed files are UTF-8 without a BOM.
- [ ] No videos, data, models, screenshots, secrets, or build artifacts are included.
- [ ] No `/Users/...`, `/home/...`, or Windows user-specific absolute paths are included.
- [ ] Documentation commands match the actual directories and script arguments.
- [ ] Chinese and English entry points are synchronized.
- [ ] Protocol, database, mobile-runtime, or license impacts are documented.

## 10. Issues and pull requests

A bug report should include the version/commit, OS, launch method, minimal reproduction, actual result, and expected result. Do not attach unsanitized videos, secrets, personal paths, or material containing player-identifying data.
