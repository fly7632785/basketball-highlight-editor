# 进球判定 v3

Python 分析引擎的篮筐精检规则版本为 `rim-dense-v3`。它沿用现有球/筐模型、局部篮筐 crop 和桌面适配器的最终策略，改进“进球 / 未进 / 不确定”的自动建议，不将机器建议写成人工真值。

## 行为变化

- 合并同帧重叠的球检测框，减少同一物理球被拆成多个轨迹片段。
- 联合判断穿越速度、有限球体与筐口的覆盖、篮网响应；弱网运动本身不足以否定进球。
- 在较长运动基线之外增加紧邻过筐的局部基线，避免先前碰筐干扰真正进网时的响应。
- 网前连续强检测停留需结合局部响应和入筐证据，阻止把接球/托球片段续成进球；普通网内减速继续保留。
- 当来球、球体入筐比例和两种网响应共同支持捕获时，允许被篮网拉偏后的侧向出网。
- 保留 `unknown/unsure/skipped`。候选关联仅作审核提示，所有锚点保留；有独立中央入筐证据的补篮不因粗扫区间重叠就被提示为上一球重复。

新证据字段包括 `passage_speed_ratio`、`opening_clearance`、`opening_overlap`、`net_response_ratio`、`net_local_response_ratio`、`net_hold_frames` 和可选 `net_lateral_capture`。现有最终状态语义保持兼容，缓存版本按 v3 标识。

## 固定候选评估

`scripts/evaluate_outcomes.py` 复用真实桌面适配器，并可从冻结源码树加载基线和当前规则。按 `candidate_id` 与精确毫秒锚点匹配，`event_time_ms` 优先于四舍五入的 `time`。全部候选参与视频策略校准；只有明确人工结果进入评分，非投篮单列，不把旧的含混否定标签当作 missed。

基线必须是 `rim-dense-v2`。`--baseline-root` 可以指向该版本的 checkout 或保留所需路径布局的源码快照；不能传入当前 v3 假装 v2。若适配器含包内相对导入，加载器使用引擎包上下文解析。

```sh
rtk proxy env PYTHONDONTWRITEBYTECODE=1 .venv/bin/python scripts/evaluate_outcomes.py --candidates .cache/outcome-review/candidates.json --evidence .cache/outcome-review/rim-check-dense.json --labels .cache/outcome-review/labels.json --anchors .cache/outcome-review/predictions.json --baseline-root .cache/outcome-v2 --current-root . --allow-non-shots --evaluation-role regression --output .cache/outcome-review/replay-new
```

输出目录必须是新目录。`--allow-unlabeled` 可保留没有明确真值的候选参与校准，但不会把这些候选加入正确数或转成 missed。`--bundle` 用于校验既有不可变审核包；私有审核包不随仓库发布，`local-review-data/` 和 `.cache/` 均应保持 Git 忽略。

## 本地人工审核回归

六段视频的 251 个固定锚点重新解码并运行原帧率球/筐精检。244 条有人工记录，其中 222 条明确投篮、17 条明确非投篮、5 条旧否定类型未细分；另 7 条未审核记录仅用于校准。两个版本使用相同的新检测证据和固定候选。

| 指标 | v2 | v3 |
|---|---:|---:|
| 明确判断准确率 | 172/195 = 88.21% | 198/200 = 99.00% |
| 明确判断覆盖率 | 195/222 = 87.84% | 200/222 = 90.09% |
| 正确且明确 / 全部投篮 | 172/222 = 77.48% | 198/222 = 89.19% |
| 自动 made precision，含明确非投篮 | 100/121 = 82.64% | 106/106 = 100% |
| missed precision，仅真实投篮 | 72/75 = 96.00% | 92/94 = 97.87% |
| 未进误判进球 | 20 | 0 |
| 进球误判未进 | 3 | 2 |
| 投篮不确定 | 27 | 22 |

相对 v2 的旧正确判断没有退步。剩余两条共同错误与 22 条不确定保留在统计中。第一节历史审核以进球正样本为主；第二节包含 31 条结构化审核和 3 条早期人工确认进球，其 4 条旧否定仍未强行归为 missed。

这些数据参与了规则开发，以上是开发/回归成绩，不是新的独立泛化结果，也不是全场命中率或完整投篮召回。候选单位是锚点，物理投篮去重没有据标签自动合并。视频、权重、原始检测、逐条标签和私有审核包均不随提交发布。

## 运行与验证边界

实测沿用原有本地球模型与 Apple MPS：640 输入、conf 0.05、IoU 0.7、rect=False、batch 16、原帧率、候选前后各 1 秒、约 5 倍筐宽局部 crop。六段新精检合计约 284 秒；没有新增模型或下载权重。

本次修改覆盖 Python 判定及其桌面适配路径。Rust/native 判定实现尚未同步这套规则；ONNX、CoreML 与移动端没有在本轮做完整视频等价性验收。模型的已知检测遗漏、网前遮挡和短窗口证据不足仍可能产生错误或不确定，自动建议仍供人工审核。

仓库内测试为可分发的合成行为测试；六段私有数据的全量回归另行执行，不让公开 CI 依赖私有视频、标注或射手开发脚本。

独立发布分支基于最新上游 main，完整 Python 测试为 **708 passed**（68.72 秒）；相关判定、桌面适配、候选关联与评估工具测试 85 项全部通过。正式 v3 在六段冻结证据上的 239 条明确人工记录逐条评分与已验证算法一致。
