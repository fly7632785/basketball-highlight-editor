# 文档入口

## 当前有效文档

这些文档描述当前代码、协议或用户可见行为，冲突时优先参考决策记录，再参考对应领域文档：

| 文档 | 用途 |
|---|---|
| [`DECISIONS_V1.md`](DECISIONS_V1.md) | 当前产品、算法和工程决策；冲突时以此为准 |
| [`REQUIREMENTS_V1.md`](REQUIREMENTS_V1.md) | V1 范围、验收状态和剩余工作 |
| [`USER_FLOW_V1.md`](USER_FLOW_V1.md) | 用户流程和异常路径 |
| [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md) | 系统边界、模块职责和任务生命周期 |
| [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md) | Flutter 与 Python Engine 的 JSONL 契约 |
| [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql) | 项目数据库结构；Engine 初始化时读取 |
| [`MACOS_PACKAGING_V1.md`](MACOS_PACKAGING_V1.md) | macOS 运行时、打包和分发边界 |
| [`REVIEW_DATASET_EXPORT.md`](REVIEW_DATASET_EXPORT.md) | 审核结果导出为训练数据的用法 |
| [`research/ANALYSIS_MODES_V1.md`](research/ANALYSIS_MODES_V1.md) | 快速/标准分析模式的数据契约和产品规则 |
| [`research/ANALYSIS_MODE_BENCHMARK_20260812.md`](research/ANALYSIS_MODE_BENCHMARK_20260812.md) | 快速/标准模式的实测耗时和结论边界 |
| [`research/LICENSE_NOTES.md`](research/LICENSE_NOTES.md) | 第三方仓库与模型权重的许可证备注 |
| [`research/THIRD_PARTY_MANIFEST.md`](research/THIRD_PARTY_MANIFEST.md) | third_party 浅克隆来源与固定提交 |
| [`LOCAL_E2E_V1.md`](LOCAL_E2E_V1.md) | 本地闭环验证证据，不是功能契约 |

历史过程文档（早期可行性评估、验证报告、UI 重构审计等）已删除，需要回溯时使用 Git 历史。需要改变算法或性能策略时，先更新 `DECISIONS_V1.md`，再补充新的带日期基准记录。

当前 UI 以 [`../design-system/courtside/MASTER.md`](../design-system/courtside/MASTER.md) 和其页面覆盖规则为准。
