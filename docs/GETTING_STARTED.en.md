# Getting Started

[中文](GETTING_STARTED.md) · **English**

This guide is for developers running the repository for the first time. It covers the primary desktop path, the experimental Windows path, and the mobile development entry point.

## 1. Confirm the boundary

This repository is a source preview, not a final end-user installer. You provide:

- Python 3.11 and the project dependencies;
- Flutter stable (the current development baseline is 3.44.8);
- FFmpeg and FFprobe for desktop;
- the bundled default detector, or a compatible model if using a slim package without large assets;
- a game video that you are allowed to process.

The source license does not automatically cover models, videos, training data, FFmpeg builds, or third-party dependencies. Read [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md) and [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md) before publishing.

## 2. Desktop development on macOS/Linux

### 2.1 Clone the repository

```bash
git clone <repository-url>
cd basketball-highlight-editor
```

### 2.2 Create the Python environment

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -c "import cv2, numpy, pandas, psutil, torch, ultralytics; print('python imports: OK')"
```

If importing `torch` fails, install a compatible PyTorch build for the selected Python and CPU/Apple Silicon/Intel platform, then reinstall the project requirements. Do not treat a developer `.venv` as a distributable runtime.

### 2.3 Install FFmpeg

Homebrew is one option on macOS:

```bash
brew install ffmpeg
ffmpeg -version
ffprobe -version
```

A Homebrew build is suitable for local development, not automatically for a distributable `.app`. Distribution needs a self-contained or static build and an LGPL/GPL review.

### 2.4 Confirm the bundled model

The complete source repository currently includes the default desktop detector at:

```text
models/bball_model.pt
```

After a normal clone, you do not need to download a model manually. Pass a custom path only when a release package omits the model or you want to replace it:

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model /absolute/path/to/your-model.pt
```

If the model is actually missing, the Engine returns `MODEL_LOAD_FAILED` and does not silently download an unknown weight. A replacement must expose the classes and format expected by the current scripts, and you must have the right to use it.

### 2.5 Check the runtime

From the repository root:

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python
```

A successful check includes:

```text
runtime: OK
- engine: OK
- src: OK
- sqlite_schema: OK
- scripts: OK
- model: OK
- python_imports: OK
- ffmpeg: OK
- ffprobe: OK
```

This checks environment completeness, not model accuracy.

### 2.6 Run the desktop app

```bash
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

If the app cannot find the Engine or Python, set the development root explicitly:

```bash
BHE_REPO_ROOT="$(pwd)/../.." flutter run -d macos
```

Or specify Python directly:

```bash
BHE_REPO_ROOT="$(pwd)/../.." \
BHE_PYTHON="$(pwd)/../../.venv/bin/python" \
flutter run -d macos
```

The runtime lookup order and packaged layout are documented in [`DEVELOPMENT.en.md`](DEVELOPMENT.en.md) and [`RELEASE.en.md`](RELEASE.en.md).

## 3. First desktop workflow

1. Create a project and choose the source video.
2. Inspect filename, duration, resolution, frame rate, audio/video codecs, and file size.
3. Accept the automatic ROI (region of interest) suggestion, or draw the hoop region manually.
4. Set the analysis range and clip padding, then choose Standard or Fast.
5. Start analysis and watch its stage, progress, and elapsed time; cancel or retry when needed.
6. Review the source video, navigate candidates, exclude false positives, adjust ranges, or add a manual candidate.
7. Export clips separately or as one merged video. Candidates are included by default; only excluded candidates are left out.

An ROI that is too small can miss the ball trajectory; an ROI that is too large can increase false positives and processing time. Candidates are suspected events, not automatically confirmed scores.

## 4. Analysis modes

- **Standard**: creates a proxy, performs a coarse scan, and refines windows against the source video; quality first.
- **Fast**: uses a lower-cost proxy and skips source-video refinement; time first and may miss events.

The mode is locked once analysis starts. Cancel the current job before switching modes. Rules, caching, and inheritance are documented in [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md).

## 5. Experimental Windows path

Windows is not the current release gate, but a compatibility path is included. You need Python 3.11, the Flutter Windows toolchain, `ffmpeg.exe`, `ffprobe.exe`, a local model, and permission to run the tools.

Prepare dependencies in PowerShell:

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
```

Check the runtime:

```powershell
.\.venv\Scripts\python.exe scripts\check_runtime.py `
  --root . `
  --python .venv\Scripts\python.exe `
  --model models\bball_model.pt
```

Run the desktop app:

```powershell
cd apps\desktop
flutter pub get
flutter run -d windows
```

Portable runtime and archive commands are in [`RELEASE.en.md`](RELEASE.en.md).

## 6. Mobile development

Mobile is an independent Flutter project and does not launch the desktop Python Engine:

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Android native analysis currently targets `arm64-v8a`. After preparing a Rust target, Android NDK, and Android ONNX Runtime library:

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
rustup target add aarch64-linux-android
../../scripts/build_mobile_runtime.sh
flutter build apk --release
```

Without native runtime artifacts, Android UI and export can still build, but analysis returns `NATIVE_RUNTIME_UNAVAILABLE`. iOS project, playback, review, and export channels are available; local analysis still requires [`scripts/build_mobile_ios_runtime.sh`](../scripts/build_mobile_ios_runtime.sh) and Runner integration. See [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) and [`../apps/mobile/README.md`](../apps/mobile/README.md).

## 7. Debug the Engine separately

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

Minimal request:

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

stdout must contain only business JSONL; diagnostic logs go to stderr. [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md) is the protocol source of truth.

## 8. Export reviewed data

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project
```

Include pending candidates and write CSV as well:

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project \
  --include-pending \
  --csv
```

The output may contain real paths, notes, and player labels, so keep it local. See [`REVIEW_DATASET_EXPORT.md`](REVIEW_DATASET_EXPORT.md) for the fields.

## 9. Minimum acceptance path

- The runtime check passes.
- Python tests and affected Flutter tests pass.
- A project can be created and reopened.
- A video can be imported, an ROI saved, and analysis completed.
- Candidates can be played, excluded, range-adjusted, and manually added.
- Separate and merged exports both produce files.
- A moved source video is reported and can be relinked.
- Project and review state survive an app restart.
