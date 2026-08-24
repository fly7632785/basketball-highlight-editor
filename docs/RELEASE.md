# 发布指南

**中文** · [English](RELEASE.en.md)

项目发布物分成两类，必须分别验收：

1. **源码预览版**：源码、文档、测试和许可证；
2. **桌面二进制版**：额外携带 Python、依赖、FFmpeg/FFprobe、模型和 Flutter 应用。

当前仓库只应按源码预览版描述。源码构建成功不代表可以把 `.app`、APK 或模型附件当作普通用户可直接安装的发布物。

## 1. 源码公开前检查

### 应包含

- `README.md` 和 `README.en.md`；
- 入门、FAQ、开发、发布、架构和协议文档；
- `LICENSE`、`NOTICE`、`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`；
- 依赖、模型和数据授权边界说明；
- 模型、数据和截图的本地使用说明。

### 不应包含

- 未核验授权的 `.pt`、`.onnx`、`.pth`、`.bin` 或其他模型/原生运行时二进制；
- 真实比赛视频、导出片段、真实标注和未脱敏截图；
- `.venv/`、`.tooling/`、`build/`、`dist/` 和个人路径；
- API key、私钥、真实联系方式或第三方源码 checkout；
- 只在某台开发机上有效的依赖路径。

执行自动检查：

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../mobile
flutter analyze
flutter test
cd ../..
git diff --check
```

`check_open_source.py` 发现的 error 必须在公开前处理；warning 需要逐项判断并记录。当前发布阻塞项见本文第 7 节。

## 2. 授权核验

| 对象 | 必须确认 |
|---|---|
| 源码 | MIT 文件是否随发布物保留 |
| Python 依赖 | 锁定版本、许可证和 notices |
| Flutter/Dart 依赖 | `pubspec.lock` 对应版本和 notices |
| FFmpeg/FFprobe | 编译配置、LGPL/GPL 边界和 notices |
| 模型代码 | 代码许可证和再分发条件 |
| 模型权重 | 是否允许公开下载或随包分发 |
| 训练数据 | 原始和衍生数据的公开处理权 |
| 演示视频/截图 | 人物、球队、场馆和画面的公开权利 |
| Android/iOS 原生库 | Rust、ONNX Runtime 和平台 SDK 的分发条件 |

如果模型或训练数据的权利无法证明，只发布源码，并要求使用者自行准备模型。详见 [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md) 和 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 3. macOS 构建

### 3.1 Debug 构建

```bash
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter build macos --debug
```

这只验证 Flutter UI 构建，不代表 Python Engine、模型和 FFmpeg 已嵌入。

### 3.2 准备便携运行时

需要一个包含项目依赖的便携 Python 目录：

```text
portable-python/
└── bin/python3
```

该 Python 应能导入 `cv2`、`numpy`、`ultralytics` 和 `torch`。不要直接复制带有开发机绝对路径或本机动态库引用的 `.venv`。

FFmpeg 和 FFprobe 应使用自包含或静态构建。依赖 Homebrew 的版本只适合本机临时验证，可显式设置 `BHE_ALLOW_EXTERNAL_FFMPEG=1`，但这不代表可分发。

### 3.3 准备运行时目录

把已授权模型放在：

```text
models/bball_model.pt
```

从仓库根目录运行：

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/prepare_macos_runtime.sh dist/macos-runtime
```

准备脚本会复制 Engine、算法脚本、SQLite schema、模型和视频工具，并运行运行时检查。失败时不要继续构建 `.app`。

### 3.4 构建 Release `.app`

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

需要签名时：

```bash
BHE_CODESIGN_IDENTITY="Developer ID Application: Example" \
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

`BHE_CODESIGN_IDENTITY` 只触发脚本的签名步骤，不等于已完成 Apple 公证或 Gatekeeper 验证。

### 3.5 干净机器验收

将 `.app` 放到没有源码仓库、Homebrew FFmpeg、开发 `.venv` 和个人模型路径的环境中，至少验证：

1. 应用能找到内置 Engine；
2. 可以创建项目并导入授权测试视频；
3. 可以读取元数据、自动或手动设置 ROI；
4. 标准分析可以完成；
5. 候选审核、时间调整和导出正常；
6. 重开项目后状态仍然存在；
7. 原视频移动后可以重新定位；
8. 没有向外部网络上传视频或模型数据；
9. 签名、公证和 Gatekeeper 安装流程通过。

## 4. Windows 实验性发布

准备运行时：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare_windows_runtime.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -OutPath dist\windows-runtime
```

构建并生成 zip：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -RuntimeOut dist\windows-runtime `
  -Zip
```

Windows 当前属于兼容路径，仍需验证 Flutter 工具链、Python/Torch/OpenCV/Ultralytics、FFmpeg DLL 和安装流程；它不能替代正式安装器、签名和用户验收。

## 5. 移动端发布边界

Android 当前主要验证 `arm64-v8a`，需要 Rust Runtime、ONNX Runtime Android 库和对应 ABI 的完整 APK。iOS 项目、媒体和导出可构建，但本地分析仍需要 Rust 静态库、ONNX Runtime XCFramework 和 Runner 链接；没有这些产物时不要发布为完整 AI 分析版本。

移动端构建入口见 [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) 和 [`../apps/mobile/README.md`](../apps/mobile/README.md)。

## 6. 版本与变更记录

发布前：

1. 更新根目录 [`CHANGELOG.md`](../CHANGELOG.md)；
2. 在 README 中明确版本和限制；
3. 协议或数据库变化时更新架构文档和兼容说明；
4. 算法参数变化时新增带日期的基准记录；
5. 为源码和二进制分别列出内容，不把模型默认为源码的一部分；
6. 使用可追溯的 Git commit 或 tag。

没有真实发布物和测试证据时，不要创建“稳定版”或“已支持全部平台”的 Release。

## 7. 当前发布阻塞项

以下事项未完成前推荐只发布源码预览：

- 清理或核验当前源码树中的模型、原生二进制、研究 checkout 和截图；
- 逐项生成锁定依赖的许可证 notices；
- 确认模型权重和训练数据授权；
- 使用公开授权的演示视频和截图；
- 在无仓库、无 Homebrew、无开发 `.venv` 的机器上验证；
- 完成 macOS 签名、公证和 Gatekeeper 验证；
- 完成 Windows 安装包和移动端目标设备验证。
