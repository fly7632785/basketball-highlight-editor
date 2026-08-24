# 入门指南

**中文** · [English](GETTING_STARTED.en.md)

这份文档面向第一次运行项目的开发者。它覆盖桌面端主路径、Windows 实验路径和移动端开发入口。

## 1. 先确认边界

当前仓库是源码预览版，不是最终用户安装包。你需要自行准备：

- Python 3.11 和项目依赖；
- Flutter stable（当前开发基线为 3.44.8）；
- FFmpeg 和 FFprobe（桌面端）；
- 仓库内置的默认检测模型；如果使用不含大文件的精简发布包，再自行提供兼容模型；
- 你有权处理的比赛视频。

源码许可证不自动覆盖模型、视频、训练数据、FFmpeg 构建和第三方依赖。发布前请看 [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md) 和 [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md)。

## 2. 桌面端 macOS/Linux 开发环境

### 2.1 获取源码

```bash
git clone <repository-url>
cd basketball-highlight-editor
```

### 2.2 创建 Python 环境

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -c "import cv2, numpy, pandas, psutil, torch, ultralytics; print('python imports: OK')"
```

如果 `torch` 导入失败，先按当前 Python 和 CPU/Apple Silicon/Intel 平台安装可用的 PyTorch，再重新安装项目依赖。不要把开发机 `.venv` 直接当作发布运行时。

### 2.3 安装 FFmpeg

macOS 开发机可以使用 Homebrew：

```bash
brew install ffmpeg
ffmpeg -version
ffprobe -version
```

Homebrew 版本适合本机开发，不代表可以直接复制到可分发 `.app`；发布时需要自包含或静态构建，并核对 LGPL/GPL 边界。

### 2.4 确认内置模型

当前完整源码仓库已经包含默认桌面模型：

```text
models/bball_model.pt
```

因此正常 clone 后不需要手动下载模型。只有在发布包不含模型或希望替换模型时，才传入自定义路径：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model /absolute/path/to/your-model.pt
```

如果当前目录确实缺少模型，Engine 会返回 `MODEL_LOAD_FAILED`，不会静默下载未知权重。替换模型必须兼容当前检测脚本的类别和格式，并且你拥有使用权。

### 2.5 检查运行时

在仓库根目录运行：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python
```

成功时输出应包含：

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

这只检查环境完整性，不验证模型准确率。

### 2.6 启动桌面端

```bash
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

如果应用找不到 Engine 或 Python，可以显式设置运行时目录：

```bash
BHE_REPO_ROOT="$(pwd)/../.." flutter run -d macos
```

或者指定 Python：

```bash
BHE_REPO_ROOT="$(pwd)/../.." \
BHE_PYTHON="$(pwd)/../../.venv/bin/python" \
flutter run -d macos
```

桌面端运行时查找顺序和打包目录见 [`DEVELOPMENT.md`](DEVELOPMENT.md) 与 [`RELEASE.md`](RELEASE.md)。

## 3. 第一次使用桌面端

1. 新建项目并选择原始视频。
2. 检查文件名、时长、分辨率、帧率、音视频编码和文件大小。
3. 优先使用自动建议 ROI（感兴趣区域）；失败时在预览帧上手动框选篮筐区域。
4. 设置分析范围和片段前后窗口，选择标准或快速模式。
5. 启动分析，观察阶段、进度和耗时；需要时可以取消或重试。
6. 在审核工作台播放原视频，切换候选、排除误检、修改片段起止点或手动补漏。
7. 选择分别导出或合并导出。候选默认保留，只有排除的候选不会导出。

ROI 太小可能漏掉篮球轨迹，ROI 太大可能增加误检和耗时。候选是模型生成的疑似事件，不是自动确认的进球。

## 4. 分析模式

- **标准模式**：生成代理、粗扫候选，并回到原视频进行精筛；质量优先。
- **快速模式**：使用较低成本代理并跳过原视频精筛；速度优先，可能漏检。

分析开始后模式锁定。要切换模式，先取消当前分析，再重新启动。模式规则、缓存和自动继承边界见 [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md)。

## 5. Windows 实验性路径

Windows 不是当前正式发布门槛，但仓库提供兼容路径。需要 Python 3.11、Flutter Windows 工具链、`ffmpeg.exe`、`ffprobe.exe`、便携模型和本地运行权限。

PowerShell 准备依赖：

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

便携运行时和压缩包命令见 [`RELEASE.md`](RELEASE.md)。

## 6. 移动端开发入口

移动端是独立 Flutter 工程，不启动桌面 Python Engine：

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Android 原生分析当前主要验证 `arm64-v8a`。准备 Rust target、Android NDK 和 ONNX Runtime Android 库后：

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
rustup target add aarch64-linux-android
../../scripts/build_mobile_runtime.sh
flutter build apk --release
```

没有原生 Runtime 产物时，Android UI 和导出仍可构建，但分析会明确返回 `NATIVE_RUNTIME_UNAVAILABLE`。iOS 的项目、播放、审核和导出通道可用；本地分析还需要执行 [`scripts/build_mobile_ios_runtime.sh`](../scripts/build_mobile_ios_runtime.sh) 并把产物接入 Runner。完整边界见 [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) 和 [`../apps/mobile/README.md`](../apps/mobile/README.md)。

## 7. 单独调试 Engine

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

发送最小请求：

```json
{"protocol_version":"1.0","type":"request","request_id":"1","command":"hello","payload":{}}
```

stdout 只能输出业务 JSONL；诊断日志写 stderr。协议细节以 [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md) 为准。

## 8. 导出审核数据

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project
```

包含待审核候选并生成 CSV：

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project \
  --include-pending \
  --csv
```

导出文件可能包含真实路径、备注和球员标签，只应保留在本地。字段说明见 [`REVIEW_DATASET_EXPORT.md`](REVIEW_DATASET_EXPORT.md)。

## 9. 最小验收

- 运行时检查成功；
- Python 测试和受影响的 Flutter 测试通过；
- 可以创建并重新打开项目；
- 可以导入视频、保存 ROI、完成分析；
- 候选可以播放、排除、调整范围和补漏；
- 分别导出和合并导出都能生成文件；
- 原视频移动后能提示重新定位；
- 重启应用后项目和审核状态仍然存在。
