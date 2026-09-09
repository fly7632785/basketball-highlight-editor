# 移动端硬件推理加速实施计划

> 用途：断点续跑与验收记录。代码已实现不等于已验证；真机数据必须回填本文件。
> 当前分支：`main`
> 创建日期：2026-09-07

## 背景

- 移动端分析耗时以模型推理为主导：粗扫 = 时长 × 5fps 的 640 全量推理（30 分钟视频约 9000 次），桌面历史数据中粗扫占总耗时 80.8%。
- 当前 Android 固定 XNNPACK + 2 线程；iOS 固定 CPU + 默认 1 线程，无任何硬件 EP。
- Rust 侧 Android EP 分支（NNAPI fp16 / QNN / XNNPACK）已存在并被 `--features android-ep` 编译（`build_mobile_runtime.sh`），但从未被调用。

## 已确认的平台事实（2026-09-07 实测）

| 项 | 结果 | 验证方式 |
| --- | --- | --- |
| Android `libonnxruntime.so` 含 NNAPI | 是（133 处符号） | `strings \| grep -ci nnapi` |
| Android `libonnxruntime.so` 含 XNNPACK | 是（52 处符号） | 同上 |
| iOS xcframework 含 XNNPACK | **否（0 处）** | `strings` 检查 `dist/mobile-ios-runtime/.../ios-arm64/onnxruntime.framework` |
| iOS xcframework 含 CoreML | 是（19 处符号） | 同上 |
| iOS 静态库构建 | `scripts/build_mobile_ios_runtime.sh`，当前不带任何 feature | 脚本第 34 行 |
| ort 2.0.0-rc.13 CoreML API | `ort::ep::CoreML`，`ComputeUnits::{All, CPUAndNeuralEngine, CPUAndGPU, CPUOnly}`，`with_model_cache_dir` | crate 源码 |

结论：**iOS 路线必须是 CoreML**（XNNPACK 不在 xcframework 里，启用 `ort/xnnpack` feature 无效）。

## 方案

### A. Android：NNAPI 自动探测（核心）

1. Dart 端 `executionProvider` 改传 `auto`。
2. `auto` 首次按设备与模型执行一次短基准测试，后续复用缓存：
   - `XNNPACK FP32 × batch 1/4`；
   - `NNAPI FP32（禁用 NNAPI CPU）× batch 1/4`；
   - `NNAPI FP16（禁用 NNAPI CPU）× batch 1`；
   - 检测数量或峰值置信度与 XNNPACK 基线不一致的配置不参与选择。
3. 粗扫 session 不再写死 `xnnpack`，与精筛共用探测结果。
4. coarse/fine summary 日志带上实际 EP。

### B. iOS：CoreML EP + 线程数

1. `Cargo.toml` 增加 `ios-ep = ["ort/coreml"]`。
2. `lib.rs` 增加 iOS EP 分支：`auto|coreml` → `CoreML`，使用 `ComputeUnits::All + MLProgram + FastPrediction`。
3. `AppDelegate` 两个 session config 补 `intra_threads: 2`。
4. Dart 端 iOS 也传 `auto`（由 Rust 映射 CoreML）。
5. `build_mobile_ios_runtime.sh` 加 `--features ios-ep`。
6. Xcode xcconfig 链接 `-framework CoreML`。

### C. 后置项（本轮不做，按数据决定）

- QNN（需 per-SoC HTP 库与许可，Android）
- CoreML `CPUAndGPU` / fp16 档位 sweep、ANE（需 fp16 模型）
- Android intra_threads sweep（2/4/6）
- iOS 粗扫字段 bug 修复与窗口化（独立任务）

### D. Batch 前置条件

- 移动端模型已从同一 `bball_model.pt` 重新导出为动态 Batch ONNX：
  `batch × 3 × height × width`。
- 固定 Batch=1 模型与动态模型在相同随机输入上的输出逐元素一致：
  `max_abs_delta=0.0`、`mean_abs_delta=0.0`。
- 动态模型对 16 个真实代理视频帧执行 Batch=4 与逐帧推理，在
  `0.05/0.10/0.20/0.50` 四个置信度门限下检测数量全部一致；原始输出
  `max_abs_delta=0.0015564`，未跨越当前检测门限。
- Android JNI 继续逐帧借用 YUV plane，Rust 在会话内缓存预处理帧并按
  Batch 推理；检测结果严格按时间顺序回放到轨迹状态。Batch 执行失败后，
  当前会话永久切换为单帧，避免每批重复失败。

## 验收门槛（换 EP / fp16 必须全过）

```text
A. box 层：~200 帧冻结帧集，双 EP 输出对比：IoU≥0.9 配对率、class 一致、conf delta 分布
B. 延迟层：p50/p95 单帧 + 连续 3 分钟真实粗扫（抓热降频 p95）
C. 决策层：完整标注视频，候选数、event_ms ≤300ms、verdict 不变（compare_cross_platform_replay.py）
```

runtime probe 已内置 A 层的简化守门（检测数量一致性）；完整 A/B/C 需真机执行。

## 进度跟踪

| # | 任务 | 状态 | 备注 |
| --- | --- | --- | --- |
| 1 | 计划文档沉淀 | ✅ 2026-09-07 | 本文件 |
| 2 | 平台事实核查（NNAPI/CoreML 符号） | ✅ 2026-09-07 | 见上表 |
| 3 | Android：Dart 传 auto | ✅ 2026-09-07 | |
| 4 | Android：auto EP 选择 + 粗扫统一 | ✅ 2026-09-07 | NNAPI 实际加速比待真机确认 |
| 5 | iOS：Cargo ios-ep + lib.rs CoreML 分支 | ✅ 2026-09-07 | cargo check 通过 |
| 6 | iOS：AppDelegate intra_threads + xcconfig CoreML | ✅ 2026-09-07 | |
| 7 | iOS：构建脚本加 ios-ep | ✅ 2026-09-07 | |
| 8 | 静态验证（flutter analyze / cargo check） | ✅ 2026-09-07 | 见变更记录 |
| 9 | Android 真机：probe 结果 + NNAPI 加速比 | 🟡 已安装待触发 | Profile APK 已安装；开始一次分析后读取 `BHE-InferenceTuner` 日志 |
| 10 | iOS 真机：CoreML 加速比 + box 对比 | 🟡 构建通过待真机 | Rust device/simulator 静态库与 Runner simulator 均已构建 |
| 11 | 完整 A/B/C gate 回放 | ⏳ 待设备 | 冻结帧集 + 30min 真值视频 |
| 12 | 动态 Batch ONNX 导出与 Batch=1 等价验证 | ✅ 2026-09-08 | 输出 delta 为 0 |
| 13 | MediaCodec 输入队列预填充 | ✅ 2026-09-08 | 解码器不再每轮只喂一个 sample |
| 14 | Rust 会话内 YUV Batch 推理 | ✅ 2026-09-08 | 默认 Batch=4；支持 1-8；失败回退单帧 |
| 15 | Android 自动测速与按设备缓存 | ✅ 2026-09-08 | 自动选择 NNAPI/XNNPACK 与 Batch；包含简化检测一致性门禁 |
| 16 | Runtime 后端与阶段耗时诊断 | ✅ 2026-09-08 | 输出注册 EP、精度、Batch 回退、session 创建和 coarse/fine FPS |
| 17 | QNN HTP | ⏳ 缺少 SDK | 当前 APK 未包含 Qualcomm QNN SDK/HTP 库，不能宣称已启用 NPU |

## 变更记录

### 2026-09-07

- 确认 Android ORT full 包含 NNAPI/XNNPACK；确认 iOS xcframework 仅含 CoreML，iOS 路线由 XNNPACK 改为 CoreML。
- `apps/mobile/lib/native_analysis_engine.dart`：`executionProvider` 统一传 `auto`。
- `AnalysisTaskManager.kt`：粗扫与精筛使用同一 `auto` EP 配置；粗扫采样率与 PC 一致为 5fps，精筛沿用项目配置帧率。
- `packages/bhe_runtime/Cargo.toml`：新增 `ios-ep = ["ort/coreml"]`。
- `packages/bhe_runtime/src/lib.rs`：新增 `#[cfg(all(target_os = "ios", feature = "ios-ep"))]` CoreML 分支（CPUAndNeuralEngine、`coreml_cache_dir` 可选透传）；`RuntimeConfig`/`RuntimeSession` 增加 `coreml_cache_dir` 字段。
- `apps/mobile/ios/Runner/AppDelegate.swift`：粗扫/精筛 config 补 `intra_threads: 2` 与 `coreml_cache_dir`。
- `apps/mobile/ios/Flutter/{Debug,Release}.xcconfig`：`OTHER_LDFLAGS` 增加 `-framework CoreML`。
- `scripts/build_mobile_ios_runtime.sh`：构建加 `--features ios-ep`。
- 验证：`flutter analyze`（mobile）通过；Rust `cargo check --features dynamic-onnx` 通过；`cargo check --target aarch64-linux-android --features dynamic-onnx,android-ep` 与 `--target aarch64-apple-ios --features ios-ep` 通过（待真机链接确认）。

### 2026-09-08

- Android 新增 `InferenceTuner`：首次分析比较 XNNPACK、NNAPI FP32/FP16 与 Batch 1/4，选择最快且通过简化检测一致性检查的配置并按设备、模型缓存。
- NNAPI 测速使用 `CPU_DISABLED`，避免把 NNAPI reference CPU 误认为硬件加速；显式 EP 注册失败会直接淘汰该测速项。
- Runtime 新增 `bhe_runtime_session_info`，日志可读取注册后端、精度、Batch 状态与 Session 初始化耗时。
- Android 粗扫每 60 帧输出墙钟 FPS 与 native FPS；精筛按窗口输出相同指标。
- iOS CoreML EP 已接入并重新构建 device/simulator Rust 静态库；`flutter build ios --simulator --debug --no-pub` 通过。
