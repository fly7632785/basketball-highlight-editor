# 开发指南

**中文** · [English](DEVELOPMENT.en.md)

这份文档面向修改代码、协议、算法或 UI 的贡献者。请按变更范围阅读产品契约和架构文档。

## 1. 开发环境

推荐：

- macOS Apple Silicon 或 Intel；
- Python 3.11；
- Flutter stable（当前开发基线为 3.44.8）；
- FFmpeg/FFprobe；
- 本地、已确认授权的模型和测试视频；
- Git。

创建 Python 环境：

```bash
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

准备桌面 Flutter：

```bash
cd apps/desktop
flutter pub get
```

移动端依赖：

```bash
cd apps/mobile
flutter pub get
```

本地模型、视频、标注、截图和构建产物不应进入 Git；目录约定见 [`../models/README.md`](../models/README.md)、[`../data/README.md`](../data/README.md) 和 `.gitignore`。

## 2. 代码边界

```text
apps/desktop/                 Flutter 桌面 UI 和项目状态
apps/mobile/                  独立 Flutter 移动端
packages/bhe_core/            移动端共享模型、项目包和引擎接口
packages/bhe_runtime/         Rust/ONNX 移动端原生 Runtime
engine/python/                JSONL Engine、任务和存储适配
engine/python/adapters/       算法脚本和导出适配
src/basketball_highlight/     检测、事件、轨迹和审核规则
scripts/                      分析、导出、运行时和移动端构建脚本
docs/architecture/            架构、协议和数据库契约
tests/                        Python 测试
apps/desktop/test/            桌面 Flutter 测试
apps/mobile/test/             移动 Flutter 测试
```

关键约束：

- 桌面 UI 不直接操作 SQLite、检测 JSON 或 FFmpeg；
- 桌面 Engine 通过 JSONL 协议提供能力；
- 移动端不启动桌面 Python Engine，通过平台 channel 调用媒体和原生 Runtime；
- 数据库保存事实状态，中间视频和检测文件位于用户项目的 `artifacts/`；
- 原始视频默认只引用，不复制、不移动、不自动删除；
- 导出以数据库当前审核状态为准，不信任 UI 缓存；
- 新分析成功切换前不能清空旧候选；
- 协议或数据库变更前，先更新契约文档和测试。

## 3. 推荐工作流

### 3.1 先确认工作树和调用链

```bash
git status --short --branch
git diff --stat
rg -n "command_name|handler_name|table_name" apps engine src scripts tests
```

先确认是否有其他 Agent 或开发者的未提交修改。不要覆盖、格式化、重置或删除无关改动；需要隔离工作时使用独立 worktree。

### 3.2 先写验收，再改实现

每个功能或 Bug 先记录可复现输入、预期输出和失败边界。Python 逻辑优先在 `tests/` 增加最小测试；Flutter 交互优先覆盖状态变化、按钮禁用和错误反馈。

### 3.3 保持小提交

```bash
git add path/to/changed/files
git diff --cached --check
git commit -m "docs: update runtime guide"
```

不要把视频、模型、构建目录、`.venv`、截图或本机绝对路径加入提交。

## 4. 测试命令

源码公开前检查：

```bash
python3 scripts/check_open_source.py
```

Python：

```bash
.venv/bin/python -m pytest -q
.venv/bin/python -m pytest -q tests/test_engine.py tests/test_export_adapter.py
```

桌面 Flutter：

```bash
cd apps/desktop
flutter analyze
flutter test
flutter build macos --debug
```

移动 Flutter：

```bash
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
```

真实视频分析、Android/iOS 原生库、模型输出和最终导出仍需要目标平台手测；单元测试不能替代这些验收。

## 5. 调试桌面分析链路

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

脚本帮助：

```bash
.venv/bin/python scripts/create_proxy.py --help
PYTHONPATH=src:scripts .venv/bin/python scripts/scan_video.py --help
.venv/bin/python scripts/generate_candidates.py --help
.venv/bin/python scripts/refine_dynamic_candidates.py --help
```

这些脚本的 `--help` 不会验证真实视频、模型和 ROI；调试输出写到临时目录，不要写入仓库或提交到 Git。

## 6. 分析模式变更

快速/标准模式不是两个独立产品，必须保持：

- 审核、手动范围、保留/排除和导出语义一致；
- 缓存键包含视频指纹、代理参数、模型和算法版本；
- 分析批次保存实际参数快照和阶段耗时；
- 新批次失败或取消时旧结果仍可用；
- 快速模式不能通过限制候选数量制造提速；
- 速度、召回和错误类型要用固定视频分别测量。

修改参数后，新增带日期的基准记录，并同步 [`benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md`](benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md) 和产品决策文档。不要把单样本耗时写成普遍保证。

## 7. UI 修改

桌面 UI 以 [`../apps/desktop/lib/theme/app_theme.dart`](../apps/desktop/lib/theme/app_theme.dart) 和现有组件实现为设计源。改动审核工作台时优先保证：

- 视频区域占主要空间；
- 候选切换、播放和审核状态有清晰反馈；
- 导出锁定状态可理解；
- 响应式窗口下不遮挡视频和时间轴；
- 键盘焦点、减少动效和浅色/深色主题可用。

视觉改动请附已确认可以公开的截图；不要提交含本机路径、真实球员或真实比赛视频的截图。

## 8. 协议、数据库和移动 Runtime 变更

修改 Engine 命令时同步：

1. [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md)；
2. Engine handler 和 Flutter client；
3. 协议测试与错误路径测试；
4. 版本兼容说明。

修改 SQLite 时同步：

1. [`architecture/SQLITE_SCHEMA_V1.sql`](architecture/SQLITE_SCHEMA_V1.sql)；
2. storage 初始化和读写逻辑；
3. 旧项目、空值和迁移测试；
4. [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md) 的生命周期说明。

修改移动端 channel、Rust C ABI、ONNX 输入输出或 ABI 时同步 [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md)、Android/iOS 构建说明和目标平台测试。

## 9. 提交前检查

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q
cd apps/desktop
flutter analyze
flutter test
cd ../mobile
flutter analyze
flutter test
cd ../..
git diff --check
git status --short --branch
```

确认：

- [ ] 所有修改文件为 UTF-8，无 BOM；
- [ ] 没有视频、数据、模型、截图、密钥或构建产物；
- [ ] 没有 `/Users/...`、`/home/...` 或 Windows 个人绝对路径；
- [ ] 文档命令与实际目录、脚本参数一致；
- [ ] 中英文入口已同步；
- [ ] 协议、数据库、移动 Runtime 或许可证影响已记录。

## 10. 提交问题和 PR

Bug 报告至少包含版本/commit、系统、运行方式、最小复现步骤、实际结果和预期结果。不要附带未脱敏视频、密钥、个人路径或包含球员个人信息的素材。
