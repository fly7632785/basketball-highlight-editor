# 跨端分析一致性契约 V1

> 状态：当前实现基准
> 生效日期：2026-08-27
> 基准端：桌面 Python Engine（`python-v2.14-white-net-trajectory`）

## 目标与边界

BHE 的桌面端和移动端必须以**同一份视频、ROI、分析范围和检测输入**产出可比较的候选结果。平台抽帧、模型执行和媒体 API 可以不同；候选事件、证据语义和判决规则不能各自演化。

当前 Rust Runtime 是“同模型、相近思路”的独立实现，**尚不是 Python Engine 的等价迁移**。在完成本文件第 5 节的回放验收前，客户端不得把两端的 `confidence`、`made` 或 `high_precision` 当成同一含义。

## 当前算法差异

| 环节 | 桌面 Python Engine | 移动 Rust Runtime | 一致性结论 |
| --- | --- | --- | --- |
| 输入链路 | 代理 → 粗扫 → 候选窗口精筛，可使用缓存 | 顺序抽帧 → 单次 ONNX 推理 | 不同；会改变检测帧和候选输入 |
| 轨迹关联 | 多轨关联、连续扁平轨迹、恢复轨迹；门限相对篮筐宽度 | 基础多轨动态关联；按预测距离一对一匹配，短断档和部分跨轨遮挡可拼接，最多保留 32 点 | **P0 不一致** |
| 穿框 | above/below 深度门槛、过渡点走廊、穿框后至少两个连续深度点、侧向离开校验 | 已对齐 above/below 深度、过渡走廊和穿框后连续点；输入来自基础多轨及短遮挡拼接 | **P1 不一致** |
| 轨迹预测 | 上方下降段，y(t) 加权二次拟合、x(t) 加权线性拟合、R²≥0.85；可作为遮挡时 review 证据 | 采用相近拟合；输入为归一化坐标，候选已经形成后计算 | **P1 不一致** |
| 篮网信号 | 背景、白网、橙色、下落方向、可用性和 baseline 等多类字段 | 三分区 8×8 灰度局部对比度帧差、同步运动抑制 | **P0 不一致** |
| 反弹/侧向离开 | 连续 post-track、深度边界、侧向离开和恢复例外 | 已对齐深度、侧向离开和恢复语义；仍缺多轨 recovery | **P1 不一致** |
| 判决 | persistence + complete_crossing + net_support + rebound/lateral exit；不满足时保留 ambiguous | 已按相同证据类别判定；补齐无网测量时的 geometry/score fallback，但输入轨迹仍未对齐 | **P1 不一致** |
| 自动导出门槛 | `calibrated_gates`，有 `high_precision` / `automatic_goal` | 已迁移核心 high-precision / automatic 规则；缺 Python 的 changed-ratio fallback | **P1 不一致** |
| 去重 | `dedupe_candidates(..., 2.0s)` | 候选事件相差 ≤2 秒去重 | **P1 不一致** |
| 结果证据 | 完整 `signals`、`gates`、`verification`、预测、overlay、reason/verdict | 基础轨迹、穿框点、分数、reason/verdict | **P1 不一致** |

## 统一数据语义

跨端比较时必须至少输出下列字段：

| 字段 | 语义 | 单位/约束 |
| --- | --- | --- |
| `algorithm_version` | 算法契约版本，不得只写语言或 Runtime 名称 | 例如 `analysis-contract-v1` |
| `event_ms` | 球穿过 `rim_y` 的插值时间 | 毫秒，源视频时间轴 |
| `trajectory` | 用于当前候选的有序球中心点 | 时间毫秒；坐标必须声明像素或 0..1 归一化 |
| `crossing` | 插值穿框点 | 与 ROI 使用相同坐标系 |
| `complete_crossing` | 是否有连续实测轨迹证明穿过筐口并进入篮网下方 | 布尔值；不可只由两点插值推断 |
| `net_signal_available` | 该候选是否取得了可用篮网测量 | 布尔值；不可用不等于“网未动” |
| `net_support` | 篮网证据是否满足当前契约的正向门槛 | 布尔值 |
| `rebound` | 球在近筐深度内回升的撞框反证据 | 布尔值 |
| `lateral_exit` | 穿框后在近筐范围横向离开的反证据 | 布尔值 |
| `verdict` | `made`、`missed`、`ambiguous` | 人工审核前的算法结论 |
| `auto_export_eligible` | 是否可默认纳入自动导出 | 必须与 `verdict=made` 分开表达 |

`confidence` 不是跨端契约字段。在两个评分函数统一前，只能在各自端内排序，不能跨端比较或按同一阈值过滤。

## 变更同步规则

任何影响下列内容的改动都必须同时检查 `src/basketball_highlight/` 和 `packages/bhe_runtime/src/lib.rs`：

- 轨迹关联、断档/速度门限、候选去重；
- 穿框、完整穿框、轨迹预测、篮网信号、反弹、侧向离开；
- 评分、`confidence`、`verdict`、自动导出门槛；
- Candidate/Evidence 字段或坐标单位。

每个此类 PR 必须：

1. 在 PR 描述写明 `Python` 和 `Rust` 各自是否修改；若只改一端，写明“不同步”的技术理由和恢复计划。
2. 同步更新本文件的“当前算法差异”表、`docs/MOBILE_PC_FEATURE_MATRIX.md` 和算法版本。
3. 对公共回放样本运行跨端回放；没有结果时不得声明结果一致。
4. 附上候选数、匹配数、时间偏差、verdict 差异和已知例外。

## 回放验收

使用同一份逐帧检测输入比较 Python 和 Rust，先隔离 PyTorch/ONNX 检测差异，再比较事件逻辑。

匹配规则：

- 同一事件：`abs(python.event_ms - rust.event_ms) <= 300ms`；
- 候选匹配后比较 `complete_crossing`、`net_signal_available`、`net_support`、`rebound`、`lateral_exit` 与 `verdict`；
- 5 分钟、30 分钟、1 小时标注样本均要报告匹配率、Precision（准确率）和 Recall（召回率）。

在跨端回放测试尚未落地前，验收状态只能是“接口字段可传递”，不是“算法等价”。

当前回放入口：

```bash
.venv/bin/python scripts/export_cross_platform_replay.py \
  --input /path/to/refined-records.json \
  --output /tmp/bhe-decision-replay.json

jq -c '.replays[]' /tmp/bhe-decision-replay.json | while IFS= read -r replay; do
  printf '%s' "$replay" | cargo run --features dynamic-onnx --manifest-path packages/bhe_runtime/Cargo.toml --bin bhe-runtime -- --decision-replay
done
```

输入 JSON 必须包含 `records`、`rim`、`frame_width` 与 `frame_height`。它用于隔离检测模型差异，先验证完整穿框、篮网证据、反弹、侧向离开和 verdict 的决策语义。

## 迁移顺序

1. 先统一 Candidate/Evidence/Verdict schema 和算法版本。
2. Rust 按 Python 语义补齐 recovery track、多轨关联、完整穿框、post-crossing persistence 与 lateral exit。
3. 统一篮网测量可用性、baseline 和 `net_support` 语义。
4. 统一 verdict 与自动导出 gate，再统一端内评分。
5. 把公共回放加入 CI；之后才允许独立调任一端的阈值。
