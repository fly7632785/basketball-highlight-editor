# Frequently Asked Questions

[中文](FAQ.md) · **English**

## Runtime and environment

### Q1: The app cannot find Python or the Engine. What should I do?

Run this from the repository root:

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

You can set the development paths explicitly:

```bash
BHE_REPO_ROOT="/path/to/basketball-highlight-editor" \
BHE_PYTHON="/path/to/basketball-highlight-editor/.venv/bin/python" \
flutter run -d macos
```

A packaged `.app` should put the Engine and Python under `Contents/Resources/runtime`; it must not depend on developer-specific absolute paths. See [`GETTING_STARTED.en.md`](GETTING_STARTED.en.md).

### Q2: What does the macOS warning about `media_kit_libs_macos_video`, `media_kit_video`, and Swift Package Manager mean?

It is a compatibility warning about the macOS plugin integration path, not automatically an application failure. If video playback, `flutter build macos`, and Xcode builds work, record the warning and continue development.

Act when a future Flutter release turns it into a build error, the project moves to Swift Package Manager, or an actual Flutter/Xcode build fails. Prefer a plugin version with SPM support, then rerun `flutter pub get`, `flutter analyze`, `flutter test`, and the macOS build. Do not remove the video plugin just to silence the warning.

### Q3: Isn't the model bundled? Why does the runtime check say that it is missing?

Yes. The complete source repository currently bundles the default detector at:

```text
models/bball_model.pt
```

The error usually means you are using a release/source package without large assets, or the file was removed locally. You can also pass a custom model path:

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model /absolute/path/to/your-model.pt
```

The model must match the classes and format expected by the current scripts, and you must have the right to use it. The Engine does not download unknown weights automatically.

### Q4: Why are FFmpeg and FFprobe required?

FFprobe reads video metadata. FFmpeg creates analysis proxies, previews, and final exports. Check them with:

```bash
command -v ffmpeg
command -v ffprobe
ffmpeg -version
ffprobe -version
```

Homebrew is fine for development; a distributable package needs a self-contained or static build and a license review. See [`RELEASE.en.md`](RELEASE.en.md).

### Q5: Is a media-plugin initialization message in Flutter tests a failure?

Not necessarily. Use the exit code, `flutter analyze`, and test assertions as the source of truth. Investigate further if the command exits non-zero or reports an actual build error.

## Analysis and candidates

### Q6: Analysis completed, but the candidate list is empty. Is that expected?

An empty list is not necessarily a UI bug. Check, in order:

1. whether the source video plays correctly;
2. whether the model exposes the basketball/hoop classes expected by the pipeline;
3. whether the ROI covers the hoop and ball movement area;
4. whether the analysis range is accidentally too short;
5. whether the video codec or model is incompatible;
6. whether the Engine reported `NO_BALL_DETECTIONS`, `MODEL_LOAD_FAILED`, or `ANALYSIS_FAILED`.

Try a larger ROI, a short sample, and Standard mode. If Fast mode has no candidates, do not silently treat it as a complete result; rerun Standard.

### Q7: There are too many candidates, or one candidate lasts for minutes. What should I do?

A candidate is an event window, not a final edited clip. Confirm the event time and adjust the start/end range in the review workspace. An oversized ROI, timestamp anomalies, or false detections from player/hoop motion can all create noisy or long windows.

Do not edit JSON or SQLite directly; use the UI so review and export state remain consistent.

### Q8: What is the difference between Fast and Standard?

Standard performs source-video refinement and favors quality. Fast uses a lower-cost proxy, skips refinement, and favors speed, so it may miss events. Review, manual range, and export semantics are the same. See [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md).

### Q9: Can I export or change modes while analysis is running?

A project runs only one heavy analysis or export job at a time. You can inspect and review the previous candidates while a new analysis runs, but export is locked. Cancel the current analysis before switching modes; the previous candidates are not cleared until the new result succeeds.

### Q10: Why can I not edit the review area after starting export?

Export rereads the current database state and locks candidate writes that would make the export differ from what the UI shows. You can continue editing after export completes or fails and start another export.

## Video, projects, and data

### Q11: What if the source video was moved or deleted?

The project stores the source path and metadata rather than copying the source video. Use “Relink video” after a move. If duration, dimensions, or the fingerprint do not match, recalibrate the ROI and rerun analysis.

### Q12: What can I clean from a project directory?

Proxies, detection caches, and failed-job temporary files are usually rebuildable. Do not automatically delete the source video, `project.db`, review records, or exports the user wants to keep. See [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md).

### Q13: Why should models, videos, and development screenshots stay out of GitHub?

They can contain unverified copyright, player information, real paths, or large binary artifacts. A public repository should keep only source, documentation, and demonstrably publishable demo assets. See [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md).

### Q14: Does reviewed-data export upload anything?

No. `scripts/export_review_dataset.py` reads the project database locally and writes JSONL/CSV. The output may contain real paths, notes, or player labels; do not commit it.

## Mobile

### Q15: Why does mobile not launch the desktop Python Engine?

This is intentional: desktop reuses the Python Engine for the long-video pipeline, while mobile uses Flutter state, platform media APIs, and Rust/ONNX Runtime instead of requiring a desktop Python environment. Project and candidate models are shared through `packages/bhe_core`.

### Q16: Android analysis returns `NATIVE_RUNTIME_UNAVAILABLE`. What should I check?

Confirm that the APK contains the current ABI's `libbhe_runtime.so` and `libonnxruntime.so`, then rebuild according to [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md). Without these native libraries, UI and export can work, but analysis must fail explicitly rather than fabricate candidates.

### Q17: Why can iOS play and export but not analyze?

iOS project, media, and export channels are wired. Local analysis still requires the Rust static library, an ONNX Runtime XCFramework, and Runner linker configuration. Without those artifacts, keep the explicit unavailable state and do not describe the build as a full AI-analysis release.

## Build and release

### Q18: Does a successful `flutter build macos` mean that I can distribute the app?

No. You still need portable Python and dependencies, FFmpeg/FFprobe, a model with verified rights, dependency notices, signing, notarization, and clean-machine validation. See [`RELEASE.en.md`](RELEASE.en.md).

### Q19: Why not replace the entire desktop Python Engine with Rust now?

The main costs are model inference, video decoding, and FFmpeg, not the JSONL service itself. Stabilize the desktop protocol, SQLite, and review semantics first, then replace internals incrementally. Mobile already has a separate Rust/ONNX path; moving desktop code to Rust would not automatically solve every performance issue.

### Q20: How do I report a security issue?

Do not publish exploit details, video samples, secrets, or personal data in a public issue. Read the root [`SECURITY.md`](../SECURITY.md) and use GitHub private vulnerability reporting if enabled, or the repository's published security contact.
