# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本遵循语义化版本约定。

## [Unreleased]

### Added

- 增加中英文根 README、入门、FAQ、开发和发布入口；
- 增加文档任务索引、模型/数据授权说明、第三方 notices 和开源审计记录；
- 增加源码树公开前检查脚本；
- 增加模型、数据、标签和截图目录的本地使用说明。

### Changed

- 将 macOS 打包说明合并到 `docs/RELEASE.md`；
- 将第三方许可证研究信息合并到 `docs/THIRD_PARTY_NOTICES.md`；
- 将单样本分析基准移动到 `docs/benchmarks/`，与用户运行文档分开；
- README 明确桌面端、Android 和 iOS 当前实现边界，不把移动端或二进制发布写成已完成。

### Known limitations

- 当前不是包含 Python、FFmpeg、模型和原生 Runtime 的最终用户安装包；
- 模型权重、训练数据、真实比赛视频、截图和原生二进制仍需独立核验授权；
- macOS/Windows 分发、iOS 本地分析和移动端真机验收仍未完成。
