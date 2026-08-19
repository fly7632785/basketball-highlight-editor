# BHE Mobile Runtime V1

## Current boundary

`apps/mobile` is an independent Flutter application. It does not launch the
desktop Python Engine and does not depend on a desktop project. The Flutter
layer owns project state, local persistence, video playback, ROI editing and
the review workflow.

## Native seams

- `MobileAnalysisEngine`: ONNX/Rust inference and candidate generation.
- `MobileExportEngine`: native video clipping.
- Flutter channel `com.bhe.bhe/mobile_media`: platform media operations.

The default analysis implementation intentionally returns an explicit
unavailable error until the ONNX model and Rust runtime are shipped. This is
safer than generating empty or fabricated candidates.

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

## Media behavior

- iOS uses `AVAssetExportSession` for MP4 clips.
- Android uses `MediaExtractor` and `MediaMuxer` for audio/video tracks.
- Project packages contain result metadata and never copy the original video.
- A missing source video must be relinked before analysis or clip export.
- Relinking checks duration, dimensions and a quick SHA-256 fingerprint made
  from the file head, tail and size, avoiding a full read of multi-gigabyte
  videos.
