# 用户指南

**中文** · [English](USER_GUIDE.en.md)

Basketball Highlight Editor 在本地扫描比赛视频，先生成疑似进球片段，再由你决定哪些内容进入集锦。它不会把模型结果当成最终事实，也不会默认上传原视频。

## 1. 安装和启动

当前最完整的路径是 macOS 桌面端。Windows 提供兼容脚本；移动端是独立 Flutter 工程，功能边界见本页末尾。

### 准备环境

需要 Python 3.11、Flutter stable 和 FFmpeg/FFprobe。macOS 可以这样安装 FFmpeg：

```bash
brew install ffmpeg
```

### 获取源码并安装依赖

```bash
git clone <repository-url>
cd basketball-highlight-editor
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

完整源码仓库包含默认桌面模型：

```text
models/bball_model.pt
```

模型缺失时 Engine 会明确返回 `MODEL_LOAD_FAILED`，不会从未知地址静默下载。替换模型时使用 `scripts/check_runtime.py --model /absolute/path/to/model.pt`，并确认模型类别、格式和授权都符合要求。

### 检查并启动

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python

cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

如果应用找不到仓库运行时，可以显式指定：

```bash
BHE_REPO_ROOT="$(pwd)/../.." \
BHE_PYTHON="$(pwd)/../../.venv/bin/python" \
flutter run -d macos
```

运行时检查只验证环境是否齐全，不代表模型准确率已经通过验收。

## 2. 第一次使用

完整路径是：

```text
新建项目 → 导入视频 → 设置范围 → 设置检测区域 → 选择模式
→ 开始分析 → 审核候选 → 调整或补漏 → 导出集锦
```

1. 点击**新建项目**，选择一段由你有权处理的比赛视频。
2. 检查文件名、时长、分辨率、帧率和编码信息。项目默认只保存原视频路径，不复制或上传原视频。
3. 设置分析范围。整场比赛可以使用全片，也可以只分析需要的时间段。
4. 接受系统建议的 ROI（感兴趣区域），或手动调整投篮分析区和篮网检测区。
5. 选择**标准模式**或**快速模式**，查看预计耗时后开始分析。
6. 分析完成后进入审核工作台。候选默认保留，只有明确排除的候选不会导出。
7. 播放候选，必要时调整片段起止时间、标记球员、添加备注或手动补漏。
8. 选择**合并导出**或**分别导出**。导出完成后可点击**打开目录**。

ROI 太小可能漏掉篮球轨迹，太大则会增加误检和耗时。候选是模型给出的疑似事件，不是自动确认的进球。

## 3. 两种分析模式

| 模式 | 适合场景 | 处理方式 | 取舍 |
|---|---|---|---|
| **标准模式** | 重要比赛、希望尽量完整 | 代理粗扫后回到原视频精筛 | 更慢，通常更稳 |
| **快速模式** | 先快速浏览、快速找片段 | 使用 `640×480 / 3 FPS` 代理并跳过原视频精筛 | 更快，可能漏检 |

新项目默认使用标准模式，并按项目记忆上次选择。分析开始后模式锁定；要切换，先取消当前任务再重新分析。两种模式的审核、手动补漏和导出规则相同。

## 4. 页面和操作

### 项目首页与导入

![深色主题项目首页](../capture/screenshot-20260813-145724.png)

- **新建项目**进入导入流程，**打开项目**恢复已有项目。
- 最近项目显示视频时长、保留数和排除数。
- 视频被移动后使用**重新定位视频**，应用不会猜测新路径。

![深色主题导入视频](../capture/screenshot-20260813-145741.png)

视频加载后会读取时长、分辨率、帧率、音视频编码和文件大小。支持 MP4、MOV、M4V、AVI、MKV 等常见格式，实际可用性取决于 FFmpeg。

### 分析范围与检测区域

![深色主题分析范围](../capture/screenshot-20260813-145806.png)

拖动时间轴两端设置**起点**和**终点**；点击**使用全片**恢复整段视频。缩短范围能减少处理时间，但范围外的事件不会进入分析。

![深色主题检测区域调整](../capture/screenshot-20260813-145835.png)

系统会先建议篮筐区域。**投篮分析区**覆盖篮筐、投篮轨迹和落点附近；**篮网检测区**尽量只覆盖篮网及其周围区域。点击区域标签后拖动边框和控制点即可调整，**重置篮网区**会恢复系统建议。

### 确认分析与进度

![深色主题确认分析](../capture/screenshot-20260813-145844.png)

确认视频、范围、两个检测区域和分析模式后，点击**确认配置并开始分析**。点击**上一步**可以修改配置。

![深色主题分析进度](../capture/screenshot-20260813-145855.png)

进度页显示阶段、进度和耗时。任务可能经过代理生成、快速扫描、候选生成、精细分析和候选封面准备。右上角**取消**会停止当前任务；取消或失败不会清空旧候选。

### 审核工作台

审核工作台优先保证视频空间：左侧播放原视频或审核代理，右侧显示候选列表。

![深色主题审核工作台：保留候选](../capture/screenshot-20260813-150054.png)

- 点击候选卡片切换片段；切换不会改变审核结果。
- 候选默认保留。点击绿色**勾选**保留，点击**叉号**排除。
- 顶部可以切换**候选预览/原视频**，并打开或关闭标注层。
- 播放栏支持播放、暂停、拖动进度、快退/快进、倍速、重播和循环。
- 证据区域显示置信度、轨迹评分、篮网运动、反弹判断和系统说明。

![深色主题审核工作台：排除候选](../capture/screenshot-20260813-150109.png)

被排除的候选仍留在列表里，方便恢复或复核。筛选器支持全部、待审核、已确认、已排除和低置信度；再次点击勾选即可恢复导出资格。

### 调整、标记和补漏

![深色主题调整片段范围](../capture/screenshot-20260813-150120.png)

点击**调整片段范围**，拖动时间轴两端或直接填写时间。**恢复默认**回到事件前 6 秒、事件后 3 秒的默认窗口；**取消**放弃修改，**应用**保存。它只改变导出窗口，不修改原视频。

![深色主题球员标记](../capture/screenshot-20260813-150302.png)

在候选卡片中选择已有球员，或点击**新建球员**创建标签。支持批量设置，导出时可按球员筛选；标签不会改变保留/排除状态。

手动补漏时切换到原视频，在事件位置暂停，点击**从原视频当前时间补漏候选**，设置范围后点击**加入候选**。手动候选默认保留，重新分析时不会被新批次静默删除。备注用于记录球员、动作或待复核原因；审核操作支持撤销和 `Cmd/Ctrl+Z`。

常用快捷键：`Space` 播放/暂停，`R` 重播，`L` 循环，`A` 切换标注，`↑/↓` 切换候选，`←/→` 快退/快进 2 秒，`C/Enter` 保留，`X/Backspace` 排除。

### 导出

![深色主题导出集锦](../capture/screenshot-20260813-150335.png)

导出页显示当前保留候选数量和总时长。可以按**全部球员**或具体球员筛选：

- **合并导出**：按事件时间排序，生成一条集锦；重叠片段会合并处理。
- **分别导出**：为每个候选生成独立视频。

已排除候选不会进入结果。导出期间审核写入会暂时锁定；导出完成或失败后返回审核仍可继续修改。结果页显示输出路径、片段数、总时长、耗时、文件大小和编码，并提供**打开目录**。

### 主题

项目推荐深色主题，本页截图也以深色为主。白色主题只改变颜色，不改变页面、按钮和交互：

![白色主题项目首页](../capture/screenshot-20260813-150603.png)

![白色主题审核空状态](../capture/screenshot-20260813-150911.png)

## 5. 常见问题

### 启动和插件

**找不到 Python 或 Engine？** 先运行 `scripts/check_runtime.py`，再用 `BHE_REPO_ROOT` 和 `BHE_PYTHON` 显式指定路径。发布 `.app` 应把运行时放在 `Contents/Resources/runtime`，不能依赖开发机绝对路径。

**macOS 提示 `media_kit_libs_macos_video`、`media_kit_video` 不支持 Swift Package Manager，需要处理吗？** 这是插件集成方式提示，不等于当前构建失败。只要 `flutter build macos`、Xcode 和播放功能正常，可以先记录。只有升级为构建错误、项目切换 SPM 或实际构建失败时，再升级插件并重新执行构建和测试；不要为了消除提示删除视频插件。

**为什么模型找不到？** 完整源码默认包含 `models/bball_model.pt`。精简包、手动删除模型或自定义路径错误都会导致 `MODEL_LOAD_FAILED`。Engine 不会静默下载未知权重。

**为什么要装 FFmpeg 和 FFprobe？** FFprobe 读取视频信息，FFmpeg 负责代理、预览和导出。

### 分析、审核和导出

**分析完成但候选为空？** 依次检查原视频播放、模型类别、ROI、分析范围、视频编码和 Engine 错误码。先扩大 ROI、缩短范围并用标准模式跑一个小样本。

**候选很多或一个片段很长？** 候选是事件窗口，不是最终片段。检查事件时间，再在工作台调整起止点。ROI 过大、时间戳异常或误检都可能造成这个现象。

**分析过程中能否导出或换模式？** 同一项目一次只运行一个重型分析或导出任务。分析时可以查看旧候选，但导出入口会锁定；换模式前先取消分析。

**点击导出后为什么不能修改？** 导出会重新读取当前数据库状态，并暂时锁定影响本次导出的候选，避免导出文件和界面状态不一致。完成或失败后可以继续修改。

### 文件、数据和隐私

**原视频被移动怎么办？** 用**重新定位视频**选择新路径。应用会校验时长、尺寸和快速指纹；不匹配时需要重新校准 ROI 并分析。

**哪些项目文件可以清理？** 代理、检测缓存和失败任务临时目录通常可以重建。不要自动删原视频、`project.db`、审核记录和用户要保留的导出文件。

**审核数据会上传吗？** 不会。`scripts/export_review_dataset.py` 只在本地读取数据库并写出 JSONL/CSV；输出可能包含真实路径、备注和球员标签，不要提交到 Git。

### 移动端和发布

移动端不启动桌面 Python Engine。Android 没有 `libbhe_runtime.so` 或 `libonnxruntime.so` 时会返回 `NATIVE_RUNTIME_UNAVAILABLE`，不会生成伪造候选。iOS 的项目、播放、审核和导出可用，本地分析仍需要 Rust 静态库、ONNX Runtime XCFramework 和 Runner 链接。

`flutter build macos` 成功不等于可以直接把 `.app` 发给别人。还要准备便携 Python、FFmpeg/FFprobe、授权明确的模型、第三方 notices、签名、公证和干净机器验收。发布边界见 [`RELEASE.md`](RELEASE.md)。

## 6. macOS 以外的开发入口

### Windows 兼容路径

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe scripts\check_runtime.py `
  --root . `
  --python .venv\Scripts\python.exe `
  --model models\bball_model.pt
cd apps\desktop
flutter pub get
flutter run -d windows
```

Windows 目前属于兼容路径，仍需自行准备 `ffmpeg.exe`、`ffprobe.exe`、Flutter Windows 工具链和可用模型。

### 移动端开发

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Android 原生分析主要验证 `arm64-v8a`。准备 Android NDK、Rust target 和 ONNX Runtime 后，再运行 `scripts/build_mobile_runtime.sh`。iOS 本地分析还需要 `scripts/build_mobile_ios_runtime.sh` 生成的 Rust 静态库、ONNX Runtime XCFramework 和 Runner 接入。

### 单独调试 Engine

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

Engine 的 stdout 只输出业务 JSONL，诊断日志写 stderr。SQLite 契约和完整协议见 [`ARCHITECTURE.md`](ARCHITECTURE.md)；开发命令和打包边界见 [`DEVELOPMENT.md`](DEVELOPMENT.md)。
