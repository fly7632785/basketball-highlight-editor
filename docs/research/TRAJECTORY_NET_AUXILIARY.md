# 投篮轨迹与篮网运动辅助判断

## 实现位置

- 轨迹特征：`src/basketball_highlight/events.py`
- 篮网帧差采集：`scripts/refine_candidates.py`
- 测试：`tests/test_events.py`

## 当前特征

新增事前落点预测辅助字段：

- `prediction`：使用篮筐上方轨迹拟合的预测结果；
- `prediction_review`：预测落点位于篮筐走廊且拟合质量达到门槛时，提升 `recall_review` 标记；
- 不改变 `high_precision`，也不单独生成自动导出事件。

在当前 119 个缓存精筛窗口回放中，55 个几何事件里有 18 个能形成预测，7 个被标记为 `prediction_review`；该结果只说明辅助信号已接通，不代表真实进球召回率已经提升。

### 投篮轨迹

在穿越点前最多 `0.6s` 的篮球轨迹中记录：

- `approach_rise_px`：接近篮筐前的上升幅度；
- `approach_horizontal_span_px`：接近过程的横向移动幅度；
- `trajectory_score`：上升幅度和穿越下降速度的综合分数。

### 篮网运动

在篮筐下方固定区域使用连续帧灰度帧差，记录：

- `net_motion_peak`：候选时间窗内篮网区域的最大变化；
- `net_motion_delta`：相对于候选前基线的增加量；
- `net_changed_ratio`：变化超过阈值的像素比例；
- `net_motion_score`：归一化辅助分数。

篮网信号不是单独的进球判定条件。当前仅在“篮网运动很弱且轨迹横向性强/轨迹分数低”时过滤候选，以减少传球误报。

## 当前真实视频结果

输入候选：17 个，人工标注进球：

```text
1.35s、38.00s、154.85s、267.20s
```

使用 `10 FPS` 粗扫、`±2.5s` 精筛后：

```text
保留：1.35s、38.00s、154.85s、267.20s
已标注候选集 Precision：100%
已标注候选集 Recall：100%
```

该结果只覆盖当前视频的 17 个候选，不能代表未进入候选列表的漏检率，也不能代表其它机位和场馆。
