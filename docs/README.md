# 文档入口

**中文** · [English](README.en.md)

本目录按“入门教程 → 操作指南 → 参考契约 → 设计解释”组织。根目录 [README.md](../README.md) 适合首次了解项目；这里提供可逐步执行的完整文档地图。

## 按任务查找

| 你想做什么 | 先读什么 |
|---|---|
| 第一次安装并运行 | [GETTING_STARTED.md](GETTING_STARTED.md) |
| 排查启动、模型、FFmpeg 或候选问题 | [FAQ.md](FAQ.md) |
| 修改代码、写测试或提交 PR | [DEVELOPMENT.md](DEVELOPMENT.md) 和 [CONTRIBUTING.md](../CONTRIBUTING.md) |
| 打包 macOS/Windows | [RELEASE.md](RELEASE.md) 和 [MACOS_PACKAGING_V1.md](MACOS_PACKAGING_V1.md) |
| 理解 Flutter 与 Python Engine | [architecture/ARCHITECTURE_V1.md](architecture/ARCHITECTURE_V1.md) |
| 调试 JSONL 命令和事件 | [architecture/ENGINE_PROTOCOL_V1.md](architecture/ENGINE_PROTOCOL_V1.md) |
| 查看项目目录与缓存生命周期 | [architecture/PROJECT_LAYOUT_V1.md](architecture/PROJECT_LAYOUT_V1.md) |
| 修改或迁移 SQLite | [architecture/SQLITE_SCHEMA_V1.sql](architecture/SQLITE_SCHEMA_V1.sql) |
| 理解产品范围和验收 | [REQUIREMENTS_V1.md](REQUIREMENTS_V1.md) |
| 查看用户流程和异常路径 | [USER_FLOW_V1.md](USER_FLOW_V1.md) |
| 查看已经确认的产品/算法决策 | [DECISIONS_V1.md](DECISIONS_V1.md) |
| 查看快速/标准模式 | [research/ANALYSIS_MODES_V1.md](research/ANALYSIS_MODES_V1.md) |
| 查看当前性能基准 | [research/ANALYSIS_MODE_BENCHMARK_20260812.md](research/ANALYSIS_MODE_BENCHMARK_20260812.md) |
| 导出人工审核训练数据 | [REVIEW_DATASET_EXPORT.md](REVIEW_DATASET_EXPORT.md) |
| 核验模型、数据和第三方依赖 | [MODEL_AND_DATA_LICENSES.md](MODEL_AND_DATA_LICENSES.md) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) |
| 查看公开前清理结果 | [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md) |

## 入门与操作

- [GETTING_STARTED.md](GETTING_STARTED.md)：Python、Flutter、FFmpeg、模型、运行时检查、首次使用、Windows 实验性路径。
- [FAQ.md](FAQ.md)：常见错误、插件 SPM 警告、候选为空、片段过长、审核锁定、数据安全。
- [REVIEW_DATASET_EXPORT.md](REVIEW_DATASET_EXPORT.md)：将审核记录导出为 JSONL/CSV 的字段和命令。
- [LOCAL_E2E_V1.md](LOCAL_E2E_V1.md)：一次本地 Engine 闭环验证证据，不是算法准确率承诺。

## 开发与架构

- [DEVELOPMENT.md](DEVELOPMENT.md)：代码边界、测试、调试、模式变更、协议/数据库变更和提交前检查。
- [architecture/ARCHITECTURE_V1.md](architecture/ARCHITECTURE_V1.md)：Flutter UI、Python Engine、算法、存储和任务生命周期。
- [architecture/ENGINE_PROTOCOL_V1.md](architecture/ENGINE_PROTOCOL_V1.md)：JSONL 请求、响应、事件、命令、错误码和兼容规则。
- [architecture/PROJECT_LAYOUT_V1.md](architecture/PROJECT_LAYOUT_V1.md)：源码目录、用户项目目录和缓存清理规则。
- [architecture/SQLITE_SCHEMA_V1.sql](architecture/SQLITE_SCHEMA_V1.sql)：项目数据库表结构。
- [../engine/python/README.md](../engine/python/README.md)：Engine 独立启动和当前已实现命令概览。
- [../apps/desktop/README.md](../apps/desktop/README.md)：Flutter 桌面端模块和本地开发入口。

## 产品、决策与研究

- [DECISIONS_V1.md](DECISIONS_V1.md)：当前产品、算法和工程决策；冲突时优先参考。
- [REQUIREMENTS_V1.md](REQUIREMENTS_V1.md)：V1 功能范围、验收状态和不阻塞事项。
- [USER_FLOW_V1.md](USER_FLOW_V1.md)：导入、分析、审核、导出及失败恢复流程。
- [research/ANALYSIS_MODES_V1.md](research/ANALYSIS_MODES_V1.md)：快速/标准模式规则、缓存、继承和闸门。
- [research/ANALYSIS_MODE_BENCHMARK_20260812.md](research/ANALYSIS_MODE_BENCHMARK_20260812.md)：当前单样本冷启动基准和结论边界。
- [research/LICENSE_NOTES.md](research/LICENSE_NOTES.md)：研究阶段第三方仓库和许可证备注。
- [research/THIRD_PARTY_MANIFEST.md](research/THIRD_PARTY_MANIFEST.md)：研究参考 checkout 的来源和固定提交。

## 开源与发布

- [RELEASE.md](RELEASE.md)：源码预览发布、依赖授权、macOS 运行时、Windows 兼容打包和干净机器验收。
- [OPEN_SOURCE_AUDIT.md](OPEN_SOURCE_AUDIT.md)：已经清理的内容、未完成事项和二进制发布阻塞项。
- [MODEL_AND_DATA_LICENSES.md](MODEL_AND_DATA_LICENSES.md)：模型、训练数据、视频和推理依赖的授权边界。
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)：运行时依赖与研究参考项目的区别。
- [../CONTRIBUTING.md](../CONTRIBUTING.md)：Issue、PR、测试和隐私要求。
- [../SECURITY.md](../SECURITY.md)：安全漏洞报告方式。
- [../CHANGELOG.md](../CHANGELOG.md)：版本变更记录。

## 文档约定

- 文档中的“当前已验证”只代表仓库记录的测试或运行证据，不代表所有视频都准确；
- 源码、配置和运行时行为冲突时，优先以 live runtime、协议和数据库事实为准；
- 新增协议、数据库字段、算法参数或发布依赖时，要同步更新中英文入口和对应参考文档；
- 不在文档中写入本机绝对路径、真实视频路径、密钥、模型下载地址或未经授权的截图；
- 研究文档记录实验过程，产品契约以 `DECISIONS_V1.md` 和对应架构文档为准。
