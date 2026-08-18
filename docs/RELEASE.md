# 发布指南

**中文** · [English](RELEASE.en.md)

当前项目有两种发布物，必须分开处理：

1. **源码预览版**：公开源码、文档、测试和许可证，不携带模型、真实视频或最终运行时；
2. **桌面二进制版**：额外携带 Python、依赖、FFmpeg/FFprobe、模型和 Flutter 应用，需要更严格的授权、签名和干净环境验证。

当前仓库只承诺源码预览版。除非本文件全部检查项完成，不要把 Release `.app` 或模型附件描述成普通用户可直接安装使用。

## 1. 源码预览版发布

### 1.1 内容检查

确认仓库包含：

- README.md 和 README.en.md；
- `docs/` 下的入门、开发、FAQ、发布和架构文档；
- MIT `LICENSE`、`NOTICE`、`CONTRIBUTING.md`、`SECURITY.md`；
- 第三方依赖和研究参考说明；
- 模型、数据和截图的本地使用说明；
- CI 工作流和 Issue/PR 模板。

确认仓库不包含：

- `.pt`、`.onnx`、`.pth`、`.bin` 等未核验权重；
- 视频、真实标注、导出片段和本机截图；
- `.venv/`、`.tooling/`、`build/`、`dist/`；
- API key、私钥、个人绝对路径和个人联系方式；
- 未授权的第三方源码 checkout 或 gitlink。

### 1.2 自动检查

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../..
git diff --check
```

开源检查允许提醒性 warning，但不能有 error。warning 需要在正式发布前逐项判断，例如依赖 notices、模型授权和截图公开权利。

### 1.3 文档检查

逐项确认：

- 中英文 README 的安装、模型、运行和测试命令互相对应；
- 命令没有依赖维护者本机的 `.tooling/` 或绝对路径；
- 没有编造模型下载地址、GitHub 仓库地址或维护者邮箱；
- “已验证”“当前限制”“未来计划”分开书写；
- 快速模式只描述已测到的速度，不承诺固定准确率和耗时；
- Windows、移动端、Rust 和最终安装包没有被写成已经完成。

## 2. 模型、数据和依赖授权

发布前必须分别保存或核验：

| 对象 | 必须确认 |
|---|---|
| 源码 | MIT 文件是否随发布物保留 |
| Python 依赖 | 锁定版本和各自许可证 |
| Flutter/Dart 依赖 | `pubspec.lock` 对应版本和 notices |
| FFmpeg/FFprobe | 编译配置、LGPL/GPL 边界和 notices |
| 模型代码 | 代码许可证和再分发条件 |
| 模型权重 | 权重文件是否允许公开下载或随包分发 |
| 训练数据 | 原始和衍生数据的公开处理权 |
| 演示视频/截图 | 人物、球队、场馆和画面公开权利 |

如果模型权重或训练数据授权无法证明，只发布源码，并要求用户自行准备模型。详细边界见 [MODEL_AND_DATA_LICENSES.md](MODEL_AND_DATA_LICENSES.md)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md)。

## 3. macOS 本地构建

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

需要一个便携 Python 目录，至少满足：

```text
portable-python/
└── bin/python3
```

该 Python 必须已经安装项目运行依赖，并且能导入 `cv2`、`numpy`、`ultralytics` 和 `torch`。不要直接复制开发机 `.venv`，因为其中可能含有绝对路径或本机动态库引用。

FFmpeg 和 FFprobe 应使用自包含或静态构建。若使用依赖 Homebrew 的版本，准备脚本会在 macOS 上拒绝它；只有本机临时验证才可设置 `BHE_ALLOW_EXTERNAL_FFMPEG=1`。

### 3.3 只准备运行时目录

先把已授权的模型放在仓库约定位置：

```text
models/bball_model.pt
```

然后运行：

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/prepare_macos_runtime.sh dist/macos-runtime
```

准备脚本会复制 Engine、脚本、算法库、SQLite schema、模型和视频工具，并运行 `check_runtime.py`。失败时不要继续构建 `.app`。

### 3.4 构建 Release `.app`

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

如需代码签名：

```bash
BHE_CODESIGN_IDENTITY="Developer ID Application: Example" \
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
FLUTTER_BIN="$(command -v flutter)" \
scripts/build_macos_release.sh
```

`BHE_CODESIGN_IDENTITY` 只是触发脚本的签名步骤，不等于已经完成 Apple 公证或 Gatekeeper 验证。

### 3.5 干净机器验收

把生成的 `.app` 复制到没有以下内容的测试目录或测试 Mac：

- 源码仓库；
- Homebrew FFmpeg；
- 开发 `.venv`；
- 本机绝对路径下的模型和脚本。

至少验证：

1. 应用启动并能找到内置 Engine；
2. 创建项目；
3. 导入授权测试视频；
4. 读取视频元数据；
5. 自动 ROI 失败时可以手动 ROI；
6. 启动标准分析并完成；
7. 审核、调整和导出；
8. 重开项目后状态仍然存在；
9. 源视频移动后可以重新定位；
10. 没有向外部网络上传视频或模型数据。

## 4. Windows 实验性发布

Windows 运行时准备脚本要求一个包含 `python.exe` 和已安装依赖的便携 Python 目录：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare_windows_runtime.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -OutPath dist\windows-runtime
```

构建 Windows Release 并生成 zip：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1 `
  -PythonRuntime C:\path\to\portable-python `
  -Ffmpeg C:\path\to\ffmpeg.exe `
  -Ffprobe C:\path\to\ffprobe.exe `
  -RuntimeOut dist\windows-runtime `
  -Zip
```

发布前必须确认：

- Flutter Windows 工具链版本；
- `BHE.exe` 和 `runtime/` 的实际布局；
- Python、Torch、OpenCV 和 Ultralytics 在目标 Windows 版本上的兼容性；
- FFmpeg DLL 或可执行文件的分发许可；
- 没有依赖开发机路径。

当前 Windows 脚本属于兼容路径，不能替代正式安装器、签名和用户验收。

## 5. 版本和变更记录

发布前：

1. 更新 `CHANGELOG.md`；
2. 在 README 中明确当前版本和限制；
3. 如果协议或数据库变化，更新架构文档和兼容说明；
4. 如果算法参数变化，新增带日期的基准记录；
5. 给源码和二进制发布物分别列出内容，不把模型默认为源码的一部分；
6. 使用可追溯的 Git commit 或 tag。

不要在没有真实发布产物和测试证据时创建“稳定版”字样的 Release。

## 6. 当前正式 Release 阻塞项

依据 [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md)，以下事项完成前，推荐只发布源码预览版：

- 依赖锁定版本的许可证 notices 尚未逐项生成；
- 模型权重和训练数据授权仍需独立确认；
- 公开演示素材需要替换为已授权的截图和视频；
- 需要在无仓库、无 Homebrew、无开发 `.venv` 的机器上验证；
- macOS 签名、公证和 Gatekeeper 验证尚未完成；
- Windows 安装包和移动端 CI 仍不是当前完成项。
