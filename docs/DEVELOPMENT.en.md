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
→ verify_rim_crossing (Standard mode, frame-by-frame rim check)
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
.venv/bin/python scripts/verify_rim_crossing.py --help
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

## 9. Manual packaging and DirectML pitfalls

### 9.1 Do not assemble the runtime directory by hand

The full contents of `runtime/` are defined by [`../scripts/prepare_windows_runtime.ps1`](../scripts/prepare_windows_runtime.ps1) (`engine/python`, `scripts`, `src`, `models/bball_model.pt`, `docs/architecture/SQLITE_SCHEMA_V1.sql`, `bin/ffmpeg.exe`, `bin/ffprobe.exe`). **Listing directories from memory will miss entries.** Missing `docs/architecture/SQLITE_SCHEMA_V1.sql` shows up as:

```text
FileNotFoundError: ...\runtime\docs\architecture\SQLITE_SCHEMA_V1.sql
create_project failed: {"code":"FILE_NOT_FOUND", ...}
```

The UI reports "file or folder not found" with a path under `runtime`, which is easy to mistake for a video-path problem. Run the official script instead, or regenerate with it after changing anything:

```powershell
powershell -File scripts\prepare_windows_runtime.ps1 -PythonRuntime <dir with python.exe> `
  -Ffmpeg <ffmpeg.exe> -Ffprobe <ffprobe.exe> -OutPath dist\windows-runtime
```

If you do assemble it manually, `Test-Path` every entry against the list and smoke-test with one `create_project` plus `open_project`.

### 9.2 A `runtime/` directory inside Release breaks incremental builds

The install step of `flutter build windows` cleans `build\windows\x64\runner\Release`. A hand-copied `runtime\` there, with the app still running, produces `MSB3073` / `cmake_install.cmake` failures. Close the app first, or keep the runtime outside the build directory.

### 9.3 onnxruntime and onnxruntime-directml cannot coexist

Both wheels install the same `onnxruntime/` package and overwrite each other; Python loads whichever version is higher. **The result is a silent fallback to CPU when you request `dml`, with no error** — the log just says `coarse_scan device=cpu`, which looks like "acceleration does nothing".

Check with:

```powershell
.venv\Scripts\python.exe -c "import onnxruntime as ort; print(ort.__version__, ort.get_available_providers())"
# DmlExecutionProvider must be present, and the version must match onnxruntime-directml
```

If two `dist-info` directories exist, run `pip uninstall onnxruntime onnxruntime-directml` and install only `onnxruntime-directml`. Note that `ultralytics[export-base]` pulls the plain `onnxruntime` back in, so re-check afterwards.

### 9.4 Do not inject the DML package through PYTHONPATH

[`../apps/desktop/lib/core/engine_client.dart`](../apps/desktop/lib/core/engine_client.dart) **overwrites** rather than appends `PYTHONPATH` when it launches the engine:

```dart
environment['PYTHONPATH'] = enginePythonPath;
```

Installing `onnxruntime-directml` into a temporary directory and pointing `PYTHONPATH` at it therefore has no effect: the engine subprocess never sees it. The acceleration package must be installed into the interpreter the engine actually uses (the one `BHE_PYTHON` points to).

### 9.5 Confirm acceleration actually took effect

Look at the completion line in `%LOCALAPPDATA%\BHE\logs\engine.log`:

```text
coarse_scan device=dml          # active
coarse_scan device=cpu          # fell back to CPU; see 9.3 / 9.4
```

DirectML must run one image at a time (`BACKEND_MAX_BATCH["dml"]=1`); batching is slower, which is a backend property rather than a bug.

## 10. Pre-submit checks

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

## 11. Issues and pull requests

A bug report should include the version/commit, OS, launch method, minimal reproduction, actual result, and expected result. Do not attach unsanitized videos, secrets, personal paths, or material containing player-identifying data.
