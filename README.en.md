# Basketball Highlight Editor

> A local tool for detecting basketball scoring candidates, reviewing them manually, and exporting highlight clips from fixed-camera game videos.

[中文](README.md) · **English**

## Project status

**Current version: V1 source preview.** This repository is intended for developers who prepare the local runtime themselves; it is not a ready-to-install end-user package. Desktop is the primary product path. Mobile is an independent experimental app: Android has a native analysis path, while iOS local AI analysis still requires the final Rust/ONNX Runtime artifacts to be linked.

| Target | Status | Intended use |
|---|---|---|
| macOS Desktop | Primary path; complete import → analysis → review → export loop | Local long-video processing |
| Windows Desktop | Compatibility path with runtime and packaging scripts; release validation is still pending | Development and experiments |
| Android Mobile | Independent Flutter app; native frame extraction, Rust/ONNX analysis, review, and export are integrated; `arm64-v8a` is the current validation target | Mobile analysis and review experiments |
| iOS Mobile | Project, playback, review, and export are available; local analysis waits for native runtime linking | Mobile UI and media-flow validation |

> **Important:** model weights, input videos, training data, FFmpeg builds, and third-party dependencies do not automatically inherit this project's MIT License. Verify each item before publishing or redistributing it.

## Features

- Import a video and inspect duration, resolution, frame rate, codecs, and file size; the source video is referenced rather than copied by default.
- Automatically suggest a hoop ROI (region of interest), with manual drawing and adjustment as a fallback.
- Standard and Fast analysis modes: Standard favors quality; Fast favors shorter processing time and may miss events.
- Show analysis stages, progress, and elapsed time; support cancellation, retry, and interrupted-job discovery after restart.
- Review the source video, navigate candidates, keep or exclude them, add notes, adjust ranges, and add manual candidates.
- Candidates are included by default; only excluded candidates are left out of export, so users do not have to confirm every item individually.
- Export clips separately or merge them in event-time order; persist export history and statistics.
- Use SQLite on desktop for project, ROI, candidate, review, job, and export state.

## Scope

The current pipeline targets **fixed-camera, single-hoop, single-video** workflows. It generates high-recall suspected scoring events for human review. It does not promise referee-grade truth, and is not designed for moving cameras, multiple hoops, live streaming, cloud collaboration, or zero-false-positive unattended editing.

## Architecture

```text
Desktop Flutter UI ── JSONL ──> Python Engine ──> SQLite
                                     ├── OpenCV / Ultralytics: sampling and detection
                                     ├── Python analysis: candidates, trajectories, review rules
                                     └── FFmpeg / FFprobe: proxy, previews, and export

Mobile Flutter UI ── platform channels ──> Android/iOS media + Rust/ONNX Runtime
```

The desktop UI does not access SQLite, detection JSON, or FFmpeg directly. The Engine exposes a JSONL (JSON Lines, one JSON message per line) contract. The mobile app does not launch the desktop Python Engine; it shares data models through `packages/bhe_core` and uses native platform capabilities.

- [Desktop architecture](docs/architecture/ARCHITECTURE_V1.md)
- [Engine protocol](docs/architecture/ENGINE_PROTOCOL_V1.md)
- [Mobile runtime](docs/architecture/MOBILE_RUNTIME_V1.md)
- [Project layout and lifecycle](docs/architecture/PROJECT_LAYOUT_V1.md)

## Requirements

### Desktop

- macOS first; Windows remains an experimental compatibility path;
- Python 3.11;
- Flutter stable; the current development baseline is 3.44.8;
- `ffmpeg` and `ffprobe`;
- the bundled default detector (or a compatible model if using a slim release package);
- additional temporary disk space for analysis and export.

Python runtime requirements are in [`requirements.txt`](requirements.txt); development requirements are in [`requirements-dev.txt`](requirements-dev.txt).

### Mobile

- Flutter stable plus the corresponding Android Studio/Xcode toolchain;
- Android native analysis currently targets `arm64-v8a` and also needs Rust, the Android NDK, and the Android ONNX Runtime library;
- iOS local analysis also needs Rust iOS targets and an ONNX Runtime XCFramework;
- native artifacts should not include developer paths or unverified binaries in a public release.

## Quick start: desktop

The following commands target a macOS/Linux shell. See the PowerShell section in [`docs/GETTING_STARTED.en.md`](docs/GETTING_STARTED.en.md) for Windows.

### 1. Create a Python environment

```bash
git clone <repository-url>
cd basketball-highlight-editor

python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

### 2. Provide FFmpeg (the default model is bundled)

For macOS development, Homebrew is one option:

```bash
brew install ffmpeg
```

The repository currently includes the default desktop detector at:

```text
models/bball_model.pt
```

After a complete clone, you do not need to download or copy a model manually. If a release package omits the model, or you want to replace it, pass a custom path with `--model`. See [`docs/MODEL_AND_DATA_LICENSES.md`](docs/MODEL_AND_DATA_LICENSES.md) and [`models/README.md`](models/README.md).

### 3. Check the runtime

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python
```

Continue when the command reports `runtime: OK`. This validates environment completeness, not algorithmic accuracy.

### 4. Run the desktop app

```bash
cd apps/desktop
flutter pub get
flutter run -d macos
```

First-use flow: create a project → choose a video → inspect metadata → accept or draw the hoop ROI → choose a mode → analyze → review candidates → export.

For the complete setup, Windows path, and troubleshooting flow, see [`docs/GETTING_STARTED.en.md`](docs/GETTING_STARTED.en.md) and [`docs/FAQ.en.md`](docs/FAQ.en.md).

## Analysis modes

| Mode | Processing | Recommended use |
|---|---|---|
| Standard | Proxy coarse scan followed by source-video refinement | First runs, important games, or low tolerance for missed events |
| Fast | `640×480 / 3 FPS` lower-cost proxy; source-video refinement is skipped | Quick inspection when some missed events are acceptable |

Both modes keep the same review, manual-range, and export semantics. Fast mode has no fixed duration or accuracy guarantee and may miss events. See [`docs/research/ANALYSIS_MODES_V1.md`](docs/research/ANALYSIS_MODES_V1.md) for the complete rules.

The Fast entry point can be hidden at build time:

```bash
flutter run -d macos --dart-define=ENABLE_FAST_ANALYSIS=false
```

## Debug the Python Engine separately

The desktop app starts the Engine automatically. To inspect the protocol manually:

```bash
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

The Engine reads JSONL requests from stdin and writes JSONL responses to stdout; stderr is diagnostic only. Commands, events, and error codes are documented in [`docs/architecture/ENGINE_PROTOCOL_V1.md`](docs/architecture/ENGINE_PROTOCOL_V1.md).

## Mobile development

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Without native runtime artifacts, the Android UI can still build, but analysis returns `NATIVE_RUNTIME_UNAVAILABLE` instead of fabricating candidates. To build the Android native analysis library:

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
rustup target add aarch64-linux-android
../../scripts/build_mobile_runtime.sh
flutter build apk --release
```

See [`apps/mobile/README.md`](apps/mobile/README.md) and [`docs/architecture/MOBILE_RUNTIME_V1.md`](docs/architecture/MOBILE_RUNTIME_V1.md) for the mobile boundary and iOS runtime preparation.

## Tests and checks

```bash
# Source-publication check: tracked files and sensitive paths
python3 scripts/check_open_source.py

# Python tests
.venv/bin/python -m pytest -q

# Desktop Flutter
cd apps/desktop
flutter analyze
flutter test

# Mobile Flutter
cd ../mobile
flutter analyze
flutter test
```

Mobile native inference, model behavior, and real-video accuracy still require device-level validation; ordinary unit tests do not replace that acceptance step.

## Packaging boundary

A successful `flutter build macos --release` or Windows Release build does not make a user-ready installer. A distributable desktop package still needs portable Python and dependencies, FFmpeg/FFprobe, a model with verified redistribution rights, dependency notices, signing, notarization, and clean-machine validation.

Runtime preparation and packaging commands are consolidated in [`docs/RELEASE.en.md`](docs/RELEASE.en.md). Windows scripts remain experimental. Mobile native-runtime preparation is documented in [`docs/architecture/MOBILE_RUNTIME_V1.md`](docs/architecture/MOBILE_RUNTIME_V1.md).

## Documentation

- **Getting started:** [`docs/GETTING_STARTED.en.md`](docs/GETTING_STARTED.en.md) · [`docs/FAQ.en.md`](docs/FAQ.en.md)
- **Development:** [`docs/DEVELOPMENT.en.md`](docs/DEVELOPMENT.en.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md)
- **Architecture:** [`docs/README.en.md`](docs/README.en.md) · [`docs/architecture/`](docs/architecture/)
- **Product contracts:** [`docs/DECISIONS_V1.md`](docs/DECISIONS_V1.md) · [`docs/REQUIREMENTS_V1.md`](docs/REQUIREMENTS_V1.md) · [`docs/USER_FLOW_V1.md`](docs/USER_FLOW_V1.md)
- **Open source and release:** [`docs/RELEASE.en.md`](docs/RELEASE.en.md) · [`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md) · [`docs/MODEL_AND_DATA_LICENSES.md`](docs/MODEL_AND_DATA_LICENSES.md)
- **Community:** [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) · [`SECURITY.md`](SECURITY.md) · [`CHANGELOG.md`](CHANGELOG.md) · [`LICENSE`](LICENSE)

## Acknowledgments

This project was informed by the following open-source projects. We are grateful to their authors for sharing their work:

- [HoopCut](https://github.com/RuiYang0122/HoopCut): basketball video editing and highlight-product ideas;
- [basketball-highlights](https://github.com/reborncd/basketball-highlights): basketball scoring detection and candidate-clip ideas;
- [ShotMarker](https://github.com/zhangrunhao/ShotMarker): shot/scoring event marking and video-review ideas;
- [basketball_clipper](https://github.com/snowroll/basketball_clipper): hoop-region, trajectory reasoning, and clip-cutting ideas;
- [ball-yolo](https://github.com/griftt/ball-yolo): basketball object detection and YOLO application ideas;
- [basketball-highlights](https://github.com/ClarkWang1214/basketball-highlights): basketball highlight generation and edge-tool workflow ideas;
- [ai-sports-cut-agent](https://github.com/bond0060/ai-sports-cut-agent): AI sports-editing tools and model-engineering ideas;
- [Basketball-Shot-Detection](https://github.com/josephattalla/Basketball-Shot-Detection): provenance record for the default desktop weight and reference for ball/hoop detection ideas.

The default desktop weight at `models/bball_model.pt` currently has the same SHA-256 as `bball_model.pt` in the local research reference project [`Basketball-Shot-Detection`](https://github.com/josephattalla/Basketball-Shot-Detection): `40f3e596652a427ba290b3f72384e49aed12caf1a8ae41beaef4a8fffcf09fa3`. This project reorganizes the runtime, candidate generation, human review, and export workflow around that reference. Except for explicitly retained model files, the projects above are not runtime dependencies, and this project does not claim to copy their code. See [`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md) and [`docs/MODEL_AND_DATA_LICENSES.md`](docs/MODEL_AND_DATA_LICENSES.md) for the applicable model, dataset, and project-license boundaries.

## Privacy and data safety

- Source videos are referenced by path and metadata and are not copied or uploaded by default.
- Analysis, preview, review, and export are local by default.
- Do not commit real game videos, player images, team identifiers, labels, or exported clips.
- Model weights, training data, FFmpeg, and third-party dependencies require separate license checks.

## Contributing

Issues, test feedback, and focused fixes are welcome. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) first. Do not submit videos, models, screenshots, secrets, personal paths, or build artifacts.

## License

The source code is released under the [MIT License](LICENSE). This does not automatically cover model weights, training data, input videos, FFmpeg builds, or third-party dependencies. Read [`NOTICE`](NOTICE) and [`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md) before redistribution.
