# 优化阶段 V3：性能优先 + 跨视频验证

## 结论

当前版本完成了性能基础设施和可重复验证工具，但**还没有达到自动产品化门槛**。两个视频的旧门槛结果仍然是：

| 视频 | 候选 | 进球标签 | 自动 TP | 自动 FP | Precision | Recall |
|---|---:|---:|---:|---:|---:|---:|
| 30 分钟 | 59 | 32 | 23 | 0 | 100.0% | 71.9% |
| 1 小时 | 51 | 18 | 5 | 13 | 27.8% | 27.8% |

30 分钟上的 100% Precision 是同视频校准结果，不作为泛化证据。

## 已完成

### 1. 性能路径

- `scripts/scan_video.py`
  - 非采样帧使用 `VideoCapture.grab()`，采样帧才 `retrieve()`，避免无意义的像素解码和拷贝。
- `scripts/refine_candidates.py`
  - 保留批量 YOLO 推理和 `grab/retrieve` 路径。
  - 支持扫描区间覆盖参数。
- `scripts/refine_dynamic_candidates.py`
  - 新增 `merge_scan_windows()`。
  - 相邻候选窗口合并成一个顺序扫描区间；扫描后再切回各候选窗口。
  - 每个候选仍写独立缓存，后续改判定逻辑不需要重复 YOLO。
- `scripts/extract_audio_features.py`
  - 多个候选的音频窗口合并后单次 `ffmpeg` 解码，避免每个候选启动一次进程。

已有音频抽取实测：

| 视频 | 候选 | 音频特征耗时 |
|---|---:|---:|
| 30 分钟 | 59 | 8.93 秒 |
| 1 小时 | 51 | 17.31 秒 |

音频不是当前主耗时；YOLO/视频解码仍是主耗时。

### 2. 多模态特征

- `src/basketball_highlight/audio.py`
  - 局部基线与事件窗口对比：RMS、峰值、分贝变化、频谱流量、高频占比。
- `src/basketball_highlight/trajectory.py`
  - 已有的上方下降段抛物线预测继续作为辅助证据，不复活明确反弹/横向离开。
- `src/basketball_highlight/events.py`
  - 篮球轨迹、篮筐几何、篮网运动和预测通道仍然分层输出。
- `scripts/error_analysis.py`
  - 自动生成 26 个错误候选的分析队列，保留人工填写的视觉原因字段。

当前 1 小时错误队列统计：

| 项目 | 数量 |
|---|---:|
| 误报 | 13 |
| 漏检 | 13 |
| 预测辅助命中 | 3 个错误候选进入 `prediction_review` |
| 可用但低分预测 | 8 |
| 无预测 | 15 |
| 音频强能量突增 | 5 |

音频和轨迹目前只用于分析，**尚未直接改自动导出门槛**，避免用 2 个视频过拟合。

### 3. 跨视频验证

- `scripts/evaluate_gate_variants.py`
  - 对比绝对像素门槛和篮筐宽度归一化门槛。
- `scripts/train_classifier_cv.py`
  - 提供小型正则化 Logistic 基线。
  - 使用按视频留一验证，而不是同视频调参同视频测试。

修正后的验证产物：

- `/Users/macmima1234/basketball-highlight-editor/data/artifacts/gate_variants_v2.json`
- `/Users/macmima1234/basketball-highlight-editor/data/artifacts/classifier_cv_v2.json`

归一化门槛的当前结果：

| 视频 | 绝对门槛 P/R | 归一化门槛 P/R |
|---|---:|---:|
| 30 分钟 | 100.0% / 71.9% | 100.0% / 65.6% |
| 1 小时 | 27.8% / 27.8% | 31.8% / 38.9% |

结论：**归一化能改善 1 小时 Recall，但同时引入大量误报，不能直接接入自动导出规则。**

分类器留一验证结果也不达标：

- 30 分钟作为测试集：`Precision 80.8% / Recall 65.6%`；
- 1 小时作为测试集：`Precision 47.8% / Recall 61.1%`。

原因不是分类器代码无法运行，而是当前只有两个机位/视频域，特征分布明显漂移，样本量不足以支持可靠的监督学习。此前分类器读取候选时没有附加归一化几何字段，已在 `evaluate_validation.py` 修正；V2 才是有效结果。

另外对 `third_party/nbaction/best.pt` 做了错误样本抽样测试。该模型在这些片段中主要输出 `Basketball`、`Player`、`Basketball Hoop`，没有稳定输出 `shooting`，因此当前不替换现有 `bball_model.pt`，避免引入更重但没有实测收益的模型路径。

## 开源项目的吸收边界

| 项目思路 | 当前吸收方式 |
|---|---|
| `bball-highlights` | YOLO 检球 + 篮筐区域几何判定；不采用 HSV 作为主判据 |
| `Basketball-Shot-Detection` | 球/筐检测日志、轨迹连续性、穿越篮筐走廊 |
| `OwlTing/AI_basketball_games_video_editor` | 检测与事件判断分层；专用球/筐类别作为后续训练方向 |
| `opencv-basketball-shot-tracker` | 上方清晰轨迹的事前落点预测，作为召回辅助 |
| `sports-highlight-detector` | 运动触发和 `grab/retrieve` 性能路径 |
| `nbaction` | 篮筐附近降低检测阈值的思路，暂不直接套用其投篮分类 |

## 当前不做的事情

1. 不把音频单特征直接作为进球判定。
2. 不把归一化门槛直接替换现有门槛。
3. 不把当前 Logistic 结果接入自动导出。
4. 不进入 Rust/Flutter 产品化。

## 下一阶段顺序

1. 人工补齐 `data/labels/dji_mimo_20260517_error_analysis_v2.csv` 的 `visual_cause`：擦筐、传球、反弹、遮挡、轨迹断裂、重复。
2. 针对错误占比最高的类型添加一个特征，单变量回放验证，禁止一次加入多个未验证特征。
3. 增加至少 3 个不同光线/距离/机位的视频，形成真正的跨域验证集。
4. 有足够标签后再训练时序分类器；验收标准仍是跨视频 `Precision >= 95%`、`Recall >= 85%`。
5. 达标后再把稳定 Python 核心转成 ONNX/Rust，最后接 Flutter。

## 可复现实验命令

```bash
cd /Users/macmima1234/basketball-highlight-editor

PYTHONPATH=src:scripts .venv/bin/python -m unittest discover -s tests -v

PYTHONPATH=src:scripts .venv/bin/python scripts/extract_audio_features.py \\
  --video data/videos/dji_mimo_20260517_082410_0_1779109736239_video.mp4 \\
  --detections data/artifacts/detections/dji_mimo_20260517_proxy_refined_trajectory_v2.json \\
  --output data/artifacts/audio_features_1hour_v1.json

PYTHONPATH=src:scripts .venv/bin/python scripts/error_analysis.py \\
  --detections data/artifacts/detections/dji_mimo_20260517_proxy_refined_trajectory_v2.json \\
  --labels data/labels/dji_mimo_20260517_user_review_v1.json \\
  --audio data/artifacts/audio_features_1hour_v1.json \\
  --output data/labels/dji_mimo_20260517_error_analysis_v2.csv
```
