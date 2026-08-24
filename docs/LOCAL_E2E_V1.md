# 本地桌面闭环验证 V1

## 验证环境

- 系统：macOS
- 输入：`data/videos/飞书20260804-170744.mp4`
- 视频：`960×720`、`30 FPS`、约 `277.67s`
- 模型：本地自备的 `models/bball_model.pt`；模型权重不随源码分发
- ROI：`x1=390, y1=180, x2=560, y2=390`
- 代理：`960×720`、`5 FPS`
- 精筛：`10 FPS` 参数传入 Engine

## 端到端结果

```text
create_project → link_video → extract_preview → save_roi
→ start_analysis → get_job 轮询 → list_candidates
→ review_candidate(goal) → export_clips(separate)
```

| 项目 | 结果 |
|---|---:|
| Engine 分析耗时 | 约 51.94 秒 |
| 任务状态 | `queued → running → completed` |
| 候选数量 | 3 |
| 候选时间 | 12.55s、176.70s、259.85s |
| 单独导出文件 | 3 个 MP4，均生成成功 |
| 预览帧 | JPG 生成成功，可被 Flutter `Image.file` 加载 |

## 结论边界

- 已证明本地 Engine、SQLite、代理、候选落库、人工审核、FFmpeg 导出可以串成闭环。
- 本次不是算法准确率验收；候选数量与历史人工标注存在差异，算法仍按“候选 + 人工审核”定位。
- 当前 Flutter 审核页已接入桌面内置播放器、时间轴、候选跳转和候选片段播放。
- 当前桌面运行依赖仓库内 `.venv`、`engine/python`、FFmpeg 和模型文件；正式分发前必须补齐运行时打包。
