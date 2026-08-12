# Engine JSON Lines Protocol V1

## 1. 传输方式

- Flutter 启动 Engine 子进程；
- Flutter 写入 Engine `stdin`；
- Engine 通过 `stdout` 输出 JSON Lines；
- `stderr` 只用于诊断，不作为业务协议；
- 每行必须是一个完整 UTF-8 JSON 对象；
- 请求和事件使用 `request_id` 关联。

## 2. 基础格式

请求：

```json
{
  "protocol_version": "1.0",
  "type": "request",
  "request_id": "req-123",
  "command": "start_analysis",
  "payload": {}
}
```

响应：

```json
{
  "protocol_version": "1.0",
  "type": "response",
  "request_id": "req-123",
  "ok": true,
  "payload": {}
}
```

事件：

```json
{
  "protocol_version": "1.0",
  "type": "event",
  "request_id": "req-123",
  "event": "progress",
  "job_id": "job-123",
  "payload": {
    "stage": "refine_candidates",
    "progress": 0.42,
    "message": "正在精筛候选片段"
  }
}
```

## 3. V1 命令

| 命令 | 用途 |
|---|---|
| `hello` | 协商协议、Engine 版本和能力 |
| `create_project` | 创建项目数据库和目录 |
| `update_project_settings` | 持久化项目名称和主题模式 |
| `open_project` | 打开已存在的项目目录并返回项目、视频、ROI、统计上下文 |
| `delete_project` | 删除项目数据库、分析缓存和导出文件，不删除项目外的原始视频 |
| `list_recent_projects` | 只在调用方显式提供的目录下扫描一级子目录，列出最近修改的项目 |
| `inspect_video` | 读取视频元数据和磁盘需求 |
| `link_video` | 引用原始视频 |
| `relink_video` | 原始视频被移动后，更新已有视频的引用路径并重新读取元数据 |
| `extract_preview` | 从原始视频提取 ROI 页面预览帧 |
| `save_roi` | 保存篮筐区域和校准数据 |
| `start_analysis` | 异步启动代理、粗扫、候选生成和精筛任务 |
| `get_job` | 查询任务状态 |
| `get_active_jobs` | 查询未完成的分析任务及恢复状态，不启动任务 |
| `retry_analysis` | 结束已中断的分析任务并从头重新开始，不覆盖原始视频 |
| `cancel_job` | 请求取消任务 |
| `list_candidates` | 按事件时间查询候选、保留/排除语义和审核用代理视频路径 |
| `start_review` | 记录开始审核某个候选的时间 |
| `review_candidate` | 写入确认 / 排除 / 暂缓状态、原因和备注，并结算审核耗时 |
| `list_review_history` | 查询候选的审核操作历史 |
| `update_clip_range` | 修改片段起止时间 |
| `start_export` | 异步导出所有未排除的候选，返回可由 `get_job` 查询的任务 |
| `retry_export` | 使用上次导出参数重新启动失败或取消的导出任务 |
| `list_exports` | 查询项目最近的导出记录和耗时统计 |
| `cleanup_artifacts` | 清理可重建中间文件 |
| `get_statistics` | 查询项目和导出统计 |
| `set_telemetry_consent` | 保存用户授权状态 |

## 4. 事件类型

```text
job_started
progress
candidate_created
artifact_created
log
job_completed
job_cancelled
job_failed
```

## 5. 错误码

```text
INVALID_REQUEST
UNSUPPORTED_PROTOCOL
PROJECT_NOT_FOUND
PROJECT_INVALID
VIDEO_NOT_FOUND
VIDEO_OPEN_FAILED
VIDEO_FORMAT_UNSUPPORTED
ROI_INVALID
DISK_SPACE_LOW
MODEL_LOAD_FAILED
ANALYSIS_FAILED
EXPORT_FAILED
JOB_NOT_FOUND
JOB_ALREADY_RUNNING
JOB_CANCELLED
```

### `get_active_jobs`

请求 payload：

```json
{
  "project_root": "/path/to/project",
  "video_id": "video_xxx",
  "job_type": "analysis"
}
```

`video_id` 可选；省略时返回该项目全部 `analysis` 类型且状态为 `queued` 或 `running` 的任务。

成功响应 payload：

```json
{
  "count": 1,
  "jobs": [
    {
      "id": "job_xxx",
      "type": "analysis",
      "state": "running",
      "stage": "coarse_scan",
      "progress": 0.42,
      "checkpoint_json": "{\"frame\":123}",
      "checkpoint": {
        "frame": 123
      },
      "runtime_state": "stale",
      "recovery_state": "stale_recoverable",
      "recoverable": true
    }
  ]
}
```

字段语义：

- `checkpoint` 是 `checkpoint_json` 的解析结果；`progress` 为最近一次持久化进度，范围为 `0.0` 到 `1.0`。
- `runtime_state=running` 且 `recovery_state=worker_attached` 表示当前 Engine 进程仍持有该任务线程，不能再次启动。
- `state=queued` 且 `recovery_state=queued_recoverable` 表示任务已入库但尚未绑定运行线程，可进入后续恢复流程。
- `state=running` 但 `runtime_state=stale` 且 `recovery_state=stale_recoverable` 表示数据库记录显示曾运行，但当前 Engine 进程没有对应线程，通常是 Engine 进程退出或崩溃造成；接口不会把它伪装成仍在运行，也不会自动启动新任务。
- `recoverable` 只表示该记录可以进入后续恢复流程，不代表本命令已经恢复或重跑任务。
- `job_type` 默认是 `analysis`，也可传 `export` 查询未完成导出任务。

限制：V1 只提供发现和状态标记，不提供断点续跑或 `recover_job`。当前 checkpoint 是阶段级元数据，不保证算法脚本能从任意帧继续；恢复实现必须先检查已有代理、检测和候选产物，避免重复写入或覆盖人工审核结果。跨多个 Engine 进程操作同一项目仍不受支持。

`retry_analysis` 是“从头重跑”而非断点续跑：仅接受当前 Engine 未持有线程的 `queued/running` 任务，先将旧任务标记为 `cancelled`，再创建新的分析任务。它不会删除原始视频、项目数据库或用户明确保留的导出文件；候选重建仍应在审核前执行。

## 6. 兼容规则

- 新字段默认可选；
- 不删除已发布字段；
- 新命令通过 `capabilities` 协商；
- Engine 不认识的命令必须返回 `INVALID_REQUEST`；
- Flutter 不认识的事件必须记录日志并忽略，不得崩溃；
- 协议测试使用固定 JSON fixtures。

### `open_project`

请求 payload：

```json
{
  "project_root": "/path/to/project"
}
```

成功响应 payload：

```json
{
  "database_path": "/path/to/project/project.db",
  "project_root": "/path/to/project",
  "project": {},
  "video": {},
  "roi": {},
  "statistics": {}
}
```

该命令只打开包含有效 `project.db` 和项目记录的目录，不会为不存在或无效的目录创建数据库或目录。

### `delete_project`

请求 payload：

```json
{
  "project_root": "/path/to/project"
}
```

成功响应 payload：

```json
{
  "deleted": true,
  "project_root": "/path/to/project",
  "project_id": "project-123"
}
```

该命令只允许删除包含有效 `project.db` 的项目目录；如果项目仍有任务进程运行，返回 `PROJECT_BUSY`，调用方应先取消任务。原始视频通常位于项目目录之外，不会被删除。

### `list_candidates`

成功响应除 `candidates` 外，可返回最近一次完整分析生成且仍存在的审核代理视频：

```json
{
  "candidates": [],
  "review_video_path": "/path/to/project/artifacts/proxies/video_key.mp4"
}
```

`review_video_path` 仅用于审核播放；原始视频路径仍由 `videos.source_path` 保存并只用于精确导出。代理不存在时该字段为 `null`，调用方应回退到原始视频或提示重新生成分析。

每个候选都返回 `selection_status`：`included` 表示默认保留，`excluded` 表示用户已打叉剔除。
旧版 `review_status` 仍保留用于兼容历史项目；导出以 `selection_status` 为准，未排除候选都会进入输出。

审核接口约定：调用方进入候选时可发送 `start_review`，payload 为
`{ "project_root": "...", "candidate_id": "...", "review_started_at": "<ISO-8601 可选>" }`。
提交时发送 `review_candidate`，除 `candidate_id`、`status` 外可带 `reason`、`note` 和
`review_started_at`；Engine 会把 `review_started_at`、`reviewed_at` 和非负的
`review_duration_ms` 写入候选审核记录。旧客户端不调用 `start_review` 时，提交动作仍然有效，
审核耗时按 0 记录。`list_review_history` 返回每次审核动作及其状态、原因、备注、时间和耗时。

`get_statistics` 的 `statistics` 对象包含候选数、待审核数、已审核数、确认数、排除数、
`confirmation_rate`、`avg_review_duration_ms`、`reason_distribution` 和
`conflict_count`；统计字段缺失时客户端应按 0 或空集合降级。

`inspect_video` 还返回 `available_disk_bytes`、`estimated_processing_space_bytes` 和 `disk_space_sufficient`，用于导入页提前提示长视频处理所需空间。分析和导出启动前会再次按项目工作目录执行预检，失败返回 `DISK_SPACE_LOW`。

`open_project` 和 `list_recent_projects` 返回的视频对象还包含 `source_exists` 和 `source_status`。当原始视频被移动后，调用方应显示重新定位入口；`relink_video` 只更新视频引用和重新读取的媒体元数据，不删除候选、审核记录或项目数据库。

### `list_recent_projects`

请求 payload：

```json
{
  "roots": ["/path/to/known/projects"],
  "limit": 20
}
```

成功响应 payload：

```json
{
  "projects": [],
  "scanned_roots": ["/path/to/known/projects"]
}
```

安全边界：`roots` 必须由调用方显式提供；Engine 只检查每个 root 自身及其一级子目录中的 `project.db`，不递归扫描用户目录，也不跟随一级子目录中的符号链接。结果按项目数据库最近修改时间倒序排列。

当前已可运行的最小闭环命令：`hello`、`create_project`、`update_project_settings`、`open_project`、`delete_project`、`list_recent_projects`、`inspect_video`、`link_video`、`relink_video`、`extract_preview`、`save_roi`、`start_analysis`、`retry_analysis`、`cancel_job`、`get_job`、`get_active_jobs`、`list_candidates`、`start_review`、`review_candidate`、`list_review_history`、`update_clip_range`、`start_export`、`retry_export`、`get_statistics`、`set_telemetry_consent`、`cleanup_artifacts`。
