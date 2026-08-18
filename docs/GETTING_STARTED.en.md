# Getting Started

[中文](GETTING_STARTED.md) · **English**

This guide expands the README quick start for someone running Basketball Highlight Editor for the first time.

## 1. Know the current boundary

The repository is a source preview, not a final end-user installer. You must provide:

- Python 3.11 and the project dependencies;
- Flutter 3.44.8 stable;
- FFmpeg and FFprobe;
- A detector model that you are authorized to use;
- A basketball video that you are authorized to process.

Model, video, training-data, and dependency rights are separate. The MIT source license does not make a model or a video freely redistributable.

## 2. macOS development setup

### 2.1 Get the source

Use the remote URL configured for your own fork or mirror:

```bash
git clone <your-repository-url>
cd basketball-highlight-editor
```

### 2.2 Prepare Python

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

Check the interpreter and imports:

```bash
.venv/bin/python --version
.venv/bin/python -c "import cv2, numpy, pandas, psutil, torch, ultralytics; print('python imports: OK')"
```

If `torch` cannot be imported, install the PyTorch distribution appropriate for your Python and Apple Silicon/Intel platform, then reinstall the project requirements. Do not copy a developer `.venv` into a release runtime.

### 2.3 Prepare FFmpeg

For local development, Homebrew is one option:

```bash
brew install ffmpeg
ffmpeg -version
ffprobe -version
```

A Homebrew build is suitable for local development, not automatically for a distributable `.app`. Distribution needs a self-contained or static build and a separate FFmpeg license review.

### 2.4 Provide a model

Put an authorized model at:

```text
models/bball_model.pt
```

Model files are ignored by Git. The Engine returns `MODEL_LOAD_FAILED` when the model is missing; it does not silently download unknown weights. See [../models/README.md](../models/README.md).

### 2.5 Check the runtime

Run from the repository root:

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

A successful result includes:

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

Fix any failed item before launching the UI. The runtime checker detects missing environment pieces; it does not measure model accuracy.

## 3. Run the desktop app

The Flutter project is under `apps/desktop`. Run Flutter project commands there:

```bash
cd apps/desktop
flutter --version
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

The app searches for the Engine runtime in this order:

1. `BHE_RUNTIME_ROOT`;
2. `BHE_REPO_ROOT`;
3. macOS `.app/Contents/Resources/runtime`;
4. a `runtime` directory beside the Windows executable;
5. parent directories of the executable and working directory.

Launching from `apps/desktop` normally lets development builds find the repository root. If not, set it explicitly:

```bash
BHE_REPO_ROOT="$(pwd)/../.." flutter run -d macos
```

If Python is not inside the runtime directory:

```bash
BHE_REPO_ROOT="$(pwd)/../.." \
BHE_PYTHON="$(pwd)/../../.venv/bin/python" \
flutter run -d macos
```

Only use `BHE_ALLOW_SYSTEM_PYTHON=1` when you know that the system Python has every required dependency. It is not a distribution strategy.

## 4. First-use workflow

### Step A: Create a project and import a video

- Create a project directory.
- Select the source video.
- Wait for duration, resolution, frame rate, codecs, and file size.
- Confirm that the source video remains referenced rather than copied.

If the video is moved, the project reports that the source is missing. Use the relink action instead of editing SQLite directly.

### Step B: Set the analysis range and ROI

- Analyze the whole video or choose a smaller range for a trial.
- Try the automatic hoop ROI suggestion.
- If automatic suggestion fails, draw the region on the preview frame.
- Save the ROI before starting analysis.

ROI means region of interest. It controls which part of the frame the detector primarily observes. A region that is too small can miss the ball; a region that is too large can increase false positives and runtime.

### Step C: Choose an analysis mode

- **Standard**: proxy coarse scan plus source-video refinement, quality first;
- **Fast**: lower proxy cost and no source-video refinement, time first, with possible misses.

The mode is locked while a job is running. Cancel and restart if you need to switch modes. Fast results still require human review.

### Step D: Review candidates

The review workspace plays the source video rather than using the analysis proxy as the final edit source. Common actions:

- play, pause, and seek;
- move to the previous or next candidate;
- keep or exclude a candidate;
- change the clip start and end;
- add a note;
- create a manual candidate from the current playback position.

The product rule is “keep by default”: every candidate that is not excluded goes into export. Users do not need to confirm every candidate individually.

### Step E: Export

Before export, the Engine reads the current review state from SQLite:

- excluded candidates are not exported;
- pending candidates are exported by default;
- manual candidates are exported by default;
- merged export is ordered by event time and handles overlaps;
- final clips are cut from the source video, not the proxy.

## 5. Debug the Engine

Start the Engine separately:

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

Send the minimal `hello` request:

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

When debugging:

- stdout is the business JSONL stream; do not write ordinary logs there;
- stderr is diagnostic;
- Flutter normally owns Engine startup;
- [architecture/ENGINE_PROTOCOL_V1.md](architecture/ENGINE_PROTOCOL_V1.md) is the protocol source of truth.

## 6. Experimental Windows path

Windows is not a V1 release gate, but a compatible path is included. You need:

- Python 3.11;
- Flutter Windows desktop tooling;
- executable `ffmpeg.exe` and `ffprobe.exe`;
- a portable Python runtime;
- a local model.

In PowerShell:

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

See [RELEASE.en.md](RELEASE.en.md) for Windows runtime and packaging commands.

## 7. Export reviewed data

Export candidates that have review records:

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project
```

Include pending candidates and also write CSV:

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project \
  --include-pending \
  --csv
```

Do not publish files containing player identities, real source paths, or personal data. See [REVIEW_DATASET_EXPORT.md](REVIEW_DATASET_EXPORT.md) for fields.

## 8. Minimum acceptance after setup

- `scripts/check_runtime.py` reports `runtime: OK`;
- Python tests pass;
- Flutter analyze and tests pass;
- a project can be created and reopened;
- a video can be imported, an ROI saved, and analysis completed;
- candidates can be played, excluded, and adjusted;
- separate and merged exports both produce files;
- moving the source video produces a relink prompt;
- closing and reopening the app preserves project and review state.
