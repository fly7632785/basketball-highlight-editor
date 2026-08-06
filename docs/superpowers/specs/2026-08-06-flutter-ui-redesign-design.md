# Courtside Flutter UI 重构设计

- **日期**:2026-08-06
- **状态**:待实现(已通过 brainstorming 定向)
- **范围**:`apps/desktop`(macOS 桌面优先,架构为未来移动端复用做准备)
- **关联**:`design-system/courtside-basketball-highlight-editor/MASTER.md`(历史方向,本设计取代其中色板/字体/组件约定)

---

## 1. 背景与目标

现有 `apps/desktop/lib/app.dart` 是 1034 行单体 `StatefulWidget`,全部状态靠根 `setState` + callback 一路下传(prop drilling),UI 是"Material 3 默认皮肤 + 棕橙 `#D97745` + 系统字体",审美无品牌辨识度,与项目内已有的 `design-system/MASTER.md`(影院黑红 + Fira Code)方向也不一致。

本次目标:

1. **完全重写 UI 为 Linear 风精致深色工具界面**,精致、统一、有产品辨识度。
2. **主题可切换**(跟随系统 / 浅色 / 深色),设计令牌集中管理。
3. **自适应**(桌面优先,移动布局同步落地,未来 app 端直接复用 shell 与业务逻辑)。
4. **架构现代化**:拆分单体,引入 Riverpod(状态)+ go_router(路由),逻辑与 UI 解耦。
5. 提示、空状态、加载、错误等**全状态精致化**。

## 2. 已定决策

| 维度 | 决策 |
|------|------|
| 风格基调 | Linear 精致深色(近黑深蓝 + 靛蓝 + 微妙边框 + 极小圆角) |
| 强调色策略 | 双轨:靛蓝 `#5E6AD2`(UI 强调/选中/进度)+ 篮球橙 `#FF6B2C`(关键 CTA) |
| 状态语义色 | goal 绿 `#3FB950` / pending 黄 `#E3B341` / excluded 灰 `#6B7280` |
| 图标库 | Lucide(`lucide_icons_flutter` 社区活跃 fork,禁用已废弃的原版 `lucide_icons`) |
| 字体 | Inter,静态打包到 `assets/fonts/`,不依赖运行时下载 |
| 架构 | Riverpod + go_router + 自适应 Scaffold + 设计令牌 + 组件库 |
| 主题模式 | system / light / dark 三选一,持久化 |

## 3. 非目标(YAGNI 边界)

- ❌ 不引入 `freezed` / `json_serializable`:数据层继续用 `Map<String, dynamic>` 与 Python engine 对齐,避免代码生成与构建复杂度。
- ❌ 不做多色板可切换(默认靛蓝+篮球橙双轨即终态;若日后需要,`app_colors.dart` 已预留结构)。
- ❌ 不重写 `core/`(engine_session / engine_client / project_session):保留现有业务方法,仅在 providers 层包装。
- ❌ 不引入复杂的动画框架(rive / lottie):用 Flutter 内置 `Animated*` + `Tween`。
- ❌ 移动端暂不实现触摸手势特化(拖拽 ROI 等),仅保证布局自适应可用。

## 4. 技术栈与依赖

新增(`pubspec.yaml`):

```yaml
dependencies:
  flutter_riverpod: ^2.5.1      # 状态管理(选 flutter_riverpod 而非 hooks_riverpod,保持纯 widget)
  go_router: ^14.2.0            # 声明式路由 + StatefulShellRoute
  lucide_icons_flutter: ^3.1.15 # 图标(确认锁定版本,跟踪 Lucide v0.562)
  shared_preferences: ^2.2.0    # 主题模式持久化
  # media_kit / media_kit_video / media_kit_libs_video / file_selector 保留
```

字体:`assets/fonts/Inter-Regular.ttf` / `Inter-Medium.ttf` / `Inter-SemiBold.ttf` / `Inter-Bold.ttf`,pubspec 静态声明。

> 实现注意:本设计**纯手写 `Notifier` / `Provider`,不引入 `riverpod_generator` / `build_runner` / 代码生成**,降低构建复杂度。

## 5. 设计令牌(`theme/tokens.dart`)

```dart
abstract final class Spacing {
  static const double xs = 4, sm = 8, md = 16, lg = 24, xl = 32, xxl = 48;
}

abstract final class CsRadius {
  static const double xs = 4, sm = 6, md = 8, lg = 12, xl = 16, full = 999;
}

abstract final class DurationD {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
}

abstract final class Breakpoints {
  static const double sm = 640, md = 900, lg = 1280, xl = 1536;
}
```

**分层策略(Linear 克制核心)**:深色模式不靠 `elevation` 阴影分层,靠**表面明度梯度 + 1px 边框**。仅 dialog / toast 用阴影。替换现有散落在 `850 / 1050 / 1180 / 680 / 900` 的断点,统一到 `Breakpoints`。

## 6. 配色系统(`theme/app_colors.dart`)

用 `ColorScheme.fromSeed` 生成基线后,手工覆盖关键槽位,确保品牌色与语义色精确。

### 深色(默认)
| 角色 | Hex | 用途 |
|------|-----|------|
| background | `#0B0E14` | 最底层(scaffold) |
| surface | `#121620` | 卡片默认 |
| surface2 | `#1A1F2B` | 悬停 / 次级容器 |
| surface3 | `#23242F` | 选中 / 输入框填充 |
| textPrimary | `#E6E8EE` | 主文字 |
| textSecondary | `#9AA0AC` | 次文字 |
| textTertiary | `#6B7280` | 辅助 / 占位 |
| border | `#23242F` | 1px 分隔 |
| borderStrong | `#31343F` | 聚焦边框 |
| indigo | `#5E6AD2` | UI 强调 / 选中 / 进度 / 聚焦 |
| orange | `#FF6B2C` | 关键 CTA(开始分析 / 导出 / 确认进球) |
| goal | `#3FB950` | 进球状态 |
| pending | `#E3B341` | 待审核状态 |
| excluded | `#6B7280` | 排除状态 |
| error | `#F85149` | 错误 |
| success | `#3FB950` | 成功 |
| warning | `#E3B341` | 警告 |

### 浅色(跟随系统可选)
| 角色 | Hex |
|------|-----|
| background | `#FAFAFA` |
| surface | `#FFFFFF` |
| surface2 | `#F4F5F7` |
| surface3 | `#E9EBEF` |
| textPrimary | `#15171C` |
| textSecondary | `#5A606B` |
| textTertiary | `#8B919B` |
| border | `#E5E7EB` |
| indigo | `#5E6AD2` |
| orange | `#F2601D`(浅色背景下降一档明度,保证对比度 ≥ 4.5:1) |
| goal | `#1F9E47` / pending `#C28A1E` / excluded `#71717A` |

**对比度要求**:所有正文 ≥ 4.5:1,大字 / 图标 ≥ 3:1。浅色 `orange` 必须实测(篮球橙在白底上文字对比度常不足,CTA 按钮文字用白色 + 按钮底色降明度处理)。

### 暴露方式
```dart
class AppColors {
  final Brightness brightness;
  const AppColors(this.brightness);
  // 静态常量 + of(context) 取 Theme 扩展
}
// 通过 ThemeExtension<AppColors> 注入,Widget 内:AppColors.of(context).indigo
```

## 7. 排版系统(`theme/app_theme.dart`)

```dart
TextTheme appTextTheme(Brightness b) => TextTheme(
  displayLarge:   TextStyle(fontFamily: 'Inter', fontSize: 32, fontWeight: w600, height: 1.15, letterSpacing: -0.8),
  displayMedium:  TextStyle(fontSize: 24, fontWeight: w600, letterSpacing: -0.5, height: 1.2),
  titleLarge:     TextStyle(fontSize: 20, fontWeight: w600, letterSpacing: -0.2),
  titleMedium:    TextStyle(fontSize: 16, fontWeight: w600),
  bodyLarge:      TextStyle(fontSize: 14, fontWeight: w400, height: 1.5),
  bodyMedium:     TextStyle(fontSize: 13, fontWeight: w400, height: 1.5),
  labelLarge:     TextStyle(fontSize: 13, fontWeight: w500),
  labelMedium:    TextStyle(fontSize: 12, fontWeight: w500),
  labelSmall:     TextStyle(fontSize: 11, fontWeight: w500),
);
```

**数字样式**:`StyleHelper.numeric(context)` 返回带 `fontFeatures: [FontFeature.tabularFigures()]` 的副本,用于所有时间码、进度百分比、计数(`goalCount` / `pendingCount` / `00:12` / `42%`),避免数字宽度跳动。

## 8. 图标

- 包:`lucide_icons_flutter`,导入 `import 'package:lucide_icons_flutter/lucide_icons_flutter.dart';`
- 命名映射:`Icons.sports_basketball` → `LucideIcons.dribbble`(或 `LucideIcons.basketball` 若可用);`Icons.play_arrow` → `LucideIcons.play`;`Icons.check` → `LucideIcons.check`;`Icons.error_outline` → `LucideIcons.circleAlert`;`Icons.refresh` → `LucideIcons.refreshCw`;等等。
- **统一描边粗细**:Lucide 默认 2px,精致工具感;不在单点覆盖 stroke width。
- 装饰性图标包 `ExcludeSemantics`;功能性图标按钮必带 `tooltip`(Semantics label)。

## 9. 文件与目录结构

```
lib/
  main.dart                       MediaKit.ensureInitialized + runApp(ProviderScope(child: CourtsideApp()))
  app.dart                        MaterialApp.router + theme + CsNoticeOverlay
  router/
    app_router.dart               GoRouter + StatefulShellRoute(4 branches)
  providers/
    session_provider.dart         engine 就绪 / 启动 / EngineClient 生命周期
    project_state.dart            ProjectNotifier: video/job/candidates/recentProjects/exportHistory/busy
    theme_provider.dart           ThemeMode + 持久化(shared_preferences)
    notice_provider.dart          NoticeQueue: 消息列表 + push/dismiss
  theme/
    tokens.dart                   Spacing / CsRadius / DurationD / Breakpoints
    app_colors.dart               AppColors(ThemeExtension,深/浅双组)
    app_theme.dart                ThemeData(brightness) + TextTheme + 组件主题
  components/
    cs_scaffold.dart              自适应 shell 桥接(路由 shell 在 router 里)
    cs_sidebar_shell.dart         NavigationRail 桌面侧栏 + 折叠
    cs_bottom_nav.dart            移动 NavigationBar(预留)
    cs_button.dart                primary / secondary / ghost / danger · sm/md/lg · loading
    cs_card.dart                  default / hover / selected 表面档位
    cs_status_chip.dart           goal / pending / excluded + 图标
    cs_sidebar_item.dart          左 3px 强调条选中
    cs_metric_tile.dart           label / value / icon
    cs_empty_state.dart           icon + title + description + 可选 action
    cs_skeleton.dart              加载占位
    cs_notice.dart + cs_notice_overlay.dart   Toast 组件 + 全局浮层
    cs_progress_track.dart        精致线性进度(分析阶段)
    cs_step_indicator.dart        大序号 + 连接线(Home 工作流 / Import 步骤)
  features/
    home/home_screen.dart         重写
    import_video/import_video_screen.dart  重写
    review/review_screen.dart     重写(核心)
    export/export_screen.dart     重写
  core/
    engine_session.dart           保留
    engine_client.dart            保留
    project_session.dart          保留
```

## 10. 状态管理(Riverpod)

### 10.1 sessionProvider
```dart
final engineClientProvider = Provider<EngineClient>((ref) {
  final client = EngineClient();
  ref.onDispose(client.dispose);
  return client;
});

class EngineBootstrapNotifier extends Notifier<AsyncValue<bool>> {
  Future<void> ensure();          // 等价 _ensureEngine:置 AsyncData(true) 或 AsyncError
  @override
  AsyncValue<bool> build() => const AsyncValue.loading();
}
final engineBootstrapProvider =
    NotifierProvider<EngineBootstrapNotifier, AsyncValue<bool>>(EngineBootstrapNotifier.new);
```
启动逻辑(`_ensureEngine / _findRuntimeRoot / _findPython` 等价)迁入 `EngineBootstrapNotifier.ensure`。用 `AsyncValue<bool>` 表达「就绪 / 加载中 / 失败」,TopBar 胶囊与致命错误屏据此渲染。

### 10.2 ProjectNotifier(project_state.dart)
承载当前所有根 State 字段,迁移现有方法:

```dart
class ProjectState {
  final JsonMap? video;
  final String? videoPath, previewPath;
  final JsonMap? job;
  final List<JsonMap> candidates, recentProjects, exportHistory;
  final bool busy, recentLoading;
  final String? recentError;
  const ProjectState();
}

class ProjectNotifier extends Notifier<ProjectState> {
  Future<void> selectVideo(String path);
  Future<void> openProject(String root);
  Future<void> loadRecentProjects();
  Future<void> saveRoi(Rect normalized);
  Future<void> startAnalysis({int sampleFps = 10, int before = 6, int after = 3});
  Future<void> retryAnalysis();
  Future<void> cancelAnalysis();
  Future<void> reviewCandidate(String id, {required String status});
  Future<void> updateClipRange(String id, int startMs, int endMs);
  Future<void> export(String mode, {String? outputDir, String? outputPath});
  // 成功 / 失败通过 noticeProvider.push(...) 发通知,不再 setState+banner
}
```

`_pollJob` 的流式轮询保留逻辑,在 Notifier 内驱动,每帧更新 `state.job` 与 `state.candidates`。

### 10.3 themeProvider
```dart
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
// 初值读 SharedPreferences;更新时写回。默认 ThemeMode.system。
```

### 10.4 noticeProvider(通知队列)
```dart
class NoticeMessage {
  final String id;                 // 唯一 key
  final NoticeSeverity severity;   // success / error / warning / info
  final String title;
  final String? description;
  final VoidCallback? action;      // 可选:重试 / 撤销
  final String? actionLabel;
  final Duration duration;         // 默认 4s,error 默认 6s
}
final noticeProvider = NotifierProvider<NoticeNotifier, List<NoticeMessage>>(NoticeNotifier.new);
// push(NoticeMessage), dismiss(id), 自动定时 dismiss
```

错误不再走 `_error` banner 字段,而是 `noticeProvider.push(error)`。致命阻塞错误仍可用全屏对话框。

## 11. 路由(go_router)

```dart
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (ctx, state, shell) => CsScaffold(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home',   builder: homeRoute)]),
          StatefulShellBranch(routes: [GoRoute(path: '/import', builder: importRoute)]),
          StatefulShellBranch(routes: [GoRoute(path: '/review', builder: reviewRoute)]),
          StatefulShellBranch(routes: [GoRoute(path: '/export', builder: exportRoute)]),
        ],
      ),
    ],
  );
});
```

- `StatefulShellRoute` 保留侧栏持久化 + 各 branch 独立导航栈(未来移动端 Back 行为正确)。
- 导航通过 `context.go('/review')`,替换现有 `onSectionChanged(AppSection.x)`。
- 深链:`/review` 可加 query(`/review?candidate=ID`)为未来定位候选预留。

## 12. 自适应 Scaffold(`components/cs_scaffold.dart`)

```dart
class CsScaffold extends StatelessWidget {
  final StatefulNavigationShell shell;
  Widget build(context) {
    return LayoutBuilder(builder: (ctx, c) {
      final wide = c.maxWidth >= Breakpoints.md;   // 900
      return Scaffold(
        body: wide
          ? Row(children: [CsSidebarShell(shell: shell, extended: c.maxWidth >= Breakpoints.lg), Expanded(child: _content(shell))])
          : _content(shell),   // 窄:内容在上,底部 BottomNav
        bottomNavigationBar: wide ? null : CsBottomNav(shell: shell),
      );
    });
  }
}
```

- `≥ md(900)`:桌面侧栏(`NavigationRail` 风格自绘,76↔232 折叠,`≥ lg(1280)` 展开)。
- `< md`:移动底栏 `NavigationBar`(Lucide 图标),桌面窄窗也生效。
- TopBar:桌面保留顶部条(标题 + Engine 状态胶囊 + 主题切换 + "本地处理"隐私徽章),移动端折叠为标题。

## 13. 主题系统与切换

- `app.dart`:`MaterialApp.router(theme: appTheme(Brightness.light), darkTheme: appTheme(Brightness.dark), themeMode: ref.watch(themeModeProvider))`。
- 切换:TopBar 的 `PopupMenuButton`(Lucide `sun` / `moon` / `monitor`)→ `themeModeProvider.set(...)`。
- `appTheme(brightness)` 内统一装配:`ColorScheme` + `AppColors`(ThemeExtension)+ `TextTheme` + 组件主题(`cardTheme` / `inputDecorationTheme` / `dividerTheme` / `chipTheme` / `dialogTheme` / `navigationBarTheme`)。
- 持久化 key:`courtside.theme_mode`。

## 14. 通知系统(CsNotice)

### 14.1 视觉
- 位置:屏幕右下角(`Stack` + `Align(bottomRight)`),距边 `Spacing.lg`。
- 多条:垂直堆叠,新消息从底部滑入,最多显示 4 条,超出移除最旧。
- 结构:
  ```
  ┌──────────────────────────────┐
  │▎ ✓  视频已加载                │  ← 左 3px 语义色条 + 图标 + 标题
  │   可以框选篮筐区域            │  ← 描述(可选)
  │                     [ 重试 ] │  ← 可选 action
  └──────────────────────────────┘
  ```
- 尺寸:`width: 360`,`padding: Spacing.md`,圆角 `CsRadius.lg`,1px `border`,浅阴影(仅 toast 用阴影)。
- 背景:`AppColors.surface`(深色 `#121620`),文字 `textPrimary`。
- 左侧强调条 3px,色 = severity。

### 14.2 语义
| severity | 图标(Lucide) | 强调色 |
|----------|--------------|--------|
| success | `circleCheck` | `success #3FB950` |
| error | `circleAlert` | `error #F85149` |
| warning | `triangleAlert` | `warning #E3B341` |
| info | `info` | `indigo #5E6AD2` |

### 14.3 行为
- 入场:`SlideTransition`(Offset(0.3, 0) → 0)+ `FadeTransition`,`DurationD.normal`(220ms,`Curves.easeOut`)。
- 自动消失:`success/info/warning` 4s,`error` 6s,定时器在 `NoticeNotifier.push` 内启动。
- hover 暂停:Widget 内 `MouseRegion` 监听 `onEnter` 暂停计时,`onExit` 恢复。
- 手动关闭:右侧 `LucideIcons.x` 小按钮(无 tooltip 也保留 44×44 命中区)。
- 可选 action:右下文字按钮(`CsButton(variant: ghost, size: sm)`),用于 error 重试 / 撤销。

### 14.4 实现
- `CsNoticeOverlay`:挂在 `MaterialApp.builder` 顶层,`ref.watch(noticeProvider)` 渲染列表。
- 替换所有 `ScaffoldMessenger.showSnackBar` / `_showNotice` / `_error` banner。

## 15. 组件库清单与 API

### CsButton
```dart
enum CsButtonVariant { primary, secondary, ghost, danger }
enum CsButtonSize { sm, md, lg }

class CsButton extends StatelessWidget {
  final CsButtonVariant variant;
  final CsButtonSize size;
  final VoidCallback? onPressed;
  final IconData? icon;            // Lucide
  final Widget label;
  final bool isLoading;            // true 时显示 spinner,label 宽度不跳
  // primary = 篮球橙实心(关键 CTA);secondary = 1px 边框描边;ghost = 纯文字;danger = error 实心
}
```
- hover:`primary` 微亮(+8% 明度),不位移避免布局抖动;`secondary` 背景 → `surface2`。
- focus:`Outline` 2px `indigo` 半透明环。
- loading:左侧图标位置替换为 16px `CircularProgressIndicator(strokeWidth: 2)`。

### CsCard
```dart
class CsCard extends StatelessWidget {
  final Widget child;
  final CsCardTier tier;           // default / hover / selected
  final VoidCallback? onTap;       // 有则包 InkWell + hover 反馈
  final EdgeInsets padding;
}
```
- 背景 = `tier` 映射的表面档位;1px `border`;圆角 `CsRadius.lg`。
- `onTap != null` 时:桌面端 `InkWell` hover → `surface2`,选中 → `surface3` + 左 3px `indigo` 条(列表项用)。

### CsStatusChip
```dart
enum ReviewStatus { goal, pending, excluded }
class CsStatusChip extends StatelessWidget {
  final ReviewStatus status;
  final bool compact;
}
```
- 语义色填充(18% alpha)+ 同色文字 + Lucide 图标(`check` / `hourglass` / `ban`)。

### CsSidebarItem / CsMetricTile / CsEmptyState / CsSkeleton / CsProgressTrack / CsStepIndicator
- `CsSidebarItem`:选中 = 左 3px `indigo` 条 + `indigo` 8% 背景 + 文字 `w600`;`Tooltip` 在折叠态显示标签。
- `CsMetricTile`:`label`(textSecondary)+ `value`(`titleMedium` + tabularFigures + 可选 `icon`)。
- `CsEmptyState`:大号 Lucide 图标(48px,textTertiary)+ title + description + 可选 action(`CsButton ghost`)。
- `CsSkeleton`:`surface2` 圆角块,`Animation` shimmer(200→400ms,尊重 `MediaQuery.disableAnimations`)。
- `CsProgressTrack`:`LinearProgressIndicator` 风格,高 6px,圆角 `full`,轨道 `surface3`,填充 `indigo`,可选阶段标签。
- `CsStepIndicator`:大序号(28px `w700` `indigo`)+ 标题 + 完成态 ✓ + 步骤间连接线(`CustomPaint` 虚线 / 实线)。

## 16. 各 Screen 重构设计

### 16.1 Home(`/home`)
- **Hero 区**:`displayLarge` slogan「把整场比赛,变成你的高光。」+ `bodyLarge` 副标 + 次级隐私徽章。
- **主 CTA 卡**(`CsCard tier:default`,背景 `surface`,但内含主 CTA):「从视频开始」+ 两个按钮:新建项目(`CsButton primary` 篮球橙 + Lucide `plus`)/ 打开项目(`secondary` + `folderOpen`)。
- **Metrics 卡**(次级):三行 `CsMetricTile`(已确认进球 / 待审核 / 视频时长,数字 tabularFigures)+ 「本地 SQLite」脚注。
- 横向布局:`≥ md` 主 CTA(flex 3)+ metrics(flex 1);`< md` 纵向堆叠。
- **最近项目**:`CsMetricTile` 风格卡片网格(`LayoutBuilder` 切 1/2/3 列),每张 `CsCard onTap` 打开,内含项目名 / 视频名 / 状态摘要 / 打开图标。空态用 `CsEmptyState`,加载用 `CsSkeleton`(3 个占位卡,替换当前 spinner+文字)。
- **工作流**:`CsStepIndicator` 五步(01–05)横向排列,带连接线,移除现有散落方块。
- 移除底部孤立的「查看审核工作台」`OutlinedButton`(导航空壳已可去审核)。

### 16.2 Import(`/import`)
- 标题 `displayMedium`「新建分析项目」+ 副标。
- 两步骤(`CsStepIndicator`):「01 选择原始视频」「02 框选篮筐区域」,完成态转 ✓。
- 视频选择区:`CsCard`(次级容器)内 `LucideIcons.film` + 文件名(`SelectableText`,允许复制)+ 「更换视频 / 选择视频」`CsButton secondary`。
- 视频信息行:分辨率 / fps / 时长 / 编码,数字 tabularFigures。
- ROI 画布(`_RoiCanvas` 精致化):
  - 边框 1px `border` + 圆角 `CsRadius.lg`,激活态边框 → `indigo`。
  - 选区:`indigo` 18% 填充 + 2px 描边 + 四角拖拽手柄(`CustomPainter` 小方块)。
  - 空态:`CsEmptyState`(图标 + 提示)。
  - 保留现有 `GestureDetector` pan 逻辑(逻辑层不动,仅视觉重绘)。
- 底部操作:右对齐「开始分析」`CsButton primary` 篮球橙 + `LucideIcons.play`,loading 内嵌 spinner。

### 16.3 Review(`/review`)(核心)
布局:`≥ md` 左预览(flex)+ 右候选队列(390 宽);`< md` 上下堆叠。

#### 分析状态条
- 顶部 `CsCard`(背景 `surface2`):`LucideIcons.sparkles`(`indigo`)或 `circleAlert`(`error`)+ 标题 + 阶段标签(`_stageLabel` 保留)+ 百分比(tabularFigures)+ `CsProgressTrack`。
- 右侧:取消(`secondary`)或重试(`primary` 篮球橙)。
- 失败态:整条 `error` 语义背景(18% alpha)+ 描述。

#### 预览面板(`_PreviewPanel`)
- 视频容器:近黑 `#080B0E`(保留)+ 1px `border` + 圆角。
- 空态 / 加载 / 错误:统一 `CsEmptyState`(图标 + 文案 + 可选取消按钮)。
- 恢复提示条:`warning` 语义 `CsCard`(18% alpha)+ 重试 `ghost` 按钮。
- **三段播放控制**(`_PlayerControls` 重排):
  ```
  [ ━━━━━━━━━━━━━━━━ Slider ━━━━━━━━━━━━━━━━━━ ]
   00:12 / 01:34      ⏮  ▶  ⏭       [ ▸ 播放候选片段 ]
   └─ 时间码(tnum)    └─ 播放组        └─ 片段操作(CsButton secondary)
  ```
  - 时间码:`labelLarge` + tabularFigures + `textSecondary`。
  - 上一 / 播放 / 下一:Lucide `skipBack` / `play` / `pause` / `skipNext`,统一 36×36,`tooltip` 中文。
  - 片段操作:`CsButton secondary` + Lucide `film` / `square`(播放中)。
- 候选信息行:`labelSmall` + tabularFigures(候选时间 · 片段范围)。

#### 候选队列(`_QueuePanel`)
- 顶部:「候选审核」(`titleMedium`)+ `CsStatusChip`(N 待审核)+ 导出按钮(底部固定 `CsButton primary` 篮球橙 + `arrowUpRight`,无 goal 时 disabled)。
- 候选项(`CsCard onTap`,选中态):
  - 左 3px `indigo` 强调条(选中)+ 背景 `surface3`。
  - 头行:`#1`(`titleMedium`)+ 时间(tabularFigures)+ `CsStatusChip`。
  - 操作行:**进球 = `CsButton primary`(篮球橙实心,语义上也是"确认主操作")+ `LucideIcons.check`**;排除 = `CsButton secondary` + `LucideIcons.ban`。两个 `Expanded` 等宽并排,但主次靠 variant 区分(替换现有两个都是 OutlinedButton 的扁平感)。
  - 「调整片段范围」:`CsButton ghost sm` + `LucideIcons.slidersHorizontal`,触发对话框(见下)。
  - 选中切换:`AnimatedContainer DurationD.normal`。
- 空态:`CsEmptyState`(Lucide `inbox` + 双行文案)。
- 调整范围对话框:`Dialog` 重做为精致 `CsCard` 风格 + 两个 `TextField`(开始 / 结束 ms,数字键盘)+ 取消 / 保存(`primary`)。保留校验 `e > s`。

#### 全局反馈
- 分析开始 / 完成 / 取消 / 失败 → `noticeProvider.push(...)`(CsNotice),移除现有 `_showNotice` 与 `_error` banner。
- 审核操作成功 → CsNotice success(「已确认进球」/「已排除候选」)。

### 16.4 Export(`/export`)
- 标题 `displayMedium`「导出集锦」+ 副标。
- 汇总 `CsCard`:四行 `CsMetricTile`(已确认片段数 / 合计时长 / 输出编码 / 处理方式,数字 tabularFigures)。
- 双 CTA:合并导出(`CsButton primary` 篮球橙 + `LucideIcons.merge`) / 分别导出(`CsButton secondary` + `LucideIcons.files`),loading 内嵌。
- 说明文字(`bodySmall textSecondary`):「只使用已确认候选…」。
- 返回审核:`CsButton ghost` + `arrowLeft`。
- 历史:每条 `CsCard`(`LucideIcons.history` + 模式 / 片段数 / 时长 / 处理耗时 + 输出路径 `SelectableText` + 时间),`labelSmall` tabularFigures。
- 完成通知:CsWith CsNotice success(「导出完成」,描述列文件)。

## 17. 错误与空状态

- **可恢复操作错误**(分析失败 / 网络错误 / 打开项目失败):CsNotice `error` + 重试 action。
- **致命错误**(engine 未找到 / Python 缺失):全屏 `CsEmptyState` 居中 + 「打开运行时目录 / 查看文档」操作。
- **列表空态**:`CsEmptyState`(最近项目 / 候选队列 / 导出历史)。
- **加载态**:`CsSkeleton` 替换 `CircularProgressIndicator + 文字`(最近项目卡片网格、候选首次加载)。
- 视频加载错误:预览区内联 `CsEmptyState`(`error` 图标 + 描述)。

## 18. 动效规范

- 所有状态切换 ≥ 150ms,≤ 320ms;`Curves.easeOut` 入场,`easeIn` 退场。
- hover 反馈:`DurationD.fast`(150ms)色变,不用 `scale`(避免布局抖动)。
- 页面切换:`StatefulShellRoute` 默认 + 自定义 `AnimatedSwitcher`(`DurationD.normal`)。
- 列表选中:`AnimatedContainer DurationD.normal`。
- CsNotice:slide + fade(见 §14.3)。
- 尊重 `MediaQuery.disableAnimations`:CsSkeleton shimmer / 页面切换在禁用动画时降级为瞬切。

## 19. 可访问性

- 所有图标按钮带 `tooltip`(中文)。
- 装饰图标 `ExcludeSemantics`;功能图标 `Semantics(label:...)`。
- `CsStatusChip` 不只靠颜色:必带图标 + 文字。
- 对比度:见 §6,浅色 `orange` 实测。
- 桌面键盘:所有 `CsButton` / `CsCard onTap` 可 Tab 聚焦,Enter 触发;`focus` 可见(2px `indigo` 环)。
- 文字缩放:布局不卡死行高(`MediaQuery.textScalerOf`)。
- 路径 / 时间码用 `SelectableText`。

## 20. 落地阶段

| 阶段 | 内容 | 产出 |
|------|------|------|
| P1 地基 | 依赖、`theme/`(tokens / colors / theme)、Inter 静态打包 | `MaterialApp` 能跑出精致深色基底 |
| P2 积木 | `components/` 全套 Cs* 组件 + CsNoticeOverlay | 组件可独立预览 / 测试 |
| P3 骨架 | router(go_router)+ providers(session / project / theme / notice)+ 拆 `app.dart` | 路由可切 4 页,业务逻辑接通,通知工作 |
| P4 逐屏 | Home → Import → Export → **Review**(最后,最复杂) | 4 屏精致 UI |
| P5 polish | 自适应验证(窄窗)、主题切换验证(浅色对比度)、动效、空 / 错 / 加载态 | 全状态精致 |

> Review 放最后:依赖 P1–P3 全部就绪,且是交互最密的一屏。

## 21. 测试策略

- **组件单元测试**:每个 `Cs*` 组件 `goldentests` 或 widget test(变体 / 尺寸 / 状态:default / hover / selected / disabled / loading)。
- **ProjectNotifier 单元测试**:selectVideo / openProject / startAnalysis / reviewCandidate / updateClipRange 状态迁移与 notice 事件,用假 `ProjectSession`(允许 mock,因 engine 是外部进程;业务逻辑层是内部代码)。
- **主题测试**:深 / 浅双主题渲染无溢出,关键文字对比度断言。
- **路由测试**:4 branch 切换、初始路由、深链 query。
- **现有 `tests/test_*.py`**:不涉及(engine 是 Python,本次仅 Flutter 层)。
- 改动前先 `flutter analyze` + 现有测试(如有)建立基线。

> 注:CLAUDE.md 偏好"不 mock 数据库用真实连接"。此处 `EngineClient` 是子进程通信,非数据库;`ProjectNotifier` 单元测试对 `ProjectSession` 用接口桩(或真起 engine 视 CI 能力)。逻辑层(状态迁移、notice 触发、ROI 归一化)是真实业务逻辑,必测。

## 22. 风险与缓解

| 风险 | 缓解 |
|------|------|
| `lucide_icons_flutter` 社区 fork 失维 | 锁定版本;组件库封装 `LucideIcons` 引用为单点,失维可整体替换(如 `material_symbols_icons`) |
| Inter 静态打包增大体积 | 仅打 4 个字重(Regular/Medium/SemiBold/Bold),~800KB,桌面可接受 |
| 浅色篮球橙对比度不足 | CTA 文字用白色 + 底色降明度 `#F2601D`;非 CTA 场景不用橙做文字色 |
| Riverpod 学习曲线 | 选 `flutter_riverpod` 手写 Notifier,不引入代码生成,API 简单 |
| 移动端布局未实测 | P5 阶段在窄窗(< 640)实机验证;移动手势特化列为未来工作 |
| go_router 大版本迁移 | 锁 `^14.2.0`,跟随官方稳定线 |

---

## 附:与现有代码的迁移映射

| 现有(`app.dart`) | 新位置 |
|------|------|
| `_BasketballHighlightAppState` 全部字段 | `providers/project_state.dart` `ProjectState` |
| `_ensureEngine / _findRuntimeRoot / _findPython` | `providers/session_provider.dart` |
| `_selectVideo / _openProject / _loadRecentProjects / _saveRoi / _startAnalysis / _pollJob / _retryAnalysis / _cancelAnalysis / _refreshCandidates / _reviewCandidate / _updateClipRange / _export / _refreshExportHistory` | `ProjectNotifier` 同名方法 |
| `_showNotice / _error / _ErrorBanner` | `noticeProvider` + `CsNoticeOverlay`(删除 banner) |
| `AppShell / _Sidebar / _TopBar` | `router/` shell + `components/cs_scaffold.dart` + `cs_sidebar_shell.dart` |
| `AppSection` enum | go_router branches(`/home` `/import` `/review` `/export`) |
| `core/*` | **不动** |
| `_RoiPainter / _RoiCanvas` | `features/import_video/` 内保留逻辑,视觉重绘 |
