# 审核控制与篮网信号 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让桌面审核的快捷键在视频区域获得焦点后仍稳定工作，并把候选信息、分析范围和篮网运动信号收敛为可验证的行为。

**Architecture:** 审核页用单一根级 `Focus` 处理按键，避免平台视频视图或列表控件抢走 `CallbackShortcuts` 的焦点。分析范围继续只保存源视频时间戳；篮网信号保留为排序和人工审核证据，不能单独阻断“穿筐”候选。

**Tech Stack:** Flutter / Riverpod / media_kit、Python / OpenCV、pytest、flutter_test。

---

### Task 1: 桌面审核按键焦点

**Files:**
- Modify: `apps/desktop/lib/features/review/review_screen.dart`
- Test: `apps/desktop/test/review_screen_test.dart`

- [ ] 写失败用例：根审核 Focus 收到 `↑` 后选择下一个候选；不依赖子控件 Tooltip。
- [ ] 运行 `flutter test test/review_screen_test.dart`，确认旧 `CallbackShortcuts` 在真实焦点移动模型下不足以覆盖该行为。
- [ ] 用根 `Focus.onKeyEvent` 统一消费 `↑↓←→ Space R C X Enter Backspace Cmd/Ctrl+Z`；命中后返回 `KeyEventResult.handled`。
- [ ] 为播放、重播、循环按钮补全含快捷键的 Tooltip。
- [ ] 重跑同一测试，确认通过。

### Task 2: 审核列表与分析范围回归

**Files:**
- Modify: `apps/desktop/test/review_screen_test.dart`
- Modify: `apps/desktop/test/import_video_screen_test.dart`（如已有测试文件则扩展）

- [ ] 写失败用例：候选行必须显示 `时间点` 与 `时长` 两行；选中同一候选触发重播而非切换。
- [ ] 写失败用例：视频时长存在时显示范围选择、全片重置和保存入口。
- [ ] 运行对应 Flutter 测试确认失败。
- [ ] 仅补足现有 UI 暴露的语义标识或行为，不改变源视频时间戳模型。
- [ ] 重跑对应 Flutter 测试确认通过。

### Task 3: 篮网信号的分类边界

**Files:**
- Modify: `src/basketball_highlight/events.py`
- Modify: `src/basketball_highlight/verdict.py`
- Test: `tests/test_events.py`
- Test: `tests/test_verdict.py`

- [ ] 写失败用例：完整穿筐且篮网测量不足时不得被判 `missed` 或因 `net_no_motion` 直接拒绝进入审核队列。
- [ ] 运行 `PYTHONPATH=src:engine/python .venv/bin/python -m pytest tests/test_events.py tests/test_verdict.py -q`，确认旧自动门槛仍把 `net_no_motion` 当硬否决。
- [ ] 将篮网信号限制为 `made/high_precision` 的加分证据；完整穿筐仍生成 `ambiguous/review` 候选，强反证（反弹、横向离开）仍可判 `missed`。
- [ ] 保留白色低饱和高亮掩码、局部光流和可校准 `net_roi`，不加入音频依赖。
- [ ] 重跑 Python 定向测试确认通过。

### Task 4: 全量验证和人工验收包

**Files:**
- Modify: `apps/desktop/test/review_screen_test.dart`

- [ ] 运行 Python 全量测试：`PYTHONPATH=src:engine/python .venv/bin/python -m pytest -q`。
- [ ] 运行 Flutter：`flutter analyze`、`flutter test`、`flutter build macos --debug`。
- [ ] 启动 `build/macos/Build/Products/Debug/desktop.app`。
- [ ] 人工验证：点击视频/Space 暂停，R 重播，↑↓切候选，←→限于当前片段 ±3 秒，循环按钮回到片段起点；导入页调范围后重开项目仍恢复；篮网检测区覆盖完整白网后保存并重新分析。

