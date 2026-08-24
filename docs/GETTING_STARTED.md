# 入门指南

**中文** · [English](GETTING_STARTED.en.md)

这份文档面向第一次运行 Basketball Highlight Editor 的开发者。它把 README 的快速开始展开为可复制的准备、检查、运行和故障排查步骤。

## 1. 先确认当前边界

当前仓库是源码预览版，不是最终用户安装包。你需要自行准备：

- Python 3.11 和依赖；
- Flutter 3.44.8 stable；
- FFmpeg 和 FFprobe；
- 与当前检测流程兼容、且你有权使用的模型；
- 你有权处理的篮球比赛视频。

模型、真实视频、训练数据和第三方依赖的授权互相独立。不要因为源码采用 MIT License，就认为模型或视频也可以自由分发。

## 2. macOS 开发环境

### 2.1 获取源码

不要把仓库地址写死在文档或脚本中，使用你实际配置的远程地址：

```bash
git clone <your-repository-url>
cd basketball-highlight-editor
```

### 2.2 准备 Python

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

检查 Python 版本和依赖导入：

```bash
.venv/bin/python --version
.venv/bin/python -c "import cv2, numpy, pandas, psutil, torch, ultralytics; print('python imports: OK')"
```

如果 `torch` 导入失败，先按照当前 Python 和 Apple Silicon/Intel 平台安装对应的 PyTorch 发行版，再重新安装项目依赖。不要把本机 `.venv` 复制为发布运行时。

### 2.3 准备 FFmpeg

开发机可以使用 Homebrew：

```bash
brew install ffmpeg
ffmpeg -version
ffprobe -version
```

Homebrew 版本适合本机开发，不代表可以直接复制进可分发 `.app`。发布时需要自包含或静态构建，并单独核验 FFmpeg 的 LGPL/GPL 边界。

### 2.4 准备模型

把本地模型放到：

```text
models/bball_model.pt
```

模型文件被 Git 忽略，不会被提交。当前 Engine 缺少模型时会返回 `MODEL_LOAD_FAILED`，不会静默下载未知权重。模型说明见 [../models/README.md](../models/README.md)。

### 2.5 运行时检查

在仓库根目录运行：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

成功输出应包含：

```text
runtime: OK
- engine: OK
- src: OK
- sqlite_schema: OK
- scripts: OK
- model: OK
- python_imports: OK
- ffmpeg: OK
- ffprobe: OK
```

如果某一项失败，先修复该项再启动 UI。`check_runtime.py` 的目标是发现环境缺失，不会验证模型的检测准确率。

## 3. 启动桌面端

Flutter 项目位于 `apps/desktop`，不要在仓库根目录执行 Flutter 的项目命令：

```bash
cd apps/desktop
flutter --version
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

应用会尝试按以下顺序找到 Engine 运行目录：

1. `BHE_RUNTIME_ROOT` 指向的目录；
2. `BHE_REPO_ROOT` 指向的仓库或运行时目录；
3. macOS `.app/Contents/Resources/runtime`；
4. Windows 可执行文件旁的 `runtime`；
5. 当前可执行文件和工作目录的上级目录。

开发环境中，从 `apps/desktop` 启动通常可以向上找到仓库根目录。如果仍然找不到 Engine，可以显式设置：

```bash
BHE_REPO_ROOT="$(pwd)/../.." flutter run -d macos
```

如果 Python 不在运行时目录中，可以显式指定：

```bash
BHE_REPO_ROOT="$(pwd)/../.." \
BHE_PYTHON="$(pwd)/../../.venv/bin/python" \
flutter run -d macos
```

仅在你明确知道系统 Python 满足依赖时，才使用 `BHE_ALLOW_SYSTEM_PYTHON=1`。不建议把它作为发布方案。

## 4. 第一次使用流程

### 步骤 A：创建项目和导入视频

- 新建项目目录；
- 选择原始视频；
- 等待读取时长、分辨率、帧率、编码和文件大小；
- 确认原始视频没有被复制，项目只保存引用路径和元数据。

如果视频被移动，项目会显示源文件缺失。使用“重新定位视频”重新关联，不要直接修改 SQLite。

### 步骤 B：设置分析范围和 ROI

- 默认可分析整个视频，也可以缩小范围进行测试；
- 优先尝试自动建议篮筐 ROI；
- 自动建议依赖模型和短时间采样，如果失败，使用预览帧手动框选；
- 保存 ROI 后才能开始分析。

ROI 是感兴趣区域，决定模型主要观察画面的哪一部分。ROI 太小可能漏掉篮球运动，太大可能增加误检和耗时。

### 步骤 C：选择分析模式

- **标准模式**：完成代理粗扫和原视频回源精筛，质量优先；
- **快速模式**：降低代理成本并跳过原视频回源精筛，速度优先，可能漏检。

分析开始后模式会锁定。要换模式，应取消当前分析后重新启动。快速模式完成后仍然需要人工审核，不能直接把它当作完整检测结果。

### 步骤 D：审核候选

候选审核工作台使用原视频播放，不把代理视频当作最终剪辑源。常用操作：

- 播放、暂停和拖动进度；
- 上一个/下一个候选；
- 保留或排除候选；
- 修改片段起止点；
- 添加备注；
- 从当前播放位置手动补漏。

当前产品规则是“候选默认保留”：没有被排除的候选会进入导出。你不需要为了导出逐条点击确认。

### 步骤 E：导出

导出前再次读取数据库中的审核状态：

- 已排除候选不会导出；
- 待审核候选默认会导出；
- 手动补漏候选默认会导出；
- 合并导出按事件时间排序并处理重叠；
- 最终导出使用原始视频，代理只用于分析和预览。

## 5. 调试 Engine

单独启动 Engine：

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

发送最小 `hello` 请求：

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

调试时注意：

- stdout 是业务 JSONL，不要把普通日志写入 stdout；
- stderr 用于诊断；
- Engine 启动后由 Flutter 通过 JSONL 调用；
- 协议细节以 [architecture/ENGINE_PROTOCOL_V1.md](architecture/ENGINE_PROTOCOL_V1.md) 为准。

## 6. Windows 实验性路径

Windows 不是当前 V1 发布门槛，但仓库提供兼容路径。需要：

- Python 3.11；
- Flutter Windows desktop 工具链；
- 可执行的 `ffmpeg.exe` 和 `ffprobe.exe`；
- 便携 Python 运行时；
- 本地模型。

在 PowerShell 中准备开发依赖：

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
```

运行检查：

```powershell
.\.venv\Scripts\python.exe scripts\check_runtime.py `
  --root . `
  --python .venv\Scripts\python.exe `
  --model models\bball_model.pt
```

启动桌面端：

```powershell
cd apps\desktop
flutter pub get
flutter run -d windows
```

Windows 发布运行时和打包命令见 [RELEASE.md](RELEASE.md)。

## 7. 运行人工审核数据导出

只导出已经产生审核记录的候选：

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project
```

包含待审核候选并生成 CSV：

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project \
  --include-pending \
  --csv
```

不要把包含球员身份、真实视频路径或个人信息的数据文件提交到公开仓库。详细字段见 [REVIEW_DATASET_EXPORT.md](REVIEW_DATASET_EXPORT.md)。

## 8. 完成后的最小验收

- `scripts/check_runtime.py` 报告 `runtime: OK`；
- Python 测试通过；
- Flutter `analyze` 和测试通过；
- 可以创建项目并重新打开；
- 可以导入视频、保存 ROI、完成分析；
- 候选可以播放、排除、调整范围；
- 分别导出和合并导出都能生成文件；
- 原始视频被移动后，项目能提示重新定位；
- 关闭并重开应用后，项目状态和审核结果仍在。
