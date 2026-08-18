# Basketball Highlight Editor

> A local desktop tool for detecting basketball scoring candidates, reviewing them manually, and exporting highlight clips from fixed-camera game videos.

[中文](README.md) · **English**

## Project status

This repository is currently a **V1 source-preview release**. It exposes the architecture, analysis workflow, and desktop loop for developers. It is not a final end-user installer: users must provide Python, FFmpeg/FFprobe, model weights, and test videos themselves, and verify the rights for each item.

The implemented product loop is:

```text
Import video → inspect metadata → suggest or draw the hoop ROI
→ create an analysis proxy → run local analysis → review candidates
→ adjust clip ranges → export separate clips or one merged highlight
```

## Scope

- Fixed-camera videos with one visible hoop;
- One project and one source video per analysis;
- Batch scanning of long videos to generate suspected scoring events;
- Human review before export: **a candidate is not a confirmed score**;
- macOS desktop first; Windows has compatible architecture and experimental packaging scripts;
- Local processing by default, with no account and no automatic upload of source videos.

The current version is not intended for moving cameras, multiple simultaneous hoops, live streaming, cloud collaboration, or zero-false-positive results without review.

## Features

- **Video import and metadata inspection**: duration, resolution, frame rate, codecs, and file size; the source video is referenced rather than copied.
- **Hoop-region setup**: automatic ROI (region of interest) suggestion when possible, with manual drawing as a fallback.
- **Two analysis modes**: Standard favors quality; Fast favors shorter processing time and may miss events.
- **Observable jobs**: stages, progress, elapsed time, cancellation, retry, and discovery of interrupted work after restart.
- **Review workspace**: play the source video, navigate candidates, keep or exclude candidates, add notes, adjust clip ranges, and add manual clips.
- **Simple review semantics**: candidates are kept by default, so users mainly remove false positives instead of confirming every item individually.
- **Export**: export clips separately or merge them in event-time order; export metadata and statistics are persisted.
- **Local project persistence**: SQLite stores video references, ROI data, candidates, review state, jobs, and export history.

## Architecture

```text
Flutter Desktop
    │ JSON Lines over stdin/stdout
    ▼
Python Engine
    ├── SQLite: project state, jobs, candidates, reviews, exports
    ├── OpenCV / Ultralytics: sampling and object detection
    ├── Python analysis package: candidate generation and review rules
    └── FFmpeg / FFprobe: proxy, previews, and final cuts
```

Flutter does not access SQLite, detection JSON, or FFmpeg directly. The Engine exposes the JSONL (JSON Lines, one JSON message per line) contract in [docs/architecture/ENGINE_PROTOCOL_V1.md](docs/architecture/ENGINE_PROTOCOL_V1.md). See [docs/architecture/ARCHITECTURE_V1.md](docs/architecture/ARCHITECTURE_V1.md) for system boundaries.

## Requirements

| Component | Requirement |
|---|---|
| Operating system | macOS desktop first; Windows support remains experimental |
| Flutter | `3.44.8` stable, or a compatible SDK |
| Python | `3.11` recommended |
| Python packages | `ultralytics`, `opencv-python`, `numpy`, `pandas`, `psutil`; `pytest` for development |
| Video tools | `ffmpeg` and `ffprobe` on `PATH`, or supplied in a packaged runtime |
| Model | A basketball detector compatible with the current pipeline, conventionally at `models/bball_model.pt` |
| Disk space | Extra temporary space is required for analysis and export; the app checks available space before heavy jobs |

Flutter video plugins may print a warning that they do not support Swift Package Manager on macOS. This is not currently the direct cause of a runtime failure. If a future Flutter release turns it into an error, update the plugins or use versions that provide SPM support; see [docs/FAQ.en.md](docs/FAQ.en.md).

## Quick start

The following commands target a macOS/Linux shell. Windows instructions are in [docs/GETTING_STARTED.en.md](docs/GETTING_STARTED.en.md).

### 1. Clone and prepare Python

```bash
git clone <your-repository-url>
cd basketball-highlight-editor

python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

Do not commit `.venv/`. If `python3.11` is unavailable, install Python 3.11 and repeat the commands.

### 2. Provide FFmpeg and a model

For local macOS development, one possible setup is:

```bash
brew install ffmpeg
```

Place a model that you are authorized to use at:

```text
models/bball_model.pt
```

The repository does not publish an unverified model URL and does not silently download unknown weights. Read [docs/MODEL_AND_DATA_LICENSES.md](docs/MODEL_AND_DATA_LICENSES.md) and [models/README.md](models/README.md) before adding a model.

### 3. Check the runtime

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

Continue when the command reports `runtime: OK`. Fix the reported model, Python package, FFmpeg, or repository-file problem first if it fails.

### 4. Run the desktop app

```bash
cd apps/desktop
flutter pub get
flutter run -d macos
```

Recommended first-use flow:

1. Create a project and select a source video.
2. Check the video metadata and analysis range.
3. Accept the automatic ROI suggestion or draw the hoop region manually.
4. Choose Standard or Fast analysis and start the job.
5. Review candidates in the workspace, exclude false positives, and adjust ranges when needed.
6. Export separate clips or one merged highlight.

See [docs/GETTING_STARTED.en.md](docs/GETTING_STARTED.en.md) for the complete setup and troubleshooting path.

## Run the Python Engine separately

The desktop app starts the Engine automatically. To inspect the protocol manually:

```bash
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

The Engine reads JSONL requests from stdin and writes JSONL responses to stdout. `stderr` is diagnostic only. Minimal request:

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

Commands, events, error codes, and compatibility rules are documented in [docs/architecture/ENGINE_PROTOCOL_V1.md](docs/architecture/ENGINE_PROTOCOL_V1.md).

## Analysis modes

| Mode | Goal | Processing | When to use |
|---|---|---|---|
| Standard | Quality first | Proxy coarse scan plus source-video refinement | First analysis, important games, or low tolerance for missed events |
| Fast | Time first | Lower-cost proxy and coarse candidates without source refinement | Quick inspection when a small amount of recall loss is acceptable |

Fast mode has no fixed accuracy or duration guarantee. In the current benchmark, a cold run on one roughly 4.6-minute sample took `75.73s` in Standard mode and `42.07s` in Fast mode, a measured `44.4%` reduction. That sample had no complete human ground truth, so it does not establish recall. See [docs/research/ANALYSIS_MODES_V1.md](docs/research/ANALYSIS_MODES_V1.md) and [docs/research/ANALYSIS_MODE_BENCHMARK_20260812.md](docs/research/ANALYSIS_MODE_BENCHMARK_20260812.md).

The Fast entry point can be hidden at build time:

```bash
flutter run -d macos --dart-define=ENABLE_FAST_ANALYSIS=false
```

## Tests and checks

```bash
# Source-only release audit; no Python runtime dependencies required
python3 scripts/check_open_source.py

# Python tests
.venv/bin/python -m pytest -q

# Flutter desktop checks
cd apps/desktop
flutter analyze
flutter test
```

Equivalent Make targets are available from the repository root:

```bash
make check-open-source
make python-test
make flutter-desktop-analyze
make flutter-desktop-test
```

The local end-to-end evidence is in [docs/LOCAL_E2E_V1.md](docs/LOCAL_E2E_V1.md). Passing tests does not turn algorithmic candidates into ground-truth scoring events; review remains part of the product flow.

## Packaging and release boundaries

### macOS

Local Debug build:

```bash
cd apps/desktop
flutter build macos --debug
```

A distributable runtime additionally needs portable Python and dependencies, self-contained or static FFmpeg/FFprobe, and a model whose redistribution rights are confirmed:

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

The script does not solve model licensing, signing, notarization, or clean-machine installation verification. A successful `Release .app` build is not yet a final distributable installer. See [docs/RELEASE.en.md](docs/RELEASE.en.md) and [docs/MACOS_PACKAGING_V1.md](docs/MACOS_PACKAGING_V1.md).

### Windows

Windows runtime and packaging scripts are included, but Windows is not a V1 release gate. Prepare portable Python, FFmpeg, FFprobe, and a model; the exact PowerShell commands are in [docs/RELEASE.en.md](docs/RELEASE.en.md).

## Documentation

### User and runtime guides

- [docs/GETTING_STARTED.en.md](docs/GETTING_STARTED.en.md): environment setup, first run, and the product workflow
- [docs/FAQ.en.md](docs/FAQ.en.md): model, FFmpeg, Engine, empty-candidate, missing-video, and plugin-warning troubleshooting
- [docs/README.en.md](docs/README.en.md): complete documentation index

### Development and architecture

- [docs/DEVELOPMENT.en.md](docs/DEVELOPMENT.en.md): development setup, tests, debugging, and pre-commit checks
- [docs/architecture/ARCHITECTURE_V1.md](docs/architecture/ARCHITECTURE_V1.md): system boundaries and responsibilities
- [docs/architecture/ENGINE_PROTOCOL_V1.md](docs/architecture/ENGINE_PROTOCOL_V1.md): Flutter ↔ Python Engine JSONL contract
- [docs/architecture/PROJECT_LAYOUT_V1.md](docs/architecture/PROJECT_LAYOUT_V1.md): repository and user-project layout
- [docs/architecture/SQLITE_SCHEMA_V1.sql](docs/architecture/SQLITE_SCHEMA_V1.sql): SQLite schema
- [design-system/courtside/MASTER.md](design-system/courtside/MASTER.md): desktop UI design system

### Product and research

- [docs/REQUIREMENTS_V1.md](docs/REQUIREMENTS_V1.md): V1 scope, acceptance status, and non-goals
- [docs/USER_FLOW_V1.md](docs/USER_FLOW_V1.md): user flow and failure paths
- [docs/DECISIONS_V1.md](docs/DECISIONS_V1.md): product, algorithm, and engineering decisions
- [docs/research/ANALYSIS_MODES_V1.md](docs/research/ANALYSIS_MODES_V1.md): Fast/Standard rules

### Open source and release

- [docs/RELEASE.en.md](docs/RELEASE.en.md): release checklist, runtime packaging, signing, and licenses
- [docs/OPEN_SOURCE_AUDIT.md](docs/OPEN_SOURCE_AUDIT.md): source-publication audit and remaining blockers
- [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md): runtime components and research references
- [docs/MODEL_AND_DATA_LICENSES.md](docs/MODEL_AND_DATA_LICENSES.md): model, data, and video rights
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution guide
- [SECURITY.md](SECURITY.md): vulnerability reporting
- [LICENSE](LICENSE): source license

## Privacy and data safety

- The source video is referenced by path and metadata by default, not copied into the project.
- Analysis, previews, review, and export are local by default.
- Do not commit real game videos, player images, team identifiers, or private labels.
- Model and training-data rights are separate from the source-code license.
- Obtain explicit consent before enabling any telemetry or data-export workflow.

## Known limitations

- Automatic output is a candidate list, not a referee decision; review it before export.
- The current pipeline targets fixed-camera, single-hoop scenes.
- The source preview does not include model weights, real videos, or a final end-user installer.
- macOS distribution still requires a portable runtime, FFmpeg licensing review, code signing, notarization, and clean-machine testing.
- Windows and mobile support are compatibility/research work, not current release gates.
- Rust/ONNX Runtime migration is not a V1 runtime prerequisite; the current Engine is Python-based.

## Contributing

Issues, test feedback, and focused fixes are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and do not submit videos, models, private labels, secrets, personal paths, or build artifacts.

## License

The source code is released under the MIT License. The license does not automatically cover model weights, training data, input videos, FFmpeg builds, or third-party dependencies. Verify each item separately and ship its notices when distributing it.
