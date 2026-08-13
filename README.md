# Basketball Highlight Editor

固定机位篮球比赛视频的进球候选识别、人工审核和片段导出工具。

## 当前阶段

项目已从算法调研进入 **V1 桌面产品工程化阶段**：Flutter macOS UI 与 Python Engine 已完成本地最小闭环，可执行“导入视频 → 提取预览帧 → 框选 ROI → 分析 → 审核 → 单独/合并导出”。

## 已确定的产品边界

- 固定机位
- 单篮筐
- 长视频批量扫描
- 自动生成疑似进球片段
- 分析结果默认保留，用户只需剔除误检后合并导出或单独导出
- macOS、Windows 优先，后续适配 iOS、Android

## 文档入口

- `docs/DECISIONS_V1.md`：当前产品、算法和工程决策，冲突时以此为准
- `docs/REQUIREMENTS_V1.md`：V1 范围、验收状态和未完成项
- `docs/architecture/ARCHITECTURE_V1.md`：系统边界和模块职责
- `docs/architecture/ENGINE_PROTOCOL_V1.md`：Flutter ↔ Python Engine JSONL 契约
- `docs/architecture/SQLITE_SCHEMA_V1.sql`：项目数据库结构
- `docs/USER_FLOW_V1.md`：用户流程和异常路径
- `docs/MACOS_PACKAGING_V1.md`：macOS 打包与运行时边界
- `docs/research/ANALYSIS_MODES_V1.md`：快速/标准分析模式决策
- `docs/research/ANALYSIS_MODE_BENCHMARK_20260812.md`：快速/标准模式实测基准
- `design-system/courtside/MASTER.md`：当前 UI 设计规范

`docs/research/` 其余文件是历史研究和实验记录，不作为当前实现契约。`third_party/` 是只读参考仓库，`data/` 是本地研发数据。

## 当前可验证命令

```bash
.venv/bin/python -m pytest -q
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine

cd apps/desktop
PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter analyze
PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test
PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter build macos --debug
```

运行时检查：

```bash
.venv/bin/python scripts/check_runtime.py --root . --python .venv/bin/python
```

导出人工审核训练数据（默认只导出已审核候选）：

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project --csv
```

本地闭环记录见 `docs/LOCAL_E2E_V1.md`。macOS 运行时准备和分发边界见 `docs/MACOS_PACKAGING_V1.md`；当前 Release `.app` 构建成功不等于已经完成可分发打包。
