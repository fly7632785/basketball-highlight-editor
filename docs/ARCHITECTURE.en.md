# Architecture, Protocol, and Runtime

[中文](ARCHITECTURE.md) · **English**

This document is the implementation reference for the desktop app, the local Engine protocol, the mobile runtime, and project storage. Product scope is in [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md); development commands are in [`DEVELOPMENT.en.md`](DEVELOPMENT.en.md).

## 1. System boundary

```text
Flutter UI → JSON Lines → Python Engine → SQLite + artifacts
                                      ↘ Python analysis / OpenCV / YOLO / FFmpeg
```

The desktop app runs locally. Flutter owns page state and user interaction; the Engine owns analysis, persistence, artifacts, and export. The UI does not call FFmpeg, read detection JSON, or write SQLite directly. The original video remains the export source; proxy video is an analysis/review artifact.

The V1 desktop stack is Flutter + Python + SQLite + FFmpeg. Rust + ONNX Runtime is the mobile inference path. A future desktop Rust implementation must keep the protocol and database contracts stable.

## 2. Desktop modules

| Layer | Responsibility |
|---|---|
| `apps/desktop/` | Flutter UI, Riverpod state, go_router navigation, Material 3 theme, media playback |
| `engine/python/` | JSONL server, job state, persistence, artifact management, export |
| `engine/python/adapters/` | Adapter around the existing analysis scripts |
| `engine/python/storage/` | SQLite repositories and migrations |
| `src/` and `scripts/` | Analysis and runtime utilities |

A heavy analysis or export task runs one at a time per project. Jobs move through `queued → running → completed`, or to `cancelled`/`failed`. Stages include input validation, proxy preparation, coarse scan, candidate refinement, persistence, export, and cleanup. Progress and checkpoints are persisted so a new Engine process can identify stale jobs without pretending they are still running.

## 3. JSON Lines protocol

Flutter starts the Engine as a child process. Each stdin/stdout line is one UTF-8 JSON object. stdout contains business messages only; stderr is for diagnostics. Requests, responses, and progress events share a `request_id`.

Request:

```json
{"protocol_version":"1.0","type":"request","request_id":"req-123","command":"hello","payload":{}}
```

Response:

```json
{"protocol_version":"1.0","type":"response","request_id":"req-123","ok":true,"payload":{}}
```

Progress event:

```json
{"protocol_version":"1.0","type":"event","request_id":"req-123","event":"progress","job_id":"job-123","payload":{"stage":"refine_candidates","progress":0.42}}
```

V1 commands include `hello`, project open/create/delete, video inspect/link/relink, preview extraction, ROI save, analysis start/retry/cancel, job queries, candidate list/manual creation, review history, clip-range update, export/retry, statistics, telemetry consent, and artifact cleanup. Events include `job_started`, `progress`, `candidate_created`, `artifact_created`, `log`, `job_completed`, `job_cancelled`, and `job_failed`.

Important semantics:

- `selection_status= included` is the default; `excluded` candidates are the only candidates omitted from export. The legacy `review_status` remains for compatibility.
- `list_candidates` may return a review proxy. Final export still uses the source video.
- `create_manual_candidate` uses `detector_version=manual-v1` and manual evidence, and manual candidates survive a later analysis batch.
- `start_review` and `review_candidate` can record review start, completion, reason, note, and duration.
- `get_active_jobs` reports stale jobs but does not silently resume them. `retry_analysis` starts a fresh run.
- `open_project` only opens a valid existing `project.db`. `list_recent_projects` scans only explicitly provided roots and their first-level children.
- Disk checks run before analysis and export and return `DISK_SPACE_LOW` when needed.

Error codes include `INVALID_REQUEST`, `UNSUPPORTED_PROTOCOL`, `PROJECT_NOT_FOUND`, `PROJECT_INVALID`, `VIDEO_NOT_FOUND`, `VIDEO_OPEN_FAILED`, `VIDEO_FORMAT_UNSUPPORTED`, `ROI_INVALID`, `DISK_SPACE_LOW`, `MODEL_LOAD_FAILED`, `ANALYSIS_FAILED`, `EXPORT_FAILED`, `JOB_NOT_FOUND`, `JOB_ALREADY_RUNNING`, and `JOB_CANCELLED`.

Compatibility rules: new fields are optional, released fields are not removed, capabilities negotiate new commands, unknown events are logged and ignored by Flutter, and protocol tests use fixed JSON fixtures.

The complete request/response examples remain in the source history; when changing a command, update the implementation, protocol tests, and [`SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql) together.

## 4. Storage and project layout

Each user project contains:

```text
<project-root>/
├── project.db
├── artifacts/       # proxies, detections, review clips, exports
├── logs/
├── telemetry_outbox/
└── README.txt
```

The database stores project settings, the source path, media metadata, normalized ROI coordinates, candidates, review state, labels, jobs, and export records. The source video is not copied. If it moves, the UI asks the user to relink it and verifies metadata plus a quick fingerprint.

Proxy videos, detection caches, and failed-job temporary files are rebuildable. Do not automatically delete the source video, `project.db`, review history, or exports the user chose to keep.

## 5. Mobile runtime

`apps/mobile` is a separate Flutter app. It does not start the desktop Python Engine. Flutter handles project state, packages, playback, ROI editing, and review; platform code handles media; Rust/ONNX Runtime handles inference.

- `MobileAnalysisEngine` abstracts inference and candidate generation.
- `NativeAnalysisEngine` bridges Flutter and platform analysis channels.
- `MobileExportEngine` handles mobile clip export.
- `packages/bhe_runtime/include/bhe_runtime.h` defines the Rust C ABI.
- Android is primarily validated for `arm64-v8a` and needs `libbhe_runtime.so` plus `libonnxruntime.so`.
- iOS playback, review, and export channels are available; local analysis still needs the Rust static library, ONNX Runtime XCFramework, and Runner integration.
- Missing native libraries return `NATIVE_RUNTIME_UNAVAILABLE`; the app does not fabricate candidates.

Desktop model conversion entry point:

```bash
.venv/bin/python scripts/export_mobile_model.py \
  --model models/bball_model.pt \
  --output models/bball_model.onnx
```

Validate model output, input normalization, class mapping, memory, thermal behavior, cancellation, and long-video performance separately on each platform.

## 6. Responsive UI and design rules

On wide desktop windows, keep the video workspace dominant and place the candidate list beside it. On smaller windows the candidate list can collapse into a side panel. The mobile app uses its own layout contract.

The desktop theme uses Material 3 and supports system, light, and dark modes. The dark review workspace is the primary presentation. State colors are paired with text or icons, focus states remain visible, animations default to 150–300 ms, and reduced motion is supported.
