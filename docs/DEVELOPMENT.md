# 开发指南

**中文** · [English](DEVELOPMENT.en.md)

这份文档面向修改代码、协议、算法或 UI 的贡献者。它不替代架构决策和协议文档；冲突时先看 `docs/DECISIONS_V1.md`，再看对应模块文档和运行时行为。

## 1. 开发环境

推荐：

- macOS Apple Silicon 或 Intel；
- Python 3.11；
- Flutter 3.44.8 stable；
- FFmpeg/FFprobe；
- 一个本地、已确认授权的模型；
- Git 和 Make。

创建 Python 环境：

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

准备 Flutter：

```bash
cd apps/desktop
flutter pub get
```

本地模型和视频不进入 Git，路径约定见 `models/README.md`、`data/README.md` 和 `.gitignore`。

## 2. 代码边界

```text
apps/desktop/                 Flutter UI 和客户端状态
engine/python/                JSONL Engine、任务和存储适配
engine/python/adapters/       算法脚本和导出脚本适配
src/basketball_highlight/     可复用的检测、事件、轨迹和审核规则
scripts/                      可独立运行的分析、导出和运行时脚本
docs/architecture/            架构、协议和数据库契约
design-system/                UI 设计规范
tests/                        Python 测试
apps/desktop/test/            Flutter 测试
```

关键约束：

- UI 不直接操作 SQLite、检测 JSON 或 FFmpeg；
- Engine 通过 JSONL 协议向 UI 提供能力；
- 数据库保存事实状态，中间视频和检测文件放在 `artifacts/`；
- 原视频默认只引用，不复制、不移动、不自动删除；
- 导出以数据库中当前审核状态为准，不信任 UI 缓存；
- 新分析成功切换前不能清空旧候选；
- 变更协议或数据库前，先更新契约文档和测试。

## 3. 推荐工作流

### 3.1 先查状态和调用链

```bash
git status --short --branch
git diff --stat
rg -n "command_name|handler_name|table_name" apps engine src scripts tests
```

先确认当前工作区是否有其他 Agent 或开发者的未提交修改。不要覆盖、格式化或重置无关改动。

### 3.2 先写验收，再改实现

每个功能或 Bug 先写出可复现输入、预期输出和失败边界。对于 Python 逻辑，优先在 `tests/` 增加最小测试；对于 Flutter 交互，优先在 `apps/desktop/test/` 覆盖状态变化、按钮禁用和错误反馈。

### 3.3 保持小提交

推荐每个提交只包含一个主题：

```bash
git add path/to/changed/files
git diff --cached --check
git commit -m "docs: explain local runtime setup"
```

不要把视频、模型、构建目录、`.venv`、截图或本机绝对路径加入提交。

## 4. 测试命令

开源预检：

```bash
python3 scripts/check_open_source.py
```

Python：

```bash
.venv/bin/python -m pytest -q
```

指定测试：

```bash
.venv/bin/python -m pytest -q tests/test_engine.py tests/test_export_adapter.py
```

Flutter：

```bash
cd apps/desktop
flutter analyze
flutter test
```

本地 Engine 协议手测：

```bash
cd /path/to/basketball-highlight-editor
PYTHONPATH=engine/python .venv/bin/python -m basketball_engine
```

Flutter 测试中的 `media_kit` 初始化提示不等于测试失败；应以命令退出码和测试结果为准。

## 5. 调试分析链路

完整分析大致经过：

```text
validate_input
→ prepare_proxy
→ coarse_scan
→ generate_candidates
→ refine_candidates（标准模式）
→ persist_candidates
→ prepare_review_previews
→ completed
```

独立检查脚本帮助：

```bash
.venv/bin/python scripts/create_proxy.py --help
PYTHONPATH=src:scripts .venv/bin/python scripts/scan_video.py --help
.venv/bin/python scripts/generate_candidates.py --help
.venv/bin/python scripts/refine_dynamic_candidates.py --help
```

注意：`scan_video.py`、`generate_candidates.py` 等脚本需要真实视频、模型和 ROI，不能只通过 `--help` 判断算法正确性。调试输出放到临时目录，不要写进 `data/` 或仓库根目录。

## 6. 分析模式变更

快速/标准模式不是两个独立产品，必须保持以下一致性：

- 候选审核、手动范围、保留/排除和导出语义一致；
- 快速和标准缓存不能互相覆盖；
- 分析批次要保存实际参数快照；
- 新批次失败或取消时旧结果仍然可用；
- 快速模式不能通过限制候选数量伪造提速；
- 速度和召回率必须用固定视频分别测量。

修改参数后，补充带日期的基准记录，并同步 [research/ANALYSIS_MODES_V1.md](research/ANALYSIS_MODES_V1.md)。不要把单个样本的耗时写成普遍保证。

## 7. UI 修改

桌面 UI 以 `apps/desktop/lib/theme/` 和 `apps/desktop/lib/components/` 为设计源。改动审核工作台时优先保证：

- 视频区域是主要空间；
- 候选切换、播放和审核状态有清晰反馈；
- 导出期间的锁定状态可理解；
- 响应式窗口下不遮挡视频和时间轴；
- 键盘焦点、减少动效和浅色/深色主题仍可用。

视觉改动请附公开可用的截图；不要提交含本机路径、真实球员或真实视频的截图。

## 8. 协议和数据库变更

修改 Engine 命令时同步：

1. `docs/architecture/ENGINE_PROTOCOL_V1.md`；
2. Engine handler 和 Flutter client；
3. 协议测试与错误路径测试；
4. 版本兼容说明。

修改 SQLite 时同步：

1. `docs/architecture/SQLITE_SCHEMA_V1.sql`；
2. storage 初始化和读写逻辑；
3. 旧项目打开、空值和迁移测试；
4. [architecture/PROJECT_LAYOUT_V1.md](architecture/PROJECT_LAYOUT_V1.md) 中的数据生命周期说明。

## 9. 提交前检查清单

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../..
git diff --check
git status --short --branch
```

确认：

- [ ] 所有修改文件为 UTF-8，无 BOM；
- [ ] 没有模型、视频、截图、构建产物或密钥；
- [ ] 没有 macOS、Linux 或 Windows 本机绝对路径；
- [ ] 文档命令与实际目录、脚本参数一致；
- [ ] 中英文文档同步更新；
- [ ] 已说明测试命令和已知限制；
- [ ] 协议、数据库或许可证影响已记录。

## 10. 提交问题和 PR

先阅读 [CONTRIBUTING.md](../CONTRIBUTING.md)。Bug 报告至少包含版本/commit、系统、运行方式、最小复现步骤、实际结果和预期结果；不要附带未脱敏视频、密钥或个人数据。
