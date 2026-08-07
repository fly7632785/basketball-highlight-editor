# Python Engine

V1 Engine 是独立的 JSON Lines 进程。Flutter 只通过 stdin/stdout 协议调用它，不直接操作算法脚本、SQLite 或 FFmpeg。

## 启动

```bash
cd /Users/macmima1234/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

## 最小请求

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

## 当前已实现

- `hello`
- `create_project`
- `inspect_video`
- `link_video`
- `save_roi`
- `start_analysis`（异步运行现有分析脚本）
- `create_analysis_job`（内部兼容命令）
- `get_job`
- `get_active_jobs`
- `retry_analysis`（对中断任务重试，并复用已完成阶段的产物）
- `list_candidates`
- `review_candidate`
- `update_clip_range`
- `get_statistics`
- `list_exports`
- `set_telemetry_consent`
- `cleanup_artifacts`

`create_proxy` 已通过现有 `scripts/create_proxy.py` 生成代理视频并写入任务记录。`start_analysis` 会异步调用现有代理、粗扫、候选生成和动态精筛脚本，完成后把候选写入 SQLite；UI 通过 `get_job` 查询进度和错误。每次分析会在 `artifacts/detections/<video_id>_<analysis_key>/manifest.json` 记录四个阶段的状态；重试时只重跑未完成或产物失效的阶段。
