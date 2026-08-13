# Task 15 Report — Home + Import

**Status:** DONE_WITH_CONCERNS
**Commit:** `8bd119c` — `feat(home,import): 重写 Home 与 Import 屏为 Linear 风精致 UI`

## Files changed
- `apps/desktop/lib/features/home/home_screen.dart` — 重写为 `ConsumerWidget`。
- `apps/desktop/lib/features/import_video/import_video_screen.dart` — 重写为 `ConsumerStatefulWidget`,`_RoiCanvas`/`_RoiPainter` 迁移 + 精致化。
- `apps/desktop/test/home_screen_test.dart` — 重写为 `ProviderScope` + `projectProvider.overrideWith`。
- `apps/desktop/lib/router/app_router.dart` — **计划外但必要**:`/home` `/import` 接入真实屏,`_HomeRoute` 保留 init 自动加载;`/review` `/export` 暂留占位等 T16。

## TDD evidence (analyze)
沙盒禁 `flutter test`,GREEN = analyze 干净。

```
$ flutter analyze lib/features/home/home_screen.dart \
                   lib/features/import_video/import_video_screen.dart \
                   test/home_screen_test.dart
Analyzing 3 items...
No issues found! (ran in 2.8s)
```
另附 `app_router.dart` 一起 analyze:同样 0 issue。

## _RoiCanvas 迁移来源 + 精致化点
- **来源**:`git show 3700bbc:apps/desktop/lib/features/import_video/import_video_screen.dart`
  3700bbc 即 baseline commit「UI 重写前 baseline」。`onPanStart`/`onPanUpdate`/`onPanEnd` 与
  `_normalizedRect`(像素 → 归一化 [0,1],clamp 到画布尺寸)**逻辑层原样迁移**,未改动语义。
- **精致化**:
  - 底色 `Color(0xFF202A33)` / `surfaceContainerHighest` → `AppColors.surface2` / `surface3`(disabled)。
  - 边框 `primary.withValues(alpha:.55)` → `indigo`(enabled,1.5px)/ `border`(disabled,1px)。
  - 圆角 `14` → `CsRadius.lg`。
  - `_RoiPainter` 描边 `primary`/strokeWidth 3 → `indigo` 18% 填充 + 2px stroke。
  - **新增四角手柄**:`Rect.fromCenter` 8×8 实心方块画在四个角。
  - 无预览 + disabled 态用 `CsEmptyState`(Lucide `lock`),替换原裸 `Icon(Icons.lock_outline)`。
- roi 初始值/重置:`initState` 读 `state.suggestedRoi`;`ref.listen` 在 `videoPath` 变化时重置(等价旧 `didUpdateWidget`)。

## Home metrics 计算 / 最近项目空错加载
- metrics:`candidates.where(review_status=='goal'/'pending').length`;`video.duration_ms` → `_formatDuration`。
- 最近项目四态(全在 `_RecentProjects`):
  - `recentLoading && recentProjects 空` → `_RecentSkeletonGrid`(LayoutBuilder 切 1/2/3 列,CsSkeleton 占位)。
  - `recentProjects 空 && recentError != null` → `CsEmptyState`(标题「加载最近项目失败」+ 错误描述)。
  - `recentProjects 空 && 无 error` → `CsEmptyState`(标题「还没有项目」+「新建项目」按钮)。
  - 非空 → `_RecentGrid`(LayoutBuilder 切 1/2/3 列,每张 `_ProjectCard` 显示 名/视频名/进球·候选·时长 + goal chip)。
- 工作流 `CsStepIndicator` 五步,completed 按 state 计算(video / roiSource / job==completed / goals>0 / exportHistory 非空)。

## Concerns

1. **计划外修改 router**:brief 的 staging 清单只列 3 文件,但工作树 router 是回退后的旧 callback
   版本(`_HomeRoute`/`_ImportRoute`/`_ReviewRoute`/`_ExportRoute` 传回调给旧 screen 构造函数)。
   新 screen 是无参 `ConsumerWidget`/`ConsumerStatefulWidget`,不更新 router 会导致整工程 analyze 失败。
   故同时重写 router:`/home`→`_HomeRoute`(保留 initState `loadRecentProjects`)→`HomeScreen()`、
   `/import`→`ImportVideoScreen()`、`/review`+`/export`→`_PlaceholderScreen`(等 T16)。
   旧 `review_screen.dart`/`export_screen.dart`(仍是 callback 版,工作树未提交)不再被 router import,留 T16 处理。

2. **init loadRecentProjects 触发**:放在 router `_HomeRoute.initState`(post-frame callback,等价 T14 前
   `_BasketballHighlightAppState` 的做法),而非 HomeScreen 内部 —— 因为 HomeScreen 是 `ConsumerWidget`
   无 initState;`ref.listen` 只响应状态变化不响应首次构建。test 直接 pump `HomeScreen` 时不会触发 load
   (fake state 已预填 recentProjects),也不会触碰 engine/session。

3. **openProject 目录选择器**:`chooseOpenProject` 内部用 `getDirectoryPath`(file_selector),沙盒 test 不点击
   「打开项目」按钮故未触发;`openProject(root)` 在 fake notifier 内只记录 root 字符串,不触碰 engine。

4. **Import ROI state**:`_roi`/`_roiSaved` 为 widget 本地 state;「保存 ROI」成功后置 `_roiSaved=true`;
   `ref.listen` 监听 videoPath 变化时重置 roi/saved(等价旧 didUpdateWidget)。「开始分析」disabled 条件:
   `hasVideo && hasRoi && _roiSaved && !roiBusy`(roiBusy = `state.busy || _savingRoi`)。

5. **测试覆盖**:home_screen_test.dart 3 case(slogan+卡片渲染 / 点卡片触发 openProject / 空态)。Import 测试
   沙盒禁跑 `flutter test`,仅靠 analyze 保证编译;_RoiCanvas pan 手势的交互测试未补(需要 pump + 拖拽 +
   验 saveRoi 回调,且要 mock file_selector 与 engine)。

6. **widget_test.dart / engine_session_test.dart 仍引用旧 `BasketballHighlightApp`**(工作树回退态),
   不在本任务范围,T17 polish 统一修。

## Self-review (YAGNI)
- 没有为「未来多项目对比」「批量操作」等假设需求加抽象 —— `_RecentGrid` 是直接的 LayoutBuilder+Row,
  不做 GridView/滚动控制器(列表短,外层已 SingleChildScrollView)。
- 没有引入 `freezed`/代码生成 —— ProjectState 的 sentinel copyWith 模式保留。
- `_RoiCanvas` 不抽成独立文件 —— 仅 Import 屏使用,私有 widget。
- 没有加 ROI 拖拽手柄的拖动交互(只画四角视觉手柄)—— 旧版没有,本任务只精致化视觉,不扩功能(遵循
  「逻辑层不动」约束)。
- metrics 脚注「本地 SQLite · 原始视频不复制」一行 labelSmall,不展开成额外 UI。
- Import 视频信息行用单行 `labelSmall` tnum 汇总(width×height · fps · 时长 · 编码),不拆成多 CsMetricTile
  —— spec §16.2 只要求一行 tabularFigures 汇总。
