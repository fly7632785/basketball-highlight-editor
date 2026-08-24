# 常见问题

**中文** · [English](FAQ.en.md)

## 运行和环境

### Q1：启动时提示找不到 Python 或 Engine，怎么办？

先在仓库根目录检查：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

桌面端启动时可以显式指定开发环境：

```bash
BHE_REPO_ROOT="/path/to/basketball-highlight-editor" \
BHE_PYTHON="/path/to/basketball-highlight-editor/.venv/bin/python" \
flutter run -d macos
```

正式 `.app` 应把 Engine 和 Python 放入 `Contents/Resources/runtime`，不要依赖开发机绝对路径。运行时查找顺序见 [GETTING_STARTED.md](GETTING_STARTED.md)。

### Q2：`media_kit_libs_macos_video`、`media_kit_video` 不支持 Swift Package Manager 是什么？需要处理吗？

这是 Flutter 对 macOS 插件依赖管理方式的兼容性提示，不等同于当前应用启动失败。当前插件仍可使用 CocoaPods/传统插件集成路径时，可以先记录并继续验证功能。

需要处理的时机：

- Flutter 未来版本把该提示升级为构建错误；
- 项目切换到 Swift Package Manager；
- `flutter build macos` 或 Xcode 构建实际失败。

届时应优先升级到已支持 SPM 的插件版本，或联系插件维护者；不要为了消除警告直接删除视频插件。升级后必须重新运行 `flutter pub get`、`flutter analyze`、`flutter test` 和 macOS 构建。

### Q3：为什么不直接使用仓库里的 `.tooling/flutter`？

`.tooling/` 是本机开发 SDK，已被 Git 忽略，不是公开仓库依赖。公开文档优先使用 `flutter`，由开发者把兼容版本放在 `PATH`；如果本机确实使用项目外的 Flutter SDK，可用 `FLUTTER_BIN` 或直接调用绝对路径。

### Q4：为什么运行时检查找不到模型？

确认文件名和路径完全一致：

```text
models/bball_model.pt
```

也可以传入自定义模型：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model /absolute/path/to/your-model.pt
```

模型必须是当前脚本和类别命名兼容的权重，并且你有权使用。模型不随源码发布，缺失时不会自动从未知地址下载。

### Q5：为什么必须安装 FFmpeg 和 FFprobe？

FFprobe 负责读取视频时长等元数据，FFmpeg 负责生成分析代理、预览和导出片段。检查：

```bash
which ffmpeg
which ffprobe
ffmpeg -version
ffprobe -version
```

如果开发环境没有它们，按系统安装；如果发布 `.app`，不要直接复制依赖 Homebrew 动态库的版本，参考 [MACOS_PACKAGING_V1.md](MACOS_PACKAGING_V1.md)。

## 分析和候选

### Q6：分析完成了，但候选列表为空，正常吗？

空列表不一定是 UI 故障。按顺序检查：

1. 原视频能否在播放器中正常播放；
2. 模型是否真的包含 `basketball` / `hoop` 等当前流程需要的类别；
3. ROI 是否框住篮筐和篮球运动范围，而不是只框住很小的篮筐边缘；
4. 分析范围是否误设为很短；
5. 是否使用了不兼容的模型或视频编码；
6. Engine 日志是否报告 `NO_BALL_DETECTIONS`、`MODEL_LOAD_FAILED` 或 `ANALYSIS_FAILED`。

先扩大 ROI、缩短视频范围做一个小样本验证；如果标准模式有候选而快速模式没有，不要自动把快速结果当作完整结果，改用标准模式重跑。

### Q7：候选很多、一个片段持续几分钟，怎么办？

候选是模型和规则生成的事件窗口，不是已经剪好的最终片段。先在审核工作台确认事件时间，再调整片段起止点。检查 ROI 是否过大、模型是否把篮筐/球员运动当成篮球事件，以及视频是否存在时间戳异常。

不要直接修改候选 JSON 或 SQLite；通过 UI 调整，保证审核状态和导出状态一致。

### Q8：快速模式和标准模式有什么区别？

标准模式包含原视频回源精筛，质量优先；快速模式使用低成本代理并跳过精筛，速度优先，可能漏检。快速模式不是低延迟保证，也不是更准确的模式。基准数据和限制见 [research/ANALYSIS_MODES_V1.md](research/ANALYSIS_MODES_V1.md)。

### Q9：分析过程中能不能导出或切换模式？

当前规则是：一个项目同时只运行一个重型分析或导出任务。分析运行期间可以继续查看和审核旧候选，但导出入口会锁定；要切换模式，先取消当前任务，再重新分析。新结果成功写入前，旧结果不会被清空。

### Q10：为什么我点击导出后，审核区不能修改？

导出任务会重新读取当前数据库状态，并锁定会影响本次导出的候选写入，避免“正在导出时又修改片段”造成导出内容和界面不一致。导出失败可以重试；导出完成后可以继续修改，再发起下一次导出。

## 视频、项目和数据

### Q11：原视频被移动或删除了怎么办？

项目只保存原视频路径和元数据，不会复制原视频。文件移动后会显示缺失状态，使用重新定位功能选择新路径；如果文件内容或关键元数据变化，建议重新校准 ROI 后再分析。

### Q12：项目目录里哪些内容可以清理？

通常可以重建的内容包括代理、检测缓存和失败任务临时文件。不要自动删除：

- 原始视频；
- `project.db`；
- 用户审核记录；
- 用户明确保留的导出文件。

目录生命周期见 [architecture/PROJECT_LAYOUT_V1.md](architecture/PROJECT_LAYOUT_V1.md)。

### Q13：为什么 GitHub 上看不到模型、视频和截图？

这是有意设计：模型权重、真实比赛视频、标注数据和开发机截图可能包含未核验的版权、个人信息或本机路径。公开仓库只保留源码、说明和空目录使用约定；公开演示需要使用已授权素材。

### Q14：审核训练数据导出会上传数据吗？

不会。`scripts/export_review_dataset.py` 只在本地读取项目数据库并写出 JSONL/CSV。导出的文件可能含有真实路径、备注或球员信息，默认应留在本地，不要提交到 Git。

## 构建和发布

### Q15：`flutter build macos` 成功后是不是就能发给别人？

不是。Flutter `.app` 还需要便携 Python、所有依赖、FFmpeg/FFprobe、模型、许可证 notices、签名、公证和干净 macOS 验证。详见 [RELEASE.md](RELEASE.md)。

### Q16：为什么不现在把 Python Engine 换成 Rust？

当前主要耗时来自模型推理、视频解码和 FFmpeg，不是 JSONL 服务本身。V1 先稳定 Python Engine、协议和 SQLite 契约；后续可替换 Engine 内部实现，但保持协议和数据契约不变。Rust 迁移不是当前开源运行前置条件。

### Q17：如何报告安全问题？

不要在公开 Issue 中发布可利用细节、视频样本或密钥。请阅读 [SECURITY.md](../SECURITY.md)，使用 GitHub 私密漏洞报告入口（如果仓库已启用）或维护者公开的安全联系方式。
