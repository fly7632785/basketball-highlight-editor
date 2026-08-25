# 常见问题

**中文** · [English](FAQ.en.md)

## 运行和环境

### Q1：启动时提示找不到 Python 或 Engine，怎么办？

在仓库根目录先运行：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model models/bball_model.pt
```

开发环境可以显式指定：

```bash
BHE_REPO_ROOT="/path/to/basketball-highlight-editor" \
BHE_PYTHON="/path/to/basketball-highlight-editor/.venv/bin/python" \
flutter run -d macos
```

发布 `.app` 应把 Engine 和 Python 放进 `Contents/Resources/runtime`，不能依赖维护者本机绝对路径。查找规则见 [`GETTING_STARTED.md`](GETTING_STARTED.md)。

### Q2：`media_kit_libs_macos_video`、`media_kit_video` 不支持 Swift Package Manager 是什么？需要处理吗？

这是 macOS 插件集成方式的兼容性提示，不等于当前应用启动失败。只要 `flutter build macos`、Xcode 构建和视频播放正常，当前可以记录后继续开发。

需要处理的时机：

- Flutter 将来把提示升级为构建错误；
- 项目切换到 Swift Package Manager；
- `flutter build macos` 或 Xcode 实际失败。

届时优先升级到支持 SPM 的插件版本，并重新执行 `flutter pub get`、`flutter analyze`、`flutter test` 和 macOS 构建。不要为了消除警告直接删除视频插件。

### Q3：为什么运行时检查找不到模型？

确认路径和文件名：

```text
models/bball_model.pt
```

也可以传入自定义权重：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python \
  --model /absolute/path/to/your-model.pt
```

模型必须与当前脚本的类别命名和格式兼容，并且你拥有使用权。Engine 不会从未知地址自动下载模型。

### Q4：为什么必须安装 FFmpeg 和 FFprobe？

FFprobe 读取视频元数据，FFmpeg 负责代理、预览和导出。检查：

```bash
command -v ffmpeg
command -v ffprobe
ffmpeg -version
ffprobe -version
```

Homebrew 版本适合本机开发；分发包需要自包含或静态构建，并单独核对许可证。打包说明见 [`RELEASE.md`](RELEASE.md)。

### Q5：Flutter 测试中出现媒体插件初始化提示，是失败吗？

不一定。以命令退出码、`flutter analyze` 结果和测试断言为准。若测试退出码非零或出现真实构建错误，再按完整错误继续排查。

## 分析和候选

### Q6：分析完成了，但候选列表为空，正常吗？

空列表不一定是 UI 故障。按顺序检查：

1. 原视频能否正常播放；
2. 模型是否包含当前流程需要的篮球/篮筐类别；
3. ROI 是否覆盖篮筐及篮球运动区域；
4. 分析范围是否误设得过短；
5. 视频编码或模型是否不兼容；
6. Engine 是否报告 `NO_BALL_DETECTIONS`、`MODEL_LOAD_FAILED` 或 `ANALYSIS_FAILED`。

先扩大 ROI、缩短范围并使用标准模式验证小样本。如果快速模式没有候选，不要静默把它当成完整结果，改用标准模式重跑。

### Q7：候选很多，或者一个候选持续几分钟，怎么办？

候选是事件窗口，不是已经剪好的最终片段。先确认事件时间，再在审核工作台调整片段起止点。ROI 过大、视频时间戳异常或模型把球员/篮筐运动误判为篮球事件，都可能导致候选过多或窗口过长。

不要直接修改 JSON 或 SQLite；通过 UI 修改以保持审核和导出状态一致。

### Q8：快速模式和标准模式有什么区别？

标准模式包含原视频回源精筛，质量优先；快速模式使用低成本代理并跳过精筛，速度优先，可能漏检。两种模式的审核、手动调整和导出规则相同。详情见 [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md)。

### Q9：分析过程中能不能导出或切换模式？

一个项目同时只运行一个重型分析或导出任务。分析期间可以继续查看和审核旧候选，但导出入口会锁定；切换模式前先取消当前分析。新结果成功前旧候选不会被清空。

### Q10：为什么我点击导出后，审核区不能修改？

导出任务会重新读取当前数据库状态，并锁定影响本次导出的候选写入，避免导出内容和界面显示不一致。导出完成或失败后可以继续修改并发起下一次导出。

## 视频、项目和数据

### Q11：原视频被移动或删除了怎么办？

项目默认只保存原视频路径和元数据，不复制原视频。文件移动后使用“重新定位视频”选择新路径；如果时长、分辨率或指纹不匹配，应重新校准 ROI 并重新分析。

### Q12：项目目录里哪些内容可以清理？

代理、检测缓存和失败任务临时文件通常可以重建。不要自动删除：

- 原始视频；
- `project.db`；
- 用户审核记录；
- 用户明确保留的导出文件。

目录生命周期见 [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md)。

### Q13：为什么模型、视频和开发截图不应该提交到 GitHub？

它们可能包含未核验版权、球员个人信息、真实路径或大体积二进制。公开仓库应只保留源码、文档和已确认可以公开的演示素材。模型和数据规则见 [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md)。

### Q14：审核数据导出会上传数据吗？

不会。`scripts/export_review_dataset.py` 只在本地读取项目数据库并写 JSONL/CSV。输出可能包含真实路径、备注或球员标签，不要提交到 Git。

## 移动端

### Q15：移动端为什么不启动桌面 Python Engine？

这是有意的边界：桌面端使用 Python Engine 复用长视频分析链路；移动端使用 Flutter 状态层、平台媒体 API 和 Rust/ONNX Runtime，避免在手机上依赖桌面 Python 环境。两端的项目/候选数据模型通过 `packages/bhe_core` 共享。

### Q16：Android 点击分析提示 `NATIVE_RUNTIME_UNAVAILABLE` 怎么办？

确认 APK 中存在当前 ABI 的 `libbhe_runtime.so` 和 `libonnxruntime.so`，并按 [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) 重新构建。没有这些原生库时，UI/导出可以工作，但分析明确失败，不会生成伪造候选。

### Q17：iOS 为什么可以播放和导出，但不能分析？

iOS 的项目、媒体和导出 channel 已接入；本地分析还需要 Rust 静态库、ONNX Runtime XCFramework 和 Runner 链接配置。缺少这些产物时应保留 `NATIVE_RUNTIME_UNAVAILABLE`，不要把构建物描述为完整 AI 分析版本。

## 构建和发布

### Q18：`flutter build macos` 成功后是不是就能发给别人？

不是。还需要便携 Python、依赖、FFmpeg/FFprobe、授权明确的模型、许可证 notices、签名、公证和干净 macOS 验证。详见 [`RELEASE.md`](RELEASE.md)。

### Q19：为什么没有立刻把桌面 Python Engine 全部换成 Rust？

当前主要成本在模型推理、视频解码和 FFmpeg，而不是 JSONL 服务本身。先稳定桌面协议、SQLite 和审核语义，再逐步替换内部实现；移动端已经有独立的 Rust/ONNX 路径。Rust 迁移不会自动解决所有桌面性能问题。

### Q20：如何报告安全问题？

不要在公开 Issue 中发布可利用细节、视频样本、密钥或个人数据。请阅读根目录 [`SECURITY.md`](../SECURITY.md)，使用 GitHub 私密漏洞报告入口（如果仓库已启用）或仓库公开的安全联系方式。
