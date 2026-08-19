# BHE Mobile

`BHE Mobile` 是独立的 Flutter 移动端工程，项目数据和视频处理都在本机完成，不启动桌面 Python Engine。

## 当前能力

- 选择视频、读取视频元数据并保存项目。
- 设置分析质量、分析范围和片段时长。
- 触摸调整篮筐/篮网 ROI（感兴趣区域）。
- Android 原生抽帧、进度回传、取消分析和视频导出通道。
- Rust ONNX Runtime 会话、篮球检测、穿框几何判断、轨迹分数和基础篮网运动分数。
- 候选审核、球员标签、备注、项目包导入导出。
- 分析中断后重新打开项目可以识别并重新分析。

## 本地开发

```bash
cd apps/mobile
../../.tooling/flutter/bin/flutter pub get
../../.tooling/flutter/bin/flutter analyze
../../.tooling/flutter/bin/flutter test
../../.tooling/flutter/bin/flutter build apk --debug
../../.tooling/flutter/bin/flutter build ios --simulator --no-codesign
```

没有原生库时，Android UI 和导出仍可构建，但点击分析会明确提示
`NATIVE_RUNTIME_UNAVAILABLE`，不会返回伪造候选。

## Android 原生分析库

Android 目前支持 `arm64-v8a` 构建。先准备 Rust Android target 和 ONNX Runtime Android 库：

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
rustup target add aarch64-linux-android
../../scripts/build_mobile_runtime.sh
../../.tooling/flutter/bin/flutter build apk --release
```

`BHE_ORT_ANDROID_DIR/arm64-v8a/libonnxruntime.so` 必须存在。原生 `.so` 不提交到 Git，脚本缺少任一依赖时会直接失败。

## iOS 状态

iOS 的视频播放、项目和导出通道已经接入；本地分析 channel 当前会返回
`NATIVE_RUNTIME_UNAVAILABLE`。要启用真机分析，还需要把 Rust 静态库、ONNX Runtime XCFramework 和 iOS 视频抽帧 FFI 接入 Runner。没有这些产物时不应打包成“支持 AI 分析”的发布版本。

## 项目包

项目包只保存项目设置、视频元数据、ROI、候选、审核状态和标签，不复制原始视频。重新打开时必须重新关联原视频，App 会校验分辨率、时长和文件指纹。
