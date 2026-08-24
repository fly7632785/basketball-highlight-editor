# Python Engine

桌面端 Engine 是独立的 JSONL（JSON Lines）进程。Flutter 通过 stdin/stdout 调用它，不直接操作算法脚本、SQLite 或 FFmpeg。

## 启动

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

stdout 只输出协议消息，诊断信息写 stderr。

## 最小请求

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

## 当前命令

- `hello`
- `create_project`
- `inspect_video`
- `link_video`
- `save_roi`
- `start_analysis`
- `get_job`
- `get_active_jobs`
- `retry_analysis`
- `list_candidates`
- `create_manual_candidate`
- `review_candidate`
- `update_clip_range`
- `start_export`
- `retry_export`
- `list_exports`
- `get_statistics`
- `set_telemetry_consent`
- `cleanup_artifacts`

`start_analysis` 和 `start_export` 都进入统一异步任务生命周期，任务状态写入 SQLite；UI 通过 `get_job` 查询阶段、进度和错误。分析 manifest 保存阶段状态，重试时只重跑未完成或无效的阶段。

发布运行时必须携带 [`../../docs/architecture/SQLITE_SCHEMA_V1.sql`](../../docs/architecture/SQLITE_SCHEMA_V1.sql)。Engine 首次创建数据库时会读取该 schema，缺失会导致项目无法创建。
