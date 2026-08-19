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

### macOS

```bash
.venv/bin/python -m pytest -q
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine

cd apps/desktop
PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter analyze
PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test
PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter build macos --debug
```

### Windows

**一键搭建**（自动检测/安装工具链、建 venv、装依赖、下载 FFmpeg 到 `bin/`、自检）：

```powershell
git clone https://gitee.com/jafir-h/basketball-highlight-editor.git
cd basketball-highlight-editor
powershell -ExecutionPolicy Bypass -File scripts\setup_windows.ps1
```

脚本幂等可重跑；已具备部分环境时可加 `-SkipToolchain` 只做项目内设置，`-Yes` 跳过 VS 安装确认。需先开启 Windows 开发者模式（Flutter 插件构建的符号链接要求）。

**手动方式**（前置：Visual Studio 2022 含 C++ 桌面开发、Python 3.12、Flutter stable、FFmpeg）：

```powershell
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt -r requirements-dev.txt

.venv\Scripts\python -m pytest -q
$env:PYTHONPATH="engine/python"; .venv\Scripts\python -m basketball_engine

cd apps\desktop
flutter analyze
flutter test
flutter build windows --debug    # 产物 build\windows\x64\runner\Debug\BHE.exe
```

Windows 平台说明：

- 引擎通过仓库根 `.venv`（`findPython` Windows 分支）或 `BHE_PYTHON` 环境变量定位；FFmpeg 放入仓库根 `bin/` 即可被子进程 PATH 感知。
- 窗口采用自绘标题栏（`TitleBarStyle.hidden`，仅 Windows），外观跟随应用主题。
- 全流程（导入 → 自动 ROI → 分析 → 审核 → 导出）已在 Windows 10 实测跑通；引擎级端到端冒烟脚本可参考本地 `%TEMP%` 下的验证记录。
- 发布运行时打包脚本：`scripts/prepare_windows_runtime.ps1`（Python + 引擎 + 模型 + FFmpeg 便携目录）。

运行时检查：

```bash
.venv/bin/python scripts/check_runtime.py --root . --python .venv/bin/python
```

导出人工审核训练数据（默认只导出已审核候选）：

```bash
.venv/bin/python scripts/export_review_dataset.py /path/to/project --csv
```

本地闭环记录见 `docs/LOCAL_E2E_V1.md`。macOS 运行时准备和分发边界见 `docs/MACOS_PACKAGING_V1.md`；当前 Release `.app` 构建成功不等于已经完成可分发打包。
