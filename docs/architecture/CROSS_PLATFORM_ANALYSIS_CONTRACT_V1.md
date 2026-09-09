# 跨端分析一致性契约 V1

> 状态：当前实现基准
> 生效日期：2026-08-28
> 基准端：桌面 Python Engine（`python-v2.14-white-net-trajectory`）

## 目标与边界

BHE 的桌面端和移动端必须以**同一份视频、ROI、分析范围和检测输入**产出可比较的候选结果。平台抽帧、模型执行和媒体 API 可以不同；候选事件、证据语义和判决规则不能各自演化。

当前 Rust Runtime 已按本文件统一采样、ROI、轨迹、穿框、篮网信号和判定契约；**真实视频全链路仍需按第 5 节验收**。在完成 PT/ONNX 同帧对比和 5 分钟、30 分钟、1 小时回放前，不能把“编译通过”当成两端结果完全相同。

## 当前算法差异

| 环节 | 桌面 Python Engine | 移动 Rust Runtime | 一致性结论 |
| --- | --- | --- | --- |
| 输入链路 | 代理 → 粗扫 → 候选窗口精筛，可使用缓存；精筛 ROI 按生产参数 `refine_scale=2` 放大，再以 640 输入 | 顺序抽帧；分析 ROI 按 `crop_scale=2` 放大，再以 640 输入；Android Bitmap 使用 stride 直传 Rust | 模型输入裁剪倍率、默认精筛采样率已固定；粗扫/窗口调度仍不同；Android 输入复制已减少 |
| 自动 ROI | 当前分析起点开始扫描最多 `20s`，`1fps`，最多 `12` 帧；全画面、`conf=0.05`、稳定篮筐聚类与 rim-plane 校准 | 当前分析起点开始扫描最多 `20s`，`1fps`，最多 `12` 帧；全画面、`conf=0.05`、相同稳定聚类、ROI 扩展和 rim-plane 校准 | **采样窗口、ROI 扩展与 rim ROI 公式已对齐；PT/ONNX 检测结果仍需实测对比** |
| 轨迹关联 | 多轨关联、连续扁平轨迹、恢复轨迹；门限相对篮筐宽度 | 多轨一对一预测关联；关联门限包含上一球框尺寸；保留原始检测用于遮挡恢复 | **决策语义已对齐；检测采样仍不同** |
| 穿框 | above/below 深度门槛、过渡点走廊、穿框后至少两个连续深度点、侧向离开校验 | 已对齐 above/below、相邻上升段排除、中间偏离、过渡走廊、穿框后连续点和侧向离开校验 | **决策语义已对齐** |
| 轨迹预测 | 上方下降段，y(t) 加权二次拟合、x(t) 加权线性拟合、R²≥0.85；可作为遮挡时 review 证据 | 同一上方下降段和前向窗口，使用归一化坐标实现等价拟合 | **候选证据语义已对齐；检测采样仍不同** |
| 篮网信号 | 三分区滚动背景、中值背景、灰度变化、白网/橙色变化和可用性 | 同一三分区滚动背景、中值背景、灰度变化、白网/橙色变化和可用性；两端均不再使用仅桌面可用的 Farneback 光流 | **信号定义已统一；像素解码差异仍可能造成边界值差异** |
| 反弹/侧向离开 | 连续 post-track、深度边界、侧向离开和恢复例外 | 已对齐深度、侧向离开和恢复语义及多轨 recovery | **规则已对齐** |
| 判决 | persistence + complete_crossing + net_support + rebound/lateral exit；不满足时保留 ambiguous | 已按相同证据类别判定；源视频时间推进到验证窗口后再落 verdict | **决策语义已对齐** |
| 自动导出门槛 | `calibrated_gates`，有 `high_precision` / `automatic_goal` | 已迁移 `high_precision` / `automatic_goal` 规则及 changed-ratio fallback | **规则已对齐；网动原始测量仍不同** |
| 去重 | `dedupe_candidates(..., 2.0s)` | 事件时间 2 秒内去重，并按 verdict、完整穿框、预测 review、分数选择胜者 | **规则已对齐；来源字段在移动端固定为本地 Runtime** |
| 结果证据 | 完整 `signals`、`gates`、`verification`、预测、overlay、reason/verdict | 已输出 `signals`、`gates`、`verification`、预测和轨迹尺寸字段 | **字段语义已对齐** |

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
| `measurement_valid` | replay 中该时间点的篮网测量是否有效 | 布尔值；缺失/无效测量必须从篮网时序统计中排除 |
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

回放默认是**原始信号回放**：只传轨迹、候选实际使用的 rim ROI、时间戳和逐帧三分区信号，由 Rust 重新计算派生字段。`measurement_valid=false` 的时间点只保留用于追溯，不参与篮网 baseline/active 统计；它不等于“篮网没有运动”。导出器优先使用候选 overlay 中的实际 rim，避免用全局 rim 替代局部校准结果。`--locked-decision` 仅用于旧版 verdict 回归，不可用于证明算法一致。脚本必须在配置了 ONNX Runtime 的目标环境执行 Rust 二进制；本机若缺少 `ORT_LIB_PATH` 只能完成编译检查，不能把编译通过当成算法等价。

当前回放入口：

```bash
.venv/bin/python scripts/export_cross_platform_replay.py \
  --input /path/to/refined-records.json \
  --output /tmp/bhe-decision-replay.json

jq -c '.replays[]' /tmp/bhe-decision-replay.json | while IFS= read -r replay; do
  printf '%s' "$replay" | cargo run --features dynamic-onnx --manifest-path packages/bhe_runtime/Cargo.toml --bin bhe-runtime -- --decision-replay
done

# 已构建 Rust replay binary 时，逐候选比较决策字段
.venv/bin/python scripts/compare_cross_platform_replay.py \
  --input /path/to/refined-records.json \
  --rust-binary /path/to/bhe-runtime \
  --output /tmp/bhe-decision-replay-report.json

# 仅在排查旧版 verdict 时锁定 Python 派生字段
.venv/bin/python scripts/compare_cross_platform_replay.py \
  --input /path/to/refined-records.json \
  --rust-binary /path/to/bhe-runtime \
  --locked-decision
```

输入 JSON 必须包含 `records`、`rim`、`frame_width` 与 `frame_height`。它用于隔离检测模型差异，先验证完整穿框、篮网证据、反弹、侧向离开和 verdict 的决策语义。

## 迁移顺序

1. 先统一 Candidate/Evidence/Verdict schema 和算法版本。
2. Rust 按 Python 语义补齐 recovery track、多轨关联、完整穿框、post-crossing persistence 与 lateral exit。
3. 统一篮网测量可用性、baseline 和 `net_support` 语义。
4. 统一 verdict 与自动导出 gate，再统一端内评分。
5. 把公共回放加入 CI；之后才允许独立调任一端的阈值。
