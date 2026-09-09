# 移动端与 PC 算法对齐及 App 性能优化执行记录

> 用途：断点续跑和验收记录。代码已实现不等于已验证。
> 当前分支：`main`
> 当前阶段：阶段 7（项目包与性能实现收口，待真机验收）
> 最后更新：2026-08-31

## 总目标

- PC 与 Android/iOS 共享时间、坐标、ROI、检测后处理、轨迹、篮网证据、候选和 verdict 语义。
- Android/iOS 仅在解码、像素读取、内存传输、线程调度和推理 Provider 使用平台优化。
- 用真实视频和真机数据验证，不以编译成功代替跨端一致性。

## 固定边界

1. 不通过单纯降低全局 FPS 换取性能。
2. 两阶段粗扫/精扫在 PC 与 App 采样契约统一前不进入标准模式。
3. Android 第一版只保证 `arm64-v8a`。
4. iOS 目标为 device arm64 与 Apple Silicon simulator。
5. 每个逻辑阶段单独验证；真机、Flutter、ORT 不可用时明确记录阻塞。
6. 桌面生成插件注册文件与算法/移动端改动隔离处理。

## 当前工作区基线

- 分支：`main`
- 未提交变更：33 个已跟踪文件、5 个新增文件
- 工作区规模：约 4544 行新增、696 行删除
- `git diff --check`：通过（2026-08-30）
- Python 测试：`218 passed`（2026-08-30）
- Rust 测试：使用本机 ONNX Runtime 动态库通过，34 passed
- Flutter：使用仓库内 `.tooling/flutter/bin/flutter`；Mobile analyze/test 已通过；Desktop analyze/test 已通过
- Android 真机：未验证
- iOS 真机：未验证
- 真实视频 PT/ONNX 和 Python/Rust 回放：本地检测记录回放通过 1 候选；设备 ONNX 全链路未完成
- Android Release APK：此前任务超时，未获得 APK 输出；Debug APK 构建和 JNI/Rust stride 符号构建通过
- iOS Simulator Debug：构建通过；device/Release/真机未验证

## 变更归属

### 跨端算法与回放（当前已有改动）

- `src/basketball_highlight/sampling.py`
- `src/basketball_highlight/events.py`
- `src/basketball_highlight/roi.py`
- `packages/bhe_runtime/src/lib.rs`
- `packages/bhe_core/lib/src/analysis_engine.dart`
- `packages/bhe_core/lib/src/models.dart`
- `scripts/scan_video.py`
- `scripts/refine_candidates.py`
- `scripts/detect_auto_roi.py`
- `scripts/export_cross_platform_replay.py`
- `scripts/compare_cross_platform_replay.py`
- `scripts/compare_pt_onnx_frame.py`
- `tests/test_cross_platform_replay.py`
- `tests/test_sampling.py`
- `docs/architecture/CROSS_PLATFORM_ANALYSIS_CONTRACT_V1.md`
- `docs/architecture/CROSS_PLATFORM_SAMPLE_TIMING.md`

### Android/iOS 桥接（当前已有改动）

- `apps/mobile/android/app/src/main/cpp/bhe_runtime_jni.cpp`
- `apps/mobile/android/app/src/main/kotlin/com/bhe/bhe_mobile/FramePipeline.kt`
- `apps/mobile/android/app/src/main/kotlin/com/bhe/bhe_mobile/MainActivity.kt`
- `apps/mobile/android/app/src/main/kotlin/com/bhe/bhe_mobile/NativeRuntime.kt`
- `apps/mobile/ios/Runner/AppDelegate.swift`
- `apps/mobile/ios/Runner/BheRuntime.h`
- `apps/mobile/lib/native_analysis_engine.dart`

### Flutter 移动端业务（当前已有改动）

- `apps/mobile/lib/mobile_app_state.dart`
- `apps/mobile/lib/mobile_ui.dart`
- `apps/mobile/test/candidate_model_test.dart`

### 需要隔离确认的桌面生成文件

- `apps/desktop/macos/Flutter/GeneratedPluginRegistrant.swift`
- `apps/desktop/windows/flutter/generated_plugin_registrant.cc`
- `apps/desktop/windows/flutter/generated_plugins.cmake`

这些文件当前表现为插件注册内容被删除，尚未确认是否由 Flutter 生成器、依赖状态或其他 Agent 引起；不得直接归入移动端算法完成项。

## 阶段状态

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| 0. 工作区收口和基线 | 已验证 | 文档已建立；桌面生成插件文件已恢复；静态检查通过 |
| 1. PC/App 底层算法契约和回放 | 已实现待验证 | 采样、Rust 判定、回放脚本已有；缺真实 PT/ONNX、Rust ORT 和样本报告 |
| 2. Android 稳定可用 | 已实现待验证 | 顺序解码、取消、Native Runtime 链路已有；Debug 构建通过；Release 构建和真机证据待完成 |
| 3. iOS 本地分析闭环 | 已实现待验证 | Swift/C ABI/Rust/ORT 配置已有；Simulator Debug 构建通过；device/Release/真机证据待完成 |
| 4. App 原生性能优化 | 已实现待验证 | Android 已改为 Bitmap NDK lockPixels + stride 直传；iOS 仍为 CGImage/Data；缺真机性能数据 |
| 5. 移动端审核能力 | 已实现待验证 | 当前基础审核、批量时长、证据展示已有；Undo、多选、筛选仍待真机/交互验收 |
| 6. 移动端导出 | 已实现待验证 | 分别导出取消已接入 Android/iOS；移动端重试、历史和合并导出仍待补齐 |
| 7. PC/App 项目包互通 | 已实现待验证 | App 已输出 v2 portable manifest 并兼容 v1；PC 端导入/导出转换仍待接入；App schema 回归测试通过 |
| 8. 完整验收 | 待开始 | 依赖前序阶段和真实设备/样本 |

## 下一次继续工作

1. 读取本文件、`git status --short --branch`、`git diff --stat`。
2. 先完成阶段 0 的文件归属和静态基线，不改无关桌面功能。
3. 然后优先完成阶段 1 的可执行回放检查与比较器测试。
4. 没有 ORT、Flutter、真机或真实样本时，将结果标为阻塞，不伪造通过。

## 验收命令

```bash
.venv/bin/python -m pytest -q
cargo fmt --manifest-path packages/bhe_runtime/Cargo.toml --check
cargo test --manifest-path packages/bhe_runtime/Cargo.toml
cd apps/mobile && flutter analyze && flutter test
cd apps/desktop && flutter analyze && flutter test
git diff --check
```

## 证据记录

### 2026-09-03

- Android YUV 路径现在按视频 rotation metadata 将显示坐标映射回编码平面；旋转后的 ROI、检测框和粗扫候选使用同一坐标系。
- Android 正式分析请求补传独立的 `rimRoi`，不再把扩大的分析区误用作物理篮筐框。
- iOS `AVAssetReader` 改为使用带 `preferredTransform` 的 `AVAssetReaderVideoCompositionOutput`，与自动 ROI 的显示方向一致；Android/iOS 都会拒绝未完整解码的采样帧。
- Android/iOS 合并导出先合并重叠区间；Android 导出 buffer 按 sample 大小扩容，避免高码率 sample 被固定 16MB 限制截断。
- 移动端模型复制改为按资源真实大小校验，并通过临时文件写完后替换，避免半文件被当作可用模型。
- Android 删除未被调用、且会与 `AnalysisTaskManager` 分叉的 `analyzeVideoLegacy()`，分析入口只保留前台服务任务链。
- iOS 不再因进入后台主动取消分析；系统仍可能暂停应用，后台持续运行与真正断点续跑仍需设备级方案验证。
- 验证：Python `219 passed`；Rust `35 passed`；Mobile `flutter analyze` 无问题、Flutter tests 全部通过；Android `assembleDebug` 成功；iOS device Release 无签名构建产物已生成。

### 2026-08-31

- Rust：使用本机 ONNX Runtime 动态库，`cargo test --features dynamic-onnx`：34 passed。
- Rust：`cargo build --features dynamic-onnx --bin bhe-runtime`：通过。
- Mobile：`flutter analyze`：通过；`flutter test`：6 tests passed。
- Desktop：`flutter analyze`：通过；`flutter test`：145 tests passed。
- Python：218 passed。
- PT/ONNX 固定帧工具在 `capture/recording-demo.mp4@0ms` 执行成功，当前帧无检测，输入 tensor shape 为 `[1,3,640,640]`。
- Python/Rust 决策回放使用 `bball_model_roi_full_10fps.json` 的 2777 条检测记录，导出出 1 个候选，结果 `matched=1`、`match_rate=1.0`、事件时间差 0ms。
- Android/iOS 导出取消接口已接入 Flutter、Android `AtomicBoolean` 和 iOS `AVAssetExportSession.cancelExport()`；尚未在真机验证。
- 项目包编码升级为 v2 portable manifest，解码兼容 v1；尚未完成 PC 端双向导入/导出。
- Android 已使用 NDK `AndroidBitmap_lockPixels` + row stride 直传 Rust；Rust 增加 stride-aware raw frame FFI；Android Debug 构建通过。
- 2026-08-31 真机日志定位：不是 Bitmap 不可锁，而是 `FramePipeline` 在选择当前帧后错误回收了同一个 Bitmap；日志出现 `Called getWidth()/getHeight() on a recycle()'d bitmap`，随后 JNI 返回 `-2`。已移除该错误回收，后续复测未再出现该错误。
- 2026-08-31 真机性能日志：5 分钟分析范围生成 2850 个 10fps 目标帧；约 220 秒仅完成 12%，设备 CPU 约 104%，Native Heap 约 183MB。瓶颈为 Android `FramePipeline` 对每个 MediaCodec 输出帧执行逐像素 YUV→ARGB，即使非目标帧也付出转换成本；已改为仅在目标采样时间附近转换 Bitmap，并重新构建安装，待新一轮真机测速。
- Mobile 项目包新增 v2 portable manifest，顶层兼容 PC 风格字段，读取兼容 v1；新增 v2/v1 回归测试。
- Android/iOS 分别导出增加取消、失败清理和取消状态传递；分析任务由 Android 前台服务持有，不随 Activity 销毁而中断；iOS 不主动因进入后台取消分析。

### 2026-08-30

- Python：218 passed。
- Rust：因未设置 `ORT_LIB_PATH`/可用本机 ONNX Runtime 链接库，无法完成测试链接。
- Flutter：命令不可用。
- `git diff --check`：通过。
- 尚无真实视频回放报告、Android 真机报告、iOS 真机报告和性能基准。
