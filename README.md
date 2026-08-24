# Basketball Highlight Editor

如果你拍过整场篮球比赛，应该知道精彩片段藏在几十分钟的录像里有多难找。Basketball Highlight Editor 会先帮你找出可能的进球，再把决定权交给你。

它是一个本地运行的篮球视频分析和剪辑工具：自动找候选，人工做判断，最后导出集锦。

**[快速开始](docs/GETTING_STARTED.md)** · **[常见问题](docs/FAQ.md)** · [English](README.en.md)

## 它解决的是什么问题？

| 你可能遇到的情况 | 它怎么处理 |
|---|---|
| 一场比赛太长，手动回看很耗时 | AI 自动扫描视频，先给出疑似进球候选 |
| 自动剪辑容易误检，结果不可控 | 候选默认进入审核，你可以保留、排除、调整和补充 |
| 视频素材不想上传云端 | 分析、预览、审核和导出默认都在本地完成 |
| 想快速看结果，又不想牺牲质量 | 提供快速模式和标准模式，按场景选择 |

## 从比赛视频到精彩集锦

```text
导入比赛视频  →  AI 自动分析  →  审核候选片段  →  导出集锦
```

1. **导入**：选择比赛视频，检查时长和画面信息。
2. **分析**：自动识别篮筐区域和疑似进球事件。
3. **审核**：在视频工作台中逐个查看候选，调整片段范围或手动补漏。
4. **导出**：分别导出片段，或按比赛时间合并成一条集锦。

## 实际用起来

- 自动建议篮筐区域，也支持手动框选和调整；
- 使用**标准模式**获得更完整的分析，或使用**快速模式**快速浏览结果；
- 在原视频上播放候选，保留/排除、修改时间范围、添加备注；
- 候选默认保留，不需要逐条点击“确认”；
- 支持单独导出和按事件时间合并导出；
- 分析进度、阶段耗时、任务恢复和导出记录清晰可见。

## 适合谁？

- 想快速整理校队、业余联赛或训练赛集锦的球员和教练；
- 需要反复复盘比赛、但不想手动拖完整视频的人；
- 希望素材留在自己电脑上、同时保留人工控制权的创作者和开发者。

当前版本优先针对**固定机位、单篮筐、单场比赛视频**优化。AI 负责缩小回看范围，最终是否保留由你决定。

## 快速开始（macOS）

完整源码仓库已经包含默认检测模型，正常 clone 后不需要额外下载模型。

### 1. 准备环境

需要 Python 3.11、Flutter stable 和 FFmpeg。macOS 可使用 Homebrew 安装 FFmpeg：

```bash
brew install ffmpeg
```

### 2. 安装项目依赖

```bash
# 在 GitHub 的 Code 菜单复制仓库地址
git clone <repository-url>
cd basketball-highlight-editor

python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

### 3. 检查并启动

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python

cd apps/desktop
flutter pub get
flutter run -d macos
```

启动后按照“新建项目 → 选择视频 → 分析 → 审核 → 导出”操作即可。Windows、移动端和完整排障步骤见 [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md)。

## 两种分析方式

| 模式 | 适合场景 | 特点 |
|---|---|---|
| **标准模式** | 重要比赛、希望尽量完整 | 质量优先，包含原视频精筛 |
| **快速模式** | 先快速浏览、快速定位片段 | 速度优先，可能漏检 |

两种模式使用相同的审核、调整和导出流程。快速模式不是“自动替你做决定”，而是让你更快得到第一版候选。

## 核心技术

- **Flutter**：桌面端和移动端界面；
- **Python + OpenCV + YOLO**：视频采样、篮球/篮筐检测和候选生成；
- **SQLite**：保存项目、分析任务、候选和审核状态；
- **FFmpeg / FFprobe**：视频元数据、预览和导出；
- **Rust + ONNX Runtime**：移动端本地推理路径。

想了解实现细节，可以从 [`docs/README.md`](docs/README.md) 开始，再阅读 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) 和 [`docs/architecture/`](docs/architecture/)。

## 当前版本

macOS 桌面端是当前最完整、最推荐的体验路径。Windows 和移动端工程已提供开发入口，但仍属于持续完善中的实验性路径。

## 文档

- **开始使用**：[`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) · [`docs/FAQ.md`](docs/FAQ.md)
- **产品说明**：[`docs/USER_FLOW_V1.md`](docs/USER_FLOW_V1.md) · [`docs/REQUIREMENTS_V1.md`](docs/REQUIREMENTS_V1.md) · [`docs/DECISIONS_V1.md`](docs/DECISIONS_V1.md)
- **开发指南**：[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- **架构参考**：[`docs/README.md`](docs/README.md) · [`docs/architecture/`](docs/architecture/)
- **发布说明**：[`docs/RELEASE.md`](docs/RELEASE.md)

## 开源致谢

本项目在模型、检测流程和产品工作流上参考了 [HoopCut](https://github.com/RuiYang0122/HoopCut)、[basketball-highlights](https://github.com/reborncd/basketball-highlights)、[ShotMarker](https://github.com/zhangrunhao/ShotMarker)、[basketball_clipper](https://github.com/snowroll/basketball_clipper)、[ball-yolo](https://github.com/griftt/ball-yolo)、[basketball-highlights](https://github.com/ClarkWang1214/basketball-highlights) 和 [ai-sports-cut-agent](https://github.com/bond0060/ai-sports-cut-agent)。感谢所有作者的公开分享。

## 隐私与许可证

视频默认只保留本地路径和元数据，不上传到云端。源码采用 [MIT License](LICENSE)；模型、训练数据、视频素材和第三方依赖请分别遵守各自授权条件。

项目还在持续完善。如果你用它处理过比赛视频，欢迎把遇到的问题和效果反馈回来。
