# Development Guide

[中文](DEVELOPMENT.md) · **English**

This guide is for contributors changing code, protocols, algorithms, or UI. It does not replace the architecture and protocol documents. When sources disagree, check `docs/DECISIONS_V1.md`, the relevant contract, and live runtime behavior.

## 1. Development environment

Recommended:

- macOS Apple Silicon or Intel;
- Python 3.11;
- Flutter 3.44.8 stable;
- FFmpeg/FFprobe;
- a local model with confirmed usage rights;
- Git and Make.

Create the Python environment:

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

Prepare Flutter:

```bash
cd apps/desktop
flutter pub get
```

Local models and videos are not part of Git. See `models/README.md`, `data/README.md`, and `.gitignore`.

## 2. Code boundaries

```text
apps/desktop/                 Flutter UI and client state
engine/python/                JSONL Engine, jobs, and storage adapters
engine/python/adapters/       adapters for analysis and export scripts
src/basketball_highlight/     reusable detection, event, trajectory, review rules
scripts/                      standalone analysis, export, and runtime scripts
docs/architecture/            architecture, protocol, and database contracts
design-system/                UI design system
tests/                        Python tests
apps/desktop/test/            Flutter tests
```

Important constraints:

- the UI does not access SQLite, detection JSON, or FFmpeg directly;
- the Engine exposes capabilities through JSONL;
- the database stores facts while large intermediates live under `artifacts/`;
- the source video is referenced, not copied, moved, or automatically deleted;
- export reads the current database review state instead of trusting UI cache;
- old candidates are not cleared until a new analysis result is validated and committed;
- protocol or database changes require contract and test updates first.

## 3. Recommended workflow

### 3.1 Inspect state and call paths first

```bash
git status --short --branch
git diff --stat
rg -n "command_name|handler_name|table_name" apps engine src scripts tests
```

Check for uncommitted work from another agent or developer. Do not overwrite, format, or reset unrelated changes.

### 3.2 Write acceptance criteria before implementation

For every feature or bug, record a reproducible input, expected output, and failure boundaries. For Python logic, add a minimal test under `tests/`; for Flutter interaction, cover state changes, disabled buttons, and error feedback under `apps/desktop/test/`.

### 3.3 Keep commits focused

```bash
git add path/to/changed/files
git diff --cached --check
git commit -m "docs: explain local runtime setup"
```

Do not commit videos, models, build directories, `.venv`, screenshots, or developer-specific absolute paths.

## 4. Test commands

Source-publication audit:

```bash
python3 scripts/check_open_source.py
```

Python:

```bash
.venv/bin/python -m pytest -q
```

A focused test run:

```bash
.venv/bin/python -m pytest -q tests/test_engine.py tests/test_export_adapter.py
```

Flutter:

```bash
cd apps/desktop
flutter analyze
flutter test
```

Local Engine protocol smoke test:

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

A `media_kit` initialization notice in Flutter tests is not the same as a failed test; use the command exit code and test result as the source of truth.

## 5. Debug the analysis pipeline

The main analysis stages are:

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

The scripts need a real video, model, and ROI for meaningful validation. Put debug outputs in a temporary directory, not in `data/` or the repository root.

## 6. Analysis-mode changes

Fast and Standard are not separate products. Keep these semantics aligned:

- review, manual ranges, keep/exclude, and export behave the same;
- Fast and Standard caches do not overwrite each other;
- every batch stores its actual parameter snapshot;
- failed or cancelled new batches leave the previous result available;
- Fast mode must not fake speed by limiting candidate count;
- speed and recall are measured separately on fixed videos.

After changing parameters, add a dated benchmark and update [research/ANALYSIS_MODES_V1.md](research/ANALYSIS_MODES_V1.md). Do not turn one sample's timing into a universal guarantee.

## 7. UI changes

The desktop UI source of truth is [../design-system/courtside/MASTER.md](../design-system/courtside/MASTER.md). For review-workspace changes, preserve:

- the video as the primary workspace;
- clear feedback for navigation, playback, and review state;
- understandable export locks;
- usable video and timeline layout at responsive widths;
- keyboard focus, reduced motion, and light/dark themes.

Attach a public-safe screenshot for visual changes. Do not submit screenshots containing local paths, real players, or real videos.

## 8. Protocol and database changes

When changing an Engine command, update:

1. `docs/architecture/ENGINE_PROTOCOL_V1.md`;
2. the Engine handler and Flutter client;
3. protocol tests and error-path tests;
4. the compatibility note.

When changing SQLite, update:

1. `docs/architecture/SQLITE_SCHEMA_V1.sql`;
2. storage initialization and read/write code;
3. old-project, null-value, and migration tests;
4. the lifecycle notes in [architecture/PROJECT_LAYOUT_V1.md](architecture/PROJECT_LAYOUT_V1.md).

## 9. Pre-commit checklist

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../..
git diff --check
git status --short --branch
```

Confirm:

- [ ] all modified files are UTF-8 without BOM;
- [ ] no models, videos, screenshots, build artifacts, or secrets;
- [ ] no `/Users/...`, `/home/...`, or Windows machine-specific paths;
- [ ] documentation commands match actual directories and script arguments;
- [ ] Chinese and English docs are updated together;
- [ ] test commands and known limitations are documented;
- [ ] protocol, database, and license impact is recorded.

## 10. Issues and pull requests

Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. A bug report should include the version/commit, OS, launch method, minimal reproduction, actual result, and expected result. Do not attach unsanitized videos, secrets, or personal data.
