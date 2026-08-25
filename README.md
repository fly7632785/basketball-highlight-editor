# Basketball Highlight Editor

> 固定机位篮球比赛视频的本地进球候选识别、人工审核与集锦导出工具。

**中文** · [English](README.en.md)

## 项目状态

**当前版本：V1 源码预览版。** 项目适合开发者在本地准备依赖后运行，不是开箱即用的最终安装包。桌面端是当前主产品路径；移动端是独立的实验性工程，Android 已有本地原生分析链路，iOS 的本地 AI 分析仍需要接入最终 Rust/ONNX Runtime 产物。

| 端 | 当前状态 | 适合做什么 |
|---|---|---|
| macOS Desktop | 主路径，支持完整导入 → 分析 → 审核 → 导出闭环 | 本地处理长视频 |
| Windows Desktop | 兼容路径，提供运行时准备和打包脚本，仍需发布验收 | 开发与实验 |
| Android Mobile | 独立 Flutter App；原生抽帧、Rust/ONNX 分析、审核和导出已接入，当前主要验证 `arm64-v8a` | 移动端分析与审核实验 |
| iOS Mobile | 项目、播放、审核和导出可用；本地分析等待原生库链接 | 移动端 UI 与媒体流程验证 |

> **重要：** 模型权重、输入视频、训练数据、FFmpeg 构建和第三方依赖不自动继承本项目的 MIT License。公开或分发前必须分别核验授权。

## 功能概览

- 导入视频并读取时长、分辨率、帧率、编码和文件大小；原视频默认只保存引用，不复制。
- 自动建议篮筐 ROI（感兴趣区域），失败时支持手动框选和调整。
- 标准/快速两档分析：标准质量优先，快速速度优先且可能漏检。
- 显示分析阶段、进度、耗时，支持取消、失败重试和应用重启后的任务恢复提示。
- 候选审核工作台支持原视频播放、候选切换、保留/排除、备注、时间范围调整和手动补漏。
- 候选默认保留；只有排除的候选不会进入导出，避免用户逐条点击“确认”。
- 支持分别导出和按事件时间合并导出，并保存导出记录和统计信息。
- 桌面端使用 SQLite 保存项目、ROI、候选、审核、任务和导出状态。

## 适用范围

当前算法针对**固定机位、单篮筐、单视频**优化，目标是生成高召回的“疑似进球”候选，再由用户审核。它不保证自动结果等于裁判结论，也不针对移动镜头、多篮筐、实时直播、云端协作或零误检场景承诺效果。

## 架构

```text
Desktop Flutter UI ── JSONL ──> Python Engine ──> SQLite
                                     ├── OpenCV / Ultralytics：采样与检测
                                     ├── Python analysis：候选、轨迹与审核规则
                                     └── FFmpeg / FFprobe：代理、预览与导出

Mobile Flutter UI ── platform channels ──> Android/iOS media + Rust/ONNX Runtime
```

桌面端 UI 不直接读写 SQLite、检测 JSON 或调用 FFmpeg；Engine 通过 JSONL（JSON Lines，逐行 JSON 消息）协议提供能力。移动端不启动桌面 Python Engine，使用 `packages/bhe_core` 的数据模型和平台原生能力。

- [桌面架构](docs/architecture/ARCHITECTURE_V1.md)
- [Engine 协议](docs/architecture/ENGINE_PROTOCOL_V1.md)
- [移动端 Runtime](docs/architecture/MOBILE_RUNTIME_V1.md)
- [项目目录与生命周期](docs/architecture/PROJECT_LAYOUT_V1.md)

## 环境要求

### 桌面端

- macOS 优先；Windows 仍是实验性兼容路径；
- Python 3.11；
- Flutter stable，当前开发基线为 3.44.8；
- `ffmpeg`、`ffprobe`；
- 与当前检测流程兼容、且你有权使用的模型；
- 分析和导出需要额外临时磁盘空间。

Python 依赖定义在 [`requirements.txt`](requirements.txt)，开发依赖定义在 [`requirements-dev.txt`](requirements-dev.txt)。

### 移动端

- Flutter stable 和 Android Studio/Xcode 对应的原生工具链；
- Android 原生分析当前只验证 `arm64-v8a`，还需要 Rust、Android NDK、ONNX Runtime Android 库；
- iOS 本地分析还需要 Rust iOS targets 和 ONNX Runtime XCFramework；
- 移动端原生库不应把开发机路径或未核验二进制直接提交到公开发布物。

## 快速开始：桌面端

以下命令适用于 macOS/Linux shell；Windows 见 [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) 的 PowerShell 小节。

### 1. 创建 Python 环境

```bash
git clone <repository-url>
cd basketball-highlight-editor

python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

### 2. 准备 FFmpeg 和模型

macOS 开发环境可以使用 Homebrew：

```bash
brew install ffmpeg
```

将你有权使用的模型放在：

```text
models/bball_model.pt
```

模型缺失时，Engine 不会从未知地址静默下载。模型和数据授权见 [`docs/MODEL_AND_DATA_LICENSES.md`](docs/MODEL_AND_DATA_LICENSES.md) 与 [`models/README.md`](models/README.md)。

### 3. 检查运行时

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

看到 `runtime: OK` 后再启动 UI。该检查只验证环境完整性，不验证算法准确率。

### 4. 启动桌面端

```bash
cd apps/desktop
flutter pub get
flutter run -d macos
```

第一次使用：新建项目 → 选择视频 → 检查元数据 → 自动建议或手动框选 ROI → 选择分析模式 → 分析 → 审核候选 → 导出。

更完整的首次运行、Windows 和故障排查步骤见 [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) 和 [`docs/FAQ.md`](docs/FAQ.md)。

## 分析模式

| 模式 | 处理方式 | 建议 |
|---|---|---|
| 标准 | 代理粗扫后回到原视频精筛 | 首次分析、重要比赛、不能接受漏检时使用 |
| 快速 | `640×480 / 3 FPS` 低成本代理，跳过原视频精筛 | 先快速浏览，接受可能漏检时使用 |

两种模式使用相同的审核、手动调整和导出语义。快速模式不承诺固定耗时或准确率；当前单个约 4.6 分钟样本的冷启动记录为标准 `75.73s`、快速 `42.07s`，仅用于说明该样本的速度差异，不能代表所有视频。详见 [`docs/research/ANALYSIS_MODES_V1.md`](docs/research/ANALYSIS_MODES_V1.md) 和 [`docs/benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md`](docs/benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md)。

可以在构建时隐藏快速模式入口：

```bash
flutter run -d macos --dart-define=ENABLE_FAST_ANALYSIS=false
```

## 单独调试 Python Engine

桌面端会自动启动 Engine。需要调试协议时，可手动启动：

```bash
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

Engine 从 stdin 读取 JSONL 请求、向 stdout 输出 JSONL 响应，stderr 仅用于诊断。协议命令、事件和错误码见 [`docs/architecture/ENGINE_PROTOCOL_V1.md`](docs/architecture/ENGINE_PROTOCOL_V1.md)。

## 移动端开发

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

没有原生 Runtime 产物时，Android UI 仍可构建，但点击分析会明确返回 `NATIVE_RUNTIME_UNAVAILABLE`，不会伪造候选。要构建 Android 原生分析库：

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
rustup target add aarch64-linux-android
../../scripts/build_mobile_runtime.sh
flutter build apk --release
```

移动端完整边界和 iOS Runtime 准备方式见 [`apps/mobile/README.md`](apps/mobile/README.md) 与 [`docs/architecture/MOBILE_RUNTIME_V1.md`](docs/architecture/MOBILE_RUNTIME_V1.md)。

## 测试与质量检查

```bash
# 源码公开前检查：只检查 Git 跟踪内容和敏感路径
python3 scripts/check_open_source.py

# Python 测试
.venv/bin/python -m pytest -q

# 桌面 Flutter
cd apps/desktop
flutter analyze
flutter test

# 移动端 Flutter
cd ../mobile
flutter analyze
flutter test
```

其中移动端原生分析、模型推理和真实视频准确率不由普通单元测试替代，发布前需要在目标设备上单独验收。

## 打包边界

`flutter build macos --release` 或 Windows Release 构建成功，不等于最终用户可以安装。可分发桌面包还需要便携 Python、依赖、FFmpeg/FFprobe、已核验授权的模型、许可证 notices、代码签名、公证和干净机器验证。

macOS 运行时准备与构建命令集中在 [`docs/RELEASE.md`](docs/RELEASE.md)；Windows 脚本属于实验性兼容路径。移动端 Android/iOS 的原生库准备见 [`docs/architecture/MOBILE_RUNTIME_V1.md`](docs/architecture/MOBILE_RUNTIME_V1.md)。

## 文档导航

- **开始使用：** [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) · [`docs/FAQ.md`](docs/FAQ.md)
- **开发贡献：** [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md)
- **架构参考：** [`docs/README.md`](docs/README.md) · [`docs/architecture/`](docs/architecture/)
- **产品契约：** [`docs/DECISIONS_V1.md`](docs/DECISIONS_V1.md) · [`docs/REQUIREMENTS_V1.md`](docs/REQUIREMENTS_V1.md) · [`docs/USER_FLOW_V1.md`](docs/USER_FLOW_V1.md)
- **开源发布：** [`docs/RELEASE.md`](docs/RELEASE.md) · [`docs/OPEN_SOURCE_AUDIT.md`](docs/OPEN_SOURCE_AUDIT.md) · [`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md) · [`docs/MODEL_AND_DATA_LICENSES.md`](docs/MODEL_AND_DATA_LICENSES.md)
- **社区规则：** [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) · [`SECURITY.md`](SECURITY.md) · [`CHANGELOG.md`](CHANGELOG.md) · [`LICENSE`](LICENSE)

## 隐私与数据安全

- 原始视频默认只保存路径、元数据和可选指纹，不复制、不上传；
- 分析、预览、审核和导出默认在本地完成；
- 真实比赛视频、球员画面、球队标识、标注和导出文件不要提交到公开仓库；
- 模型权重、训练数据、FFmpeg 和第三方依赖必须独立核验授权。

## 贡献

欢迎提交问题、测试反馈和聚焦明确的小范围修复。提交前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)，不要提交视频、模型、截图、密钥、个人路径或构建产物。

## 许可证

源码采用 [MIT License](LICENSE)。该许可证不自动覆盖模型权重、训练数据、输入视频、FFmpeg 构建产物或第三方依赖；分发前请阅读 [`NOTICE`](NOTICE) 和 [`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md)。
