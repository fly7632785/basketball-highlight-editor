# Basketball Highlight Editor

固定机位篮球比赛视频的进球候选识别、人工审核和片段导出工具。

## 当前阶段

项目已从算法调研进入 **V1 桌面产品工程化阶段**：Flutter macOS UI 与 Python Engine 已完成本地最小闭环，可执行“导入视频 → 提取预览帧 → 框选 ROI → 分析 → 审核 → 单独/合并导出”。

## 已确定的产品边界

- 固定机位
- 单篮筐
- 长视频批量扫描
- 自动生成疑似进球片段
- 用户审核后合并导出或单独导出
- macOS、Windows 优先，后续适配 iOS、Android

## 目录

- `docs/research/`：调研计划、复用矩阵和技术结论
- `docs/DECISIONS_V1.md`：当前产品与技术决策单一入口
- `docs/ROADMAP_EXECUTION_V1.md`：按依赖关系排列的执行路线
- `docs/architecture/`：系统架构、协议和 SQLite Schema
- `engine/python/`：本地 JSON Lines Engine
- `third_party/`：只读克隆的参考项目
- `data/`：本地测试视频和标注规范，不提交原始视频
- `src/`：已验证的算法库
- `tests/`：后续测试

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

本地闭环记录见 `docs/LOCAL_E2E_V1.md`。macOS 运行时准备和分发边界见 `docs/MACOS_PACKAGING_V1.md`；当前 Release `.app` 构建成功不等于已经完成可分发打包。
