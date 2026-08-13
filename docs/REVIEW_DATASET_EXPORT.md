# 人工审核训练数据导出

`scripts/export_review_dataset.py` 从项目根目录的 `project.db` 导出人工审核结果，保留模型预标注证据，并将人工审核字段单独写出。

## 使用

默认只导出 `goal`、`excluded`、`deferred`、`second_review`：

```bash
python scripts/export_review_dataset.py /path/to/project
```

指定输出目录、包含待审核候选并同时生成 CSV：

```bash
python scripts/export_review_dataset.py /path/to/project \
  --output-dir /path/to/export \
  --include-pending \
  --csv
```

默认输出到 `project_root/artifacts/exports`。文件名带 UTC 时间戳；如果目标文件已存在，工具会拒绝覆盖。

## 字段

每行 JSONL 对应一个候选，字段顺序固定：

`candidate_id`、`video_id`、`event_time_ms`、`review_start_ms`、`review_end_ms`、`model_score`、`model_confidence`、`detector_version`、`review_status`、`review_reason`、`review_note`、`reviewed_at`、`evidence_json`、`evidence_parse_error`。

- `model_score`、`model_confidence`、`detector_version`、`evidence_json` 是模型侧预标注数据。
- `review_status`、`review_reason`、`review_note`、`reviewed_at` 是人工审核数据。
- 合法 JSON 的 `evidence_json` 输出为 JSON 值；解析失败时保留数据库原字符串，并在 `evidence_parse_error` 写入错误信息。
- CSV 中的 `evidence_json` 始终写成 JSON 文本，便于其他训练工具读取。

验证：

```bash
./.venv/bin/pytest -q tests/test_export_review_dataset.py
```
