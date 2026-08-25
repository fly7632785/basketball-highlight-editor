# 开源公开前审计记录

更新时间：2026-08-24

## 公开策略

当前目标是先发布**源码预览版**，让开发者理解架构并在本地准备依赖后运行。当前不承诺提供可直接安装的 macOS/Windows 桌面包，也不承诺移动端二进制可以在所有设备上执行本地 AI 分析。

## 文档整理结果

本轮文档治理完成：

- 根目录 README 重写为中英文双入口，并补齐桌面/移动端状态、安装、运行、测试和发布边界；
- `docs/README.md` 与 `docs/README.en.md` 改为按任务导航；
- 入门、FAQ、开发和发布文档同步更新，删除失效命令和重复入口；
- macOS 打包说明合并到 `docs/RELEASE.md`，不再维护重复的 `MACOS_PACKAGING_V1.md`；
- 许可证研究笔记和第三方 checkout 清单合并到 `docs/THIRD_PARTY_NOTICES.md`；
- 一次性本地 E2E 记录从主文档删除，避免把本机样本当成当前功能契约；
- 单样本性能记录移动到 `docs/benchmarks/`，保留为实验依据而不是用户承诺。

## 当前源码树仍需处理的阻塞项

以下项目在当前 `feature/mobile-app` 基线中仍然存在，公开 GitHub 前必须清理、替换或取得明确授权：

- `models/bball_model.pt`、`models/bball_model.onnx`；
- `apps/mobile/assets/models/bball_model.onnx`；
- `apps/mobile/android/app/src/main/jniLibs/arm64-v8a/*.so`；
- `apps/desktop/assets/fonts/*.ttf` 当前是占位文本，不是可分发的有效字体文件；
- `.research/opensource-refs-20260806/` 下的研究 checkout/gitlink；
- `capture/screenshot-*.png` 等开发机截图。

这些并非本轮文档修改的目标，因此没有在本 worktree 中删除；文档已经不再把它们描述为“天然可以公开”的内容。删除前要保留原始与派生物边界，并确认移动端构建在无预编译库时仍能给出明确的 `NATIVE_RUNTIME_UNAVAILABLE`。

## 发布前必须完成

- 运行 `python3 scripts/check_open_source.py`，并处理所有 error；
- 从 Git 历史和当前索引中清理未授权模型、原生二进制、视频、截图、研究 checkout 和个人数据；
- 根据实际 `requirements*.txt`、`pubspec.lock`、`Cargo.lock` 和 FFmpeg 构建生成 notices；
- 核验模型权重、训练数据、演示视频和截图的公开权利；
- 在没有仓库、Homebrew、开发 `.venv` 和个人路径的干净机器上验证 macOS；
- 完成 macOS 签名、公证和 Gatekeeper 验证；
- 完成 Windows 兼容打包和移动端 Android/iOS 目标设备验证；
- 发布时为源码、桌面包、移动包、模型和数据分别列出内容与许可证。

## 已确认的边界

- 原始视频默认本地处理，不上传、不复制到项目目录；
- 候选是算法建议，必须经过人工审核；
- 桌面端 Python Engine 与移动端 Rust/ONNX Runtime 是两条不同运行时路径；
- 模型、数据、编解码器和第三方依赖不自动继承源码 MIT License；
- `flutter build` 成功不等于干净机器可运行或可以公开分发。

## 审计命令

```bash
python3 scripts/check_open_source.py
git ls-files | rg '\.(pt|onnx|pth|bin|mp4|mov|mkv|so|dylib)$'
git ls-files | rg '(^|/)(capture|data|\.research|third_party)/'
git diff --check
```
