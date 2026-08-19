# BHE Mobile Runtime V1

## Current boundary

`apps/mobile` is an independent Flutter application. It does not launch the
desktop Python Engine and does not depend on a desktop project. The Flutter
layer owns project state, local persistence, video playback, ROI editing and
the review workflow.

The mobile runtime is currently in staged integration:

- Flutter UI, project persistence and analysis progress recovery are ready.
- Android video frame extraction and the Rust/ONNX JNI seam are ready.
- The Android Rust/ONNX shared libraries are build inputs, not checked-in
  binaries.
- iOS analysis deliberately reports `NATIVE_RUNTIME_UNAVAILABLE` until the
  Rust static library and ONNX Runtime XCFramework are linked into Runner.

## Native seams

- `MobileAnalysisEngine`: ONNX/Rust inference and candidate generation.
- `MobileExportEngine`: native video clipping.
- Flutter channel `com.bhe.bhe/mobile_media`: platform media operations.

The default platform implementation returns an explicit unavailable error
when its native runtime is not packaged. It never generates empty or
fabricated candidates to hide a missing runtime.

## Model export

The desktop-validated checkpoint must be exported and compared before it is
bundled in the app:

```bash
.venv/bin/python scripts/export_mobile_model.py \
  --model models/bball_model.pt \
  --output models/bball_model.onnx
```

The repository contains the exported ONNX artifact. Python ONNX Runtime CPU
smoke testing passed; numerical parity against the desktop detector and
mobile ONNX Runtime/Rust packaging remain separate runtime tasks.

### Android native package

The supported local build entry point currently targets `arm64-v8a`:

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
scripts/build_mobile_runtime.sh
cd apps/mobile
flutter build apk --release
```

`BHE_ORT_ANDROID_DIR` must contain:

```text
arm64-v8a/libonnxruntime.so
```

The script checks Rust, the Android NDK and the Rust Android target before
building. It fails instead of producing a UI-only APK that appears to support
analysis but cannot run it. Additional ABIs should be added only after their
ONNX Runtime binaries and device performance are validated.

## Media behavior

- iOS uses `AVAssetExportSession` for MP4 clips.
- Android uses `MediaExtractor` and `MediaMuxer` for audio/video tracks.
- Project packages contain result metadata and never copy the original video.
- A missing source video must be relinked before analysis or clip export.
- Relinking checks duration, dimensions and a quick SHA-256 fingerprint made
  from the file head, tail and size, avoiding a full read of multi-gigabyte
  videos.
