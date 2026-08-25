# BHE Mobile

`BHE Mobile` 是独立的 Flutter 移动端工程。它不启动桌面 Python Engine，项目数据和媒体处理在本机完成；移动端推理通过 Android/iOS 原生 channel 接入 Rust/ONNX Runtime。

## 当前状态

- Flutter UI、项目持久化、视频导入/播放、ROI、审核和项目包导入导出已接入；
- Android 支持原生抽帧、进度、取消、Rust/ONNX 分析、候选生成和视频导出，当前主要验证 `arm64-v8a`；
- iOS 项目、播放、审核和导出通道可用，本地分析还需要 Rust 静态库、ONNX Runtime XCFramework 和 Runner 链接；
- 缺少原生库时会返回 `NATIVE_RUNTIME_UNAVAILABLE`，不会返回伪造候选；
- 移动端真机长视频性能、模型一致性、多 ABI 和 iOS 分析仍需单独验收。

## 本地开发

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --no-codesign
```

## Android 原生分析库

当前入口只针对 `arm64-v8a`：

```bash
export BHE_ANDROID_NDK="$HOME/Library/Android/sdk/ndk/<version>"
export BHE_ORT_ANDROID_DIR="/path/to/onnxruntime-android"
rustup target add aarch64-linux-android
../../scripts/build_mobile_runtime.sh
flutter build apk --release
```

`BHE_ORT_ANDROID_DIR/arm64-v8a/libonnxruntime.so` 必须存在。Rust Runtime 和 ONNX Runtime 原生库是构建输入，不应把带个人路径或未核验授权的二进制加入公开发布物。

## iOS Runtime

```bash
export BHE_ORT_IOS_XCFRAMEWORK="/path/to/onnxruntime.xcframework"
../../scripts/build_mobile_ios_runtime.sh
```

脚本会生成 device/simulator 静态库、C ABI header 和 XCFramework 副本，但不会自动修改 Xcode 工程。完整接入状态见 [`../../docs/architecture/MOBILE_RUNTIME_V1.md`](../../docs/architecture/MOBILE_RUNTIME_V1.md)。

## 项目包

项目包只保存项目设置、视频元数据、ROI、候选、审核状态和标签，不复制原始视频。重新打开时必须重新关联原视频，App 会校验分辨率、时长和文件指纹。
