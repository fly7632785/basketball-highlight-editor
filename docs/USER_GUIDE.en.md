# User Guide

[中文](USER_GUIDE.md) · **English**

Basketball Highlight Editor scans a game video locally, produces possible scoring events, and lets you decide what belongs in the final highlight. Candidates are suggestions, not confirmed facts. The original video is not uploaded by default.

## 1. Install and run

The most complete path is the macOS desktop app. Windows has a compatibility path. Mobile is a separate Flutter project.

You need Python 3.11, Flutter stable, and FFmpeg/FFprobe. On macOS:

```bash
brew install ffmpeg
git clone <repository-url>
cd basketball-highlight-editor
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

The full source checkout includes the default desktop model at `models/bball_model.pt`. If it is missing, the Engine returns `MODEL_LOAD_FAILED`; it never silently downloads weights from an unknown URL.

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

Use `BHE_REPO_ROOT` and `BHE_PYTHON` when the app cannot locate the repository runtime.

## 2. First project

```text
New project → Import video → Set range → Set detection areas → Choose mode
→ Analyze → Review candidates → Adjust or add missing clips → Export
```

1. Create a project and select a video you are allowed to process.
2. Check the video metadata. The project stores a reference to the original file instead of copying or uploading it.
3. Set the analysis range and choose the suggested ROI, or adjust the shooting and net areas manually.
4. Choose Standard or Fast analysis.
5. Review the generated candidates. Candidates are included by default; only excluded candidates are left out of exports.
6. Adjust ranges, add player labels or notes, and create manual candidates when the detector misses an event.
7. Merge the clips or export them separately. The result page offers **Open folder**.

## 3. Analysis modes

| Mode | Use it when | Trade-off |
|---|---|---|
| **Standard** | You want a more complete result | Slower; refines candidates against the source video |
| **Fast** | You need a first pass quickly | Uses a `640×480 / 3 FPS` proxy and skips source-video refinement; may miss events |

New projects default to Standard and remember the last choice per project. The mode is locked after analysis starts. Cancel the task before switching. Review, manual edits, and export use the same rules in both modes.

## 4. Main screens

The screenshots below use the dark theme. The light theme changes colors only; the controls and workflow stay the same.

![Dark project home](../capture/screenshot-20260813-145724.png)

![Dark video import](../capture/screenshot-20260813-145741.png)

![Dark analysis range](../capture/screenshot-20260813-145806.png)

![Dark detection areas](../capture/screenshot-20260813-145835.png)

![Dark analysis confirmation](../capture/screenshot-20260813-145844.png)

![Dark analysis progress](../capture/screenshot-20260813-145855.png)

The review workspace keeps the video large and the candidate list beside it. Select a candidate to switch playback; switching does not change its status. Use the checkmark to include and the X to exclude. The player supports seeking, speed control, replay, looping, source/proxy switching, and annotation toggling.

![Dark review workspace](../capture/screenshot-20260813-150054.png)

Excluded candidates stay visible so they can be restored or checked again. The filter can show all, pending, included, excluded, or low-confidence candidates.

![Dark excluded candidate](../capture/screenshot-20260813-150109.png)

Use **Adjust clip range** to edit the export window. The default is six seconds before the event and three seconds after it. **Reset default**, **Cancel**, and **Apply** have their literal meanings.

![Dark clip range editor](../capture/screenshot-20260813-150120.png)

Player labels can be created or assigned in a candidate card and used as an export filter. They do not change inclusion status.

![Dark player labels](../capture/screenshot-20260813-150302.png)

For a missed event, pause the source video and use **Add candidate from current time**. Set the range and add it. Manual candidates are included by default and survive a later analysis batch.

![Dark export](../capture/screenshot-20260813-150335.png)

**Merge export** creates one timeline-ordered highlight. **Separate export** creates one file per candidate. Excluded candidates are not exported. After the job finishes, the result shows the path, clip count, duration, elapsed time, file size, codec, and **Open folder**.

Light-theme examples:

![Light project home](../capture/screenshot-20260813-150603.png)

![Light review empty state](../capture/screenshot-20260813-150911.png)

## 5. FAQ

- **Empty candidates:** check playback, model categories, ROI, range, video encoding, and Engine errors. Try a larger ROI and Standard mode on a short sample.
- **Long or noisy candidates:** candidates are event windows. Check the event time and adjust the start/end points in the review workspace.
- **Export locks review edits:** export takes a fresh database snapshot and temporarily locks the affected writes. Editing is available again after success or failure.
- **Source video moved:** use **Relink video**. The app checks metadata and a quick fingerprint rather than guessing a new path.
- **macOS SPM plugin warning:** it is a compatibility warning unless the build or playback actually fails. Upgrade the plugin when Flutter makes it a build error; do not remove the media plugin just to hide the warning.
- **Mobile runtime missing:** Android returns `NATIVE_RUNTIME_UNAVAILABLE` when the Rust/ONNX libraries are absent. UI and export may still work, but analysis is not faked.

## 6. Other development paths

Windows is a compatibility path:

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe scripts\check_runtime.py `
  --root . `
  --python .venv\Scripts\python.exe `
  --model models\bball_model.pt
cd apps\desktop
flutter pub get
flutter run -d windows
```

Mobile development uses the independent Flutter project:

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Android native analysis is mainly validated for `arm64-v8a`; iOS local analysis still needs the Rust static library, ONNX Runtime XCFramework, and Runner integration. The full commands are in [`DEVELOPMENT.en.md`](DEVELOPMENT.en.md).

For release, licensing, portable runtimes, and clean-machine checks, see [`RELEASE.en.md`](RELEASE.en.md). For implementation details, see [`ARCHITECTURE.en.md`](ARCHITECTURE.en.md).
