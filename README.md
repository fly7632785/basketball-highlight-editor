# Basketball Highlight Editor

> 固定机位篮球比赛视频的本地进球候选识别、人工审核和集锦导出工具。

**中文** · [English](README.en.md)

## 项目状态

当前版本是 **V1 源码预览版**，重点用于公开架构、分析流程和桌面端闭环。它不是最终用户安装包：Python 运行时、FFmpeg/FFprobe、模型权重和测试视频需要使用者自行准备，并分别确认授权。

当前已经跑通的主流程：

```text
导入视频 → 读取元数据 → 自动建议或手动框选篮筐区域
→ 生成分析代理 → 本地分析 → 候选审核
→ 手动调整片段 → 分别导出或合并导出
```

## 适用范围

- 固定机位、单篮筐的视频；
- 一次处理一个项目、一个原始视频；
- 长视频批量扫描，自动生成“疑似进球”候选；
- 用户审核后再导出，**候选不等于已经确认的进球**；
- macOS 桌面端优先，Windows 保持架构兼容并提供实验性打包脚本；
- 所有视频分析默认在本地完成，不需要账号，也不会自动上传原始视频。

不适合：移动镜头、多篮筐同时出现、实时直播、需要云端协作或希望直接得到零误检结果的场景。

## 主要功能

- **视频导入与元数据检查**：显示时长、分辨率、帧率、编码和文件大小；只保存原始视频引用，不复制原视频。
- **篮筐区域配置**：优先尝试自动建议 ROI（感兴趣区域），失败时可在预览帧上手动框选。
- **两档分析模式**：标准模式优先质量；快速模式优先速度，可能漏检。
- **分析过程可恢复**：显示阶段、进度、耗时，支持取消、失败重试和应用重启后发现未完成任务。
- **候选审核工作台**：播放原视频、切换候选、保留/排除、备注、调整片段起止点和手动补漏。
- **简单审核语义**：默认候选保留，用户只需要排除误检；不要求逐条点击“确认”才能导出。
- **导出**：分别导出每个片段，或按事件时间合并为一个集锦；导出完成后保存路径和统计信息。
- **本地项目持久化**：每个项目使用 SQLite 保存视频、ROI、候选、审核状态、任务和导出记录。

## 技术架构

```text
Flutter Desktop
    │ JSON Lines over stdin/stdout
    ▼
Python Engine
    ├── SQLite：项目状态、任务、候选、审核和导出记录
    ├── OpenCV / Ultralytics：视频采样与目标检测
    ├── Python 算法库：候选生成、轨迹和审核规则
    └── FFmpeg / FFprobe：代理、预览和最终剪辑
```

Flutter 不直接读写 SQLite、检测 JSON 或执行 FFmpeg；Engine 通过 [docs/architecture/ENGINE_PROTOCOL_V1.md](docs/architecture/ENGINE_PROTOCOL_V1.md) 定义的 JSONL（JSON Lines，逐行 JSON 消息）协议提供能力。算法和分发边界见 [docs/architecture/ARCHITECTURE_V1.md](docs/architecture/ARCHITECTURE_V1.md)。

## 环境要求

### 已验证基线

| 组件 | 要求 |
|---|---|
| 操作系统 | macOS 桌面端优先；Windows 路径仍属于实验性支持 |
| Flutter | `3.44.8` stable，或与项目 Dart SDK 兼容的版本 |
| Python | 推荐 `3.11` |
| Python 依赖 | `ultralytics`、`opencv-python`、`numpy`、`pandas`、`psutil`；开发测试另需 `pytest` |
| 视频工具 | `ffmpeg` 和 `ffprobe`，必须在 `PATH` 中或通过运行时目录提供 |
| 模型 | 与当前检测流程兼容的篮球检测模型，默认路径为 `models/bball_model.pt` |
| 磁盘 | 分析和导出需要源视频之外的临时空间，启动任务前会执行空间检查 |

Flutter 的 macOS 视频插件可能打印“不支持 Swift Package Manager”的警告。它不是当前运行失败的直接原因；若未来 Flutter 版本将警告升级为错误，应升级插件或等待维护者补充 SPM 支持，详见 [docs/FAQ.md](docs/FAQ.md)。

## 快速开始

下面的命令适用于 macOS/Linux shell。Windows 步骤见 [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) 的 Windows 小节。

### 1. 获取源码并准备 Python

```bash
git clone <your-repository-url>
cd basketball-highlight-editor

python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

如果本机没有 `python3.11`，请安装 Python 3.11 后重新执行；不要把 `.venv/` 提交到仓库。

### 2. 准备 FFmpeg 和模型

开发机可以使用系统 FFmpeg，例如 macOS：

```bash
brew install ffmpeg
```

把你有权使用的模型放到：

```text
models/bball_model.pt
```

仓库不提供未经核验授权的模型下载地址，也不会静默下载未知权重。模型和视频授权边界见 [docs/MODEL_AND_DATA_LICENSES.md](docs/MODEL_AND_DATA_LICENSES.md) 和 [models/README.md](models/README.md)。

### 3. 检查本地运行时

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

看到 `runtime: OK` 后再启动桌面端。检查失败时，先按输出补齐缺失的模型、Python 包、FFmpeg 或项目文件。

### 4. 启动桌面端

```bash
cd apps/desktop
flutter pub get
flutter run -d macos
```

首次使用建议按以下顺序操作：

1. 新建项目并选择原始视频；
2. 检查视频元数据和分析范围；
3. 使用自动建议 ROI，失败时手动框选篮筐区域；
4. 选择“标准”或“快速”模式并开始分析；
5. 在候选审核工作台播放和切换候选，排除误检或调整片段范围；
6. 选择分别导出或合并导出。

更完整的准备、运行和故障排查步骤见 [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)。

## 单独运行 Python Engine

桌面端默认会自行启动 Engine。如需调试协议或单独运行 Engine：

```bash
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

Engine 从标准输入读取 JSONL 请求，向标准输出写 JSONL 响应；`stderr` 只用于诊断。最小请求：

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

协议命令、事件、错误码和兼容规则见 [docs/architecture/ENGINE_PROTOCOL_V1.md](docs/architecture/ENGINE_PROTOCOL_V1.md)。

## 分析模式

| 模式 | 目标 | 处理方式 | 使用建议 |
|---|---|---|---|
| 标准 | 质量优先 | 完成代理粗扫和原视频回源精筛 | 首次分析、重要比赛、不能接受漏检 |
| 快速 | 速度优先 | 使用较低成本代理，直接使用粗扫候选 | 先快速浏览，接受少量漏检后再人工审核 |

快速模式不是“准确率更高”的模式，也没有固定耗时承诺。当前基准记录中，单个约 4.6 分钟样本的冷启动耗时为标准 `75.73s`、快速 `42.07s`，实测提速 `44.4%`；该样本没有完整人工真值，不能据此宣称召回率。详情见 [docs/research/ANALYSIS_MODES_V1.md](docs/research/ANALYSIS_MODES_V1.md) 和 [docs/research/ANALYSIS_MODE_BENCHMARK_20260812.md](docs/research/ANALYSIS_MODE_BENCHMARK_20260812.md)。

构建时可以通过 `--dart-define=ENABLE_FAST_ANALYSIS=false` 隐藏快速模式入口：

```bash
flutter run -d macos --dart-define=ENABLE_FAST_ANALYSIS=false
```

## 测试与质量检查

```bash
# 开源公开前检查，不需要安装 Python 运行依赖
python3 scripts/check_open_source.py

# Python 单元测试
.venv/bin/python -m pytest -q

# Flutter 桌面检查
cd apps/desktop
flutter analyze
flutter test
```

也可以在仓库根目录使用：

```bash
make check-open-source
make python-test
make flutter-desktop-analyze
make flutter-desktop-test
```

本地 Engine 闭环证据见 [docs/LOCAL_E2E_V1.md](docs/LOCAL_E2E_V1.md)。算法候选必须人工审核，不能把测试通过等同于算法准确率验收。

## 打包与发布边界

### macOS

本地 Debug 构建：

```bash
cd apps/desktop
flutter build macos --debug
```

可分发运行时还必须提供便携 Python、依赖、静态或自包含 FFmpeg、FFprobe 和已核验授权的模型。准备运行时和构建 `.app`：

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

当前构建脚本不会替你解决模型授权、签名、公证或干净机器安装验证；`Release .app` 构建成功不等于最终安装包可分发。详见 [docs/RELEASE.md](docs/RELEASE.md) 和 [docs/MACOS_PACKAGING_V1.md](docs/MACOS_PACKAGING_V1.md)。

### Windows

Windows 运行时准备和打包脚本已经纳入源码，但还不是 V1 发布门槛。请使用 PowerShell，并准备便携 Python、FFmpeg、FFprobe 和模型；具体命令见 [docs/RELEASE.md](docs/RELEASE.md)。

## 文档导航

### 用户与运行

- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)：从零准备环境、首次运行和基本工作流
- [docs/FAQ.md](docs/FAQ.md)：模型、FFmpeg、Engine、候选为空、视频丢失和插件警告排查
- [docs/README.md](docs/README.md)：全部文档索引

### 开发与架构

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)：开发环境、测试、调试和提交前检查
- [docs/architecture/ARCHITECTURE_V1.md](docs/architecture/ARCHITECTURE_V1.md)：系统边界和模块职责
- [docs/architecture/ENGINE_PROTOCOL_V1.md](docs/architecture/ENGINE_PROTOCOL_V1.md)：Flutter ↔ Python Engine JSONL 契约
- [docs/architecture/PROJECT_LAYOUT_V1.md](docs/architecture/PROJECT_LAYOUT_V1.md)：仓库和用户项目目录
- [docs/architecture/SQLITE_SCHEMA_V1.sql](docs/architecture/SQLITE_SCHEMA_V1.sql)：SQLite 数据库结构
- [apps/desktop/lib/theme/](apps/desktop/lib/theme/)：桌面 UI 主题和设计 token

### 产品与研究

- [docs/REQUIREMENTS_V1.md](docs/REQUIREMENTS_V1.md)：V1 范围、验收状态和明确不做事项
- [docs/USER_FLOW_V1.md](docs/USER_FLOW_V1.md)：用户流程和异常路径
- [docs/DECISIONS_V1.md](docs/DECISIONS_V1.md)：当前产品、算法和工程决策
- [docs/research/ANALYSIS_MODES_V1.md](docs/research/ANALYSIS_MODES_V1.md)：快速/标准模式规则

### 开源与发布

- [docs/RELEASE.md](docs/RELEASE.md)：发布前检查、运行时打包、签名和许可证
- [docs/OPEN_SOURCE_AUDIT.md](docs/OPEN_SOURCE_AUDIT.md)：源码公开审计和剩余阻塞项
- [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md)：第三方组件和参考项目边界
- [docs/MODEL_AND_DATA_LICENSES.md](docs/MODEL_AND_DATA_LICENSES.md)：模型、数据和视频授权
- [CONTRIBUTING.md](CONTRIBUTING.md)：贡献指南
- [SECURITY.md](SECURITY.md)：安全漏洞报告
- [LICENSE](LICENSE)：源码许可证

## 隐私与数据安全

- 原始视频默认只保存路径、元数据和可选指纹，不复制到项目目录；
- 分析、预览、审核和导出默认在本地完成；
- 真实比赛视频、球员画面、球队标识和标注数据不应提交到公开仓库；
- 模型权重和训练数据的授权独立于本项目源码许可证；
- 如启用任何遥测或数据导出功能，应先取得用户明确授权。

## 已知限制

- 自动结果是候选，不是裁判结论；请在导出前审核；
- 目前针对固定机位、单篮筐场景优化；
- 当前公开版本没有最终用户安装包，也不随仓库提供模型权重或真实视频；
- macOS 发布包仍需要便携运行时、FFmpeg 许可核验、代码签名、公证和干净环境测试；
- Windows 和移动端仍处于兼容/预研阶段；
- Rust/ONNX Runtime 迁移不是 V1 运行前置条件，当前 Engine 仍由 Python 实现。

## 贡献

欢迎提交问题、测试反馈和小范围修复。提交前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，不要提交视频、模型、真实标注、密钥、个人路径或构建产物。

## 许可证

本仓库源码采用 MIT License。该许可证不自动覆盖模型权重、训练数据、输入视频、FFmpeg 编译产物或第三方依赖；发布这些对象前必须分别确认授权，并保留对应 notices。

---

如果你只想快速判断项目是否适合自己的视频，先完成“准备模型 → 运行时检查 → 启动桌面端”三步；如果分析没有候选，优先阅读 [docs/FAQ.md](docs/FAQ.md) 的 ROI、模型和视频格式排查项。
