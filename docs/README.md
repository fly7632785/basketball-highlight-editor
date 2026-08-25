# 文档入口

**中文** · [English](README.en.md)

根目录 [`README.md`](../README.md) 是项目概览和最短运行路径。本目录按“入门 → 排障 → 开发 → 架构 → 发布”组织；产品契约和研究记录只在需要修改对应行为时阅读。

## 按任务查找

| 目标 | 从这里开始 |
|---|---|
| 第一次安装和运行桌面端 | [`GETTING_STARTED.md`](GETTING_STARTED.md) |
| 候选为空、模型、FFmpeg、插件警告 | [`FAQ.md`](FAQ.md) |
| 修改代码、补测试、提交 PR | [`DEVELOPMENT.md`](DEVELOPMENT.md) 和 [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |
| 打包 macOS/Windows | [`RELEASE.md`](RELEASE.md) |
| 理解桌面端架构 | [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md) |
| 调试 Flutter ↔ Engine 协议 | [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md) |
| 理解项目目录和缓存 | [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md) |
| 理解移动端原生 Runtime | [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) |
| 修改 SQLite 结构 | [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql) |
| 导出审核数据 | [`REVIEW_DATASET_EXPORT.md`](REVIEW_DATASET_EXPORT.md) |
| 了解 Fast/Standard 分析模式 | [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md) |
| 查看已记录的性能样本 | [`benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md`](benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md) |
| 核对模型、数据和依赖授权 | [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md) 和 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) |
| 发布前检查源码树 | [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md) |

## 用户文档

- [`GETTING_STARTED.md`](GETTING_STARTED.md)：Python、Flutter、FFmpeg、模型、运行时检查、首次使用和 Windows 实验路径。
- [`FAQ.md`](FAQ.md)：启动、候选、视频、导出、移动端和 macOS Swift Package Manager 警告。
- [`REVIEW_DATASET_EXPORT.md`](REVIEW_DATASET_EXPORT.md)：把审核结果导出为 JSONL/CSV 的命令和字段。

## 开发与架构

- [`DEVELOPMENT.md`](DEVELOPMENT.md)：模块边界、测试、调试、协议/数据库变更和提交前检查。
- [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md)：桌面 UI、Python Engine、算法、存储和任务生命周期。
- [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md)：JSONL 请求、响应、事件、命令和错误码。
- [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md)：源码树、用户项目树和缓存清理规则。
- [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md)：Android/iOS 原生媒体与 Rust/ONNX 接入边界。
- [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql)：项目数据库结构。
- [`../engine/python/README.md`](../engine/python/README.md)：独立 Engine 启动和当前命令概览。
- [`../apps/desktop/README.md`](../apps/desktop/README.md)：桌面 Flutter 模块。
- [`../apps/mobile/README.md`](../apps/mobile/README.md)：移动端开发和原生库准备。

## 产品契约与研究

- [`DECISIONS_V1.md`](DECISIONS_V1.md)：当前产品、算法和工程决策；与旧记录冲突时优先看这里和运行时行为。
- [`REQUIREMENTS_V1.md`](REQUIREMENTS_V1.md)：V1 范围、已实现/部分实现/未完成状态和发布门槛。
- [`USER_FLOW_V1.md`](USER_FLOW_V1.md)：导入、分析、审核、导出和异常路径。
- [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md)：两档模式规则、缓存、继承和质量闸门。
- [`benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md`](benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md)：单个样本的冷启动耗时记录，不是准确率承诺。

## 开源与发布

- [`RELEASE.md`](RELEASE.md)：源码预览发布、桌面运行时、签名、公证和许可证检查。
- [`OPEN_SOURCE_AUDIT.md`](OPEN_SOURCE_AUDIT.md)：当前源码树的公开阻塞项。
- [`MODEL_AND_DATA_LICENSES.md`](MODEL_AND_DATA_LICENSES.md)：模型、训练数据、视频和推理依赖的授权边界。
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)：运行时依赖和研究参考的集中清单。
- 根目录 [`CONTRIBUTING.md`](../CONTRIBUTING.md)、[`SECURITY.md`](../SECURITY.md)、[`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md)、[`CHANGELOG.md`](../CHANGELOG.md) 和 [`LICENSE`](../LICENSE)。

## 文档约定

- “已实现”表示当前代码存在对应路径，不等于所有平台、视频和模型都已完成发布验收。
- “已验证”必须对应测试、运行日志或可复现实验；单个视频的耗时不能写成普遍保证。
- 当源码、文档和运行结果冲突时，优先核对 live runtime、协议和数据库状态，再更新文档。
- 不在文档中写入个人绝对路径、真实视频路径、密钥、未授权模型下载地址或未脱敏截图。
- 协议命令、数据库字段、分析参数或发布依赖发生变化时，同时更新本索引和对应中英文入口。

一次性本地闭环记录、许可证研究笔记和研究 checkout 清单不再作为主文档维护；可从 Git 历史追溯，稳定结论集中到产品契约和 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
