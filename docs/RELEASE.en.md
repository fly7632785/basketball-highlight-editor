# Release Guide

[中文](RELEASE.md) · **English**

Treat releases as two separate deliverables:

1. **Source preview**: source, documentation, tests, and licenses;
2. **Desktop binary**: Flutter plus Python, dependencies, FFmpeg/FFprobe, and a model.

The current repository should be described as source preview only. A successful source build does not make an `.app`, APK, or model attachment a ready-to-install release.

## 1. Source-publication checklist

### Include

- `README.md` and `README.en.md`;
- getting-started, FAQ, development, release, architecture, and protocol docs;
- `LICENSE` and `NOTICE`;
- dependency, model, and data-rights guidance;
- local-use instructions for models, data, and screenshots.

### Do not include

- unverified `.pt`, `.onnx`, `.pth`, `.bin`, or other model/native-runtime binaries;
- real game videos, exported clips, real labels, or unsanitized screenshots;
- `.venv/`, `.tooling/`, `build/`, `dist/`, or personal paths;
- API keys, private keys, personal contact details, or third-party source checkouts;
- dependency paths that only work on one development machine.

Run the checks:

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
```

Every error from `check_open_source.py` must be fixed before publication. Warnings need an explicit decision and record. The current release blockers are listed in section 7 of this guide.

## 2. Rights review

| Item | Must be confirmed |
|---|---|
| Source | MIT file is included in the deliverable |
| Python dependencies | Locked versions, licenses, and notices |
| Flutter/Dart dependencies | Versions in `pubspec.lock` and notices |
| FFmpeg/FFprobe | Build configuration, LGPL/GPL boundary, and notices |
| Model code | Code license and redistribution terms |
| Model weights | Whether public download or bundling is allowed |
| Training data | Public-processing rights for original and derived data |
| Demo videos/screenshots | Rights for people, teams, venues, and footage |
| Android/iOS native libraries | Distribution terms for Rust, ONNX Runtime, and platform SDKs |

If model or training-data rights cannot be proven, publish source only and ask users to provide their own model. See [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md).

## 3. macOS build

### 3.1 Debug build

```bash
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter build macos --debug
```

This validates the Flutter UI build only; it does not prove that Python, the Engine, the model, or FFmpeg are embedded.

### 3.2 Prepare a portable runtime

Provide a portable Python directory containing the project dependencies:

```text
portable-python/
└── bin/python3
```

It must import `cv2`, `numpy`, `ultralytics`, and `torch`. Do not copy a developer `.venv` that contains absolute paths or machine-local libraries.

Use a self-contained or static FFmpeg/FFprobe build. Homebrew-dependent binaries are for local testing only; `BHE_ALLOW_EXTERNAL_FFMPEG=1` can be used explicitly for that purpose, but it is not a distribution solution.

### 3.3 Prepare the runtime directory

Place an authorized model at:

```text
models/bball_model.pt
```

From the repository root:

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/prepare_macos_runtime.sh dist/macos-runtime
```

The script copies the Engine, algorithm scripts, SQLite schema, model, and video tools, then runs the runtime check. Do not continue to the app build when it fails.

### 3.4 Build the Release `.app`

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

With code signing:

```bash
BHE_CODESIGN_IDENTITY="Developer ID Application: Example" \
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

`BHE_CODESIGN_IDENTITY` only triggers the script's signing step; it does not prove Apple notarization or Gatekeeper validation.

### 3.5 Clean-machine acceptance

Copy the `.app` to an environment without the source repository, Homebrew FFmpeg, the development `.venv`, or personal model paths. Verify at least:

1. the app finds its bundled Engine;
2. a project can be created and an authorized test video imported;
3. metadata and automatic/manual ROI setup work;
4. Standard analysis completes;
5. review, range adjustment, and export work;
6. project state survives reopening;
7. a moved source video can be relinked;
8. no video or model data is uploaded externally;
9. signing, notarization, and Gatekeeper installation work.

## 4. Experimental Windows release

Prepare the runtime:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare_windows_runtime.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -OutPath dist\windows-runtime
```

Build and create a zip:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -RuntimeOut dist\windows-runtime `
  -Zip
```

Windows remains a compatibility path. Validate the Flutter toolchain, Python/Torch/OpenCV/Ultralytics, FFmpeg DLLs, and installation flow; these scripts are not a formal installer or signing process.

## 5. Mobile release boundary

Android currently targets `arm64-v8a` and needs the Rust runtime, Android ONNX Runtime library, and a complete APK for that ABI. iOS project, media, and export paths can build, but local analysis still needs the Rust static library, the ONNX Runtime XCFramework, and Runner linking. Do not publish a build without these artifacts as a full AI-analysis release.

See [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) and [`../apps/mobile/README.md`](../apps/mobile/README.md) for the mobile build entry points.

## 6. Version and change records

Before a release:

1. Update the root [`CHANGELOG.md`](../CHANGELOG.md).
2. State the version and limitations in both README files.
3. Update architecture and compatibility notes for protocol or database changes.
4. Add a dated benchmark when algorithm parameters change.
5. List source and binary contents separately; never assume the model is part of the source license.
6. Use a traceable Git commit or tag.

Do not create a “stable” or “all-platform supported” release without a real artifact and acceptance evidence.

## 7. Current release blockers

Prefer source-only publication until the following are complete:

- remove or verify models, native binaries, research checkouts, and screenshots in the current source tree;
- generate notices for every locked dependency;
- confirm model-weight and training-data rights;
- replace demo material with publishable videos and screenshots;
- validate on a machine without the repository, Homebrew, or the development `.venv`;
- complete macOS signing, notarization, and Gatekeeper validation;
- complete Windows installer and mobile target-device validation.
