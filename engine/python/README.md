# Python Engine

V1 Engine 是独立的 JSON Lines 进程。Flutter 只通过 stdin/stdout 协议调用它，不直接操作算法脚本、SQLite 或 FFmpeg。

## 启动

```bash
cd /path/to/basketball-highlight-editor
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

`start_analysis` 会在统一异步任务中调用 `scripts/create_proxy.py`、粗扫、候选生成和动态精筛脚本，完成后把候选写入 SQLite；UI 通过 `get_job` 查询进度和错误。每次分析会在 `artifacts/detections/<video_id>_<analysis_key>/manifest.json` 记录四个阶段的状态；重试时只重跑未完成或产物失效的阶段。代理生成和导出不再提供绕过任务生命周期的同步协议入口。

发布运行时必须同时携带 `docs/architecture/SQLITE_SCHEMA_V1.sql`。Engine 首次初始化项目数据库时会从运行时根目录读取该文件；缺失会导致项目无法创建。
