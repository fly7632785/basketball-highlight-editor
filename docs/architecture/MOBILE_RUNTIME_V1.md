# BHE Mobile Runtime V1

## 当前边界

`apps/mobile` 是独立的 Flutter 应用，不启动桌面 Python Engine，也不依赖桌面项目。Flutter 层负责项目状态、项目包、视频播放、ROI 编辑和审核流程；平台层负责媒体操作，原生 Runtime 负责移动端推理。

当前状态：

- Flutter UI、项目持久化、项目包导入/导出和分析进度恢复路径已实现；
- Android 已实现视频抽帧、进度回传、取消、片段导出，以及 Rust/ONNX JNI seam；当前主要验证 `arm64-v8a`；
- Android 原生 `.so` 和 ONNX Runtime 是构建输入，不应把未核验的开发产物当作公开发布附件；
- iOS 的项目、播放、审核和导出 channel 已接入；本地分析仍需要 Rust 静态库、ONNX Runtime XCFramework 和 Runner 链接；
- 缺少原生库时统一返回 `NATIVE_RUNTIME_UNAVAILABLE`，不会用空候选掩盖 Runtime 缺失。

## 原生边界

- `MobileAnalysisEngine`：抽象移动端推理和候选生成；
- `NativeAnalysisEngine`：Flutter 与平台分析 channel 的桥接；
- `MobileExportEngine`：移动端视频片段导出；
- `com.bhe.bhe/mobile_media`：视频导出、保存到媒体库等平台媒体操作；
- `com.bhe.bhe/mobile_analysis`：启动/取消分析；
- `com.bhe.bhe/mobile_analysis_progress`：分析进度事件；
- `packages/bhe_runtime/include/bhe_runtime.h`：Rust C ABI 边界。

平台实现必须显式报告参数错误、Runtime 缺失、模型加载失败、取消和导出失败。不要返回空数组来伪装分析成功。

## 模型与输入

桌面模型转换为移动 ONNX 的入口：

```bash
.venv/bin/python scripts/export_mobile_model.py \
  --model models/bball_model.pt \
  --output models/bball_model.onnx
```

转换产物需要分别验证：

- 桌面模型与 ONNX 数值/候选一致性；
- Android/iOS ONNX Runtime 加载；
- Rust 输入的图像尺寸、归一化、类别映射和输出格式；
- 真机长视频的内存、温度、耗时和取消行为。

模型权利独立于源码许可证，见 [`../MODEL_AND_DATA_LICENSES.md`](../MODEL_AND_DATA_LICENSES.md)。

## Android 构建

当前支持的本地入口目标为 `arm64-v8a`：

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
rustup target add aarch64-linux-android
scripts/build_mobile_runtime.sh
cd apps/mobile
flutter build apk --release
```

`BHE_ORT_ANDROID_DIR` 必须包含：

```text
arm64-v8a/libonnxruntime.so
```

脚本会检查 Rust、Android NDK、Rust target 和 ONNX Runtime 文件；缺少任一项时失败，而不是生成看似支持分析、实际不能推理的 APK。增加其他 ABI 前，先验证对应 ONNX Runtime 二进制和设备性能。

## iOS 构建

Rust 静态库和 C ABI 头文件生成入口：

```bash
export BHE_ORT_IOS_XCFRAMEWORK="/path/to/onnxruntime.xcframework"
scripts/build_mobile_ios_runtime.sh
```

脚本要求 `aarch64-apple-ios`、`aarch64-apple-ios-sim` targets 和 ONNX Runtime XCFramework，生成 device/simulator 静态库与头文件。它不会自动把产物写入 Xcode 工程，也不会在缺少依赖时生成不完整产物。

完成真正 iOS 分析发布前还要：

1. 将静态库、头文件和 XCFramework 接入 Runner；
2. 验证 Debug/Release 的 linker search path 和 framework flags；
3. 在真机和模拟器分别验证模型加载、帧抽取、取消和导出；
4. 核对静态链接和发布物的许可证 notices。

## 媒体和项目包行为

- iOS 使用 `AVAssetExportSession` 导出 MP4 片段；
- Android 使用 `MediaExtractor` 和 `MediaMuxer` 复制音视频轨道；
- 项目包保存项目设置、视频元数据、ROI、候选、审核状态和标签，不复制原始视频；
- 重新打开项目时必须重新关联原视频；
- 重新关联会校验时长、尺寸和由文件头/尾/大小计算的快速 SHA-256 指纹，避免完整读取多 GB 视频；
- 保存到媒体库需要用户授权，失败必须向 UI 返回明确错误。
