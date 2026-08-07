# macOS 运行时打包 V1

## 当前结论

Flutter `Release` 构建已经可以生成 `.app`，但仅包含 UI。Engine 还需要以下运行时：

- 可携带的 Python 运行时和依赖：`cv2`、`numpy`、`ultralytics`、`torch`；
- Engine、算法脚本、`src/`；
- 篮球检测模型；
- 可携带的 `ffmpeg` / `ffprobe`。

当前开发机的 `.venv/bin/python` 指向用户目录下的 Python，不可直接复制到其他 Mac。当前 Homebrew FFmpeg 还依赖多个 `/usr/local` 动态库，也不能直接当作发布包中的 FFmpeg。

因此，当前 Release `.app` **不是可分发安装包**，不能把“构建成功”误认为“用户机器可运行”。

## 已实现的准备工具

运行时检查：

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python
```

准备运行时目录：

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/prepare_macos_runtime.sh dist/macos-runtime
```

构建并嵌入到 `.app`：

```bash
BHE_PYTHON_RUNTIME=/path/to/portable-python \
BHE_FFMPEG=/path/to/static/ffmpeg \
BHE_FFPROBE=/path/to/static/ffprobe \
scripts/build_macos_release.sh
```

如果只是在当前开发机验证动态 FFmpeg，可临时加：

```bash
BHE_ALLOW_EXTERNAL_FFMPEG=1
```

这只适合本机测试，不代表可分发。

## 下一步验收标准

1. `portable-python/bin/python3` 不依赖开发机绝对路径；
2. `ffmpeg` 和 `ffprobe` 不依赖 Homebrew 路径；
3. 把生成的 `.app` 复制到没有仓库、没有 Homebrew、没有 `.venv` 的干净 macOS 用户目录；
4. 能完成 `hello → inspect_video → start_analysis → export_clips`；
5. 完成签名、公证和 Gatekeeper 安装验证。

Python 运行时体积预计显著大于 Flutter UI；在确认模型和推理后端前，不提前引入 Rust/ONNX Runtime 打包，避免同时改变算法和分发链。
