# Release Guide

[中文](RELEASE.md) · **English**

There are two different release artifacts and they must be handled separately:

1. **Source preview**: source, documentation, tests, and licenses without model weights, real videos, or a final runtime;
2. **Desktop binary**: Flutter plus Python, dependencies, FFmpeg/FFprobe, and a model, requiring additional rights, signing, and clean-machine validation.

The current repository only promises the source preview. Until every checklist below is complete, do not describe a Release `.app` or model attachment as a ready-to-install product.

## 1. Source-preview release

### 1.1 Content audit

Confirm that the repository contains:

- `README.md` and `README.en.md`;
- setup, development, FAQ, release, and architecture documents under `docs/`;
- MIT `LICENSE`, `NOTICE`, `CONTRIBUTING.md`, and `SECURITY.md`;
- third-party and research-reference notes;
- local-use instructions for models, data, and screenshots;
- CI workflows and issue/PR templates.

Confirm that it does not contain:

- unverified `.pt`, `.onnx`, `.pth`, or `.bin` weights;
- videos, real labels, exported clips, or private screenshots;
- `.venv/`, `.tooling/`, `build/`, or `dist/`;
- API keys, private keys, personal absolute paths, or private contact details;
- unauthorized third-party checkouts or gitlinks.

### 1.2 Automated checks

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../..
git diff --check
```

Warnings may be advisory, but errors must be fixed. Review each warning before release, including dependency notices, model rights, and screenshot permissions.

### 1.3 Documentation audit

Confirm that:

- the Chinese and English READMEs have corresponding setup, model, run, and test commands;
- commands do not depend on a maintainer's `.tooling/` or absolute path;
- no model URL, GitHub URL, or maintainer email is invented;
- verified facts, current limitations, and future plans are separated;
- Fast mode reports measured timing without fixed accuracy or duration promises;
- Windows, mobile, Rust, and final installers are not described as complete.

## 2. Model, data, and dependency rights

Keep or verify these separately before release:

| Object | Required check |
|---|---|
| Source | retain the MIT file with the release |
| Python dependencies | locked versions and individual licenses |
| Flutter/Dart dependencies | versions in `pubspec.lock` and notices |
| FFmpeg/FFprobe | build configuration, LGPL/GPL boundary, and notices |
| Model code | code license and redistribution conditions |
| Model weights | whether public download or bundling is allowed |
| Training data | rights for original and derived data |
| Demo videos/screenshots | public rights for people, teams, venues, and frames |

If model or training-data rights cannot be proven, publish source only and ask users to provide their own model. See [MODEL_AND_DATA_LICENSES.md](MODEL_AND_DATA_LICENSES.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md).

## 3. macOS local build

### 3.1 Debug build

```bash
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter build macos --debug
```

This validates the Flutter UI build only. It does not prove that Python, the Engine, the model, or FFmpeg are embedded.

### 3.2 Prepare a portable runtime

A portable Python directory should contain at least:

```text
portable-python/
└── bin/python3
```

That interpreter must have the runtime dependencies installed and import `cv2`, `numpy`, `ultralytics`, and `torch`. Do not copy a developer `.venv`; it may contain absolute paths or machine-specific libraries.

Use self-contained or static FFmpeg and FFprobe builds. A Homebrew-dependent binary is rejected on macOS by the preparation script; `BHE_ALLOW_EXTERNAL_FFMPEG=1` is for local-only testing.

### 3.3 Prepare only the runtime directory

Place an authorized model at the repository convention:

```text
models/bball_model.pt
```

Then run:

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/prepare_macos_runtime.sh dist/macos-runtime
```

The script copies the Engine, scripts, algorithm package, SQLite schema, model, and video tools, then runs `check_runtime.py`. Do not continue to app packaging when it fails.

### 3.4 Build a Release `.app`

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

For code signing:

```bash
BHE_CODESIGN_IDENTITY="Developer ID Application: Example" \
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

`BHE_CODESIGN_IDENTITY` only enables the script's signing step. It does not complete Apple notarization or Gatekeeper validation.

### 3.5 Clean-machine validation

Copy the generated `.app` to a test directory or Mac without:

- the source repository;
- Homebrew FFmpeg;
- a developer `.venv`;
- a model or script at a developer-specific absolute path.

At minimum verify:

1. the app starts and finds its bundled Engine;
2. a project can be created;
3. an authorized test video can be imported;
4. video metadata can be read;
5. manual ROI works when automatic ROI fails;
6. Standard analysis completes;
7. review, range editing, and export work;
8. reopening the project preserves state;
9. moving the source video allows relinking;
10. no video or model data is uploaded externally.

## 4. Experimental Windows release

The Windows runtime preparation script requires a portable Python directory containing `python.exe` and installed dependencies:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare_windows_runtime.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -OutPath dist\windows-runtime
```

Build a Windows Release and zip:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -RuntimeOut dist\windows-runtime `
  -Zip
```

Before publishing, verify:

- the Flutter Windows toolchain version;
- the actual `BHE.exe` and `runtime/` layout;
- Python, Torch, OpenCV, and Ultralytics compatibility on target Windows versions;
- FFmpeg executable/DLL distribution rights;
- absence of developer-specific paths.

The Windows scripts are a compatibility path, not a replacement for a signed installer and user acceptance testing.

## 5. Version and changelog

Before release:

1. update `CHANGELOG.md`;
2. state the current version and limitations in both READMEs;
3. update architecture and compatibility notes when protocol or database changes;
4. add a dated benchmark when algorithm parameters change;
5. list source and binary contents separately, without treating a model as part of the source by default;
6. use a traceable Git commit or tag.

Do not create a “stable” release label without a real artifact and test evidence.

## 6. Current blockers for a formal release

According to [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md), prefer a source-only release until these are complete:

- per-version dependency notices are generated;
- model-weight and training-data rights are independently confirmed;
- public demos use cleared screenshots and videos;
- clean-machine runtime validation is complete without the repository, Homebrew, or a developer `.venv`;
- macOS signing, notarization, and Gatekeeper validation are complete;
- the Windows installer path and mobile CI are no longer open items.
