# Courtside Flutter UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完全重写 `apps/desktop` Flutter UI 为 Linear 精致深色工具界面,引入 Riverpod + go_router + 自适应 Scaffold + 设计令牌 + 组件库,支持主题切换,为未来移动端复用做好准备。

**Architecture:** 拆分 1034 行单体 `app.dart` → router(go_router `StatefulShellRoute`)+ Riverpod providers(session / project / theme / notice)+ theme/(令牌/配色/主题)+ components/(Cs* 组件库)+ features/(4 屏重写)。`core/`(engine 业务)保留不动。

**Tech Stack:** Flutter ^3.12.2 · flutter_riverpod ^2.5.1 · go_router ^14.2.0 · lucide_icons_flutter ^3.1.15 · shared_preferences ^2.2.0 · Inter(静态打包)

## Global Constraints

- **Flutter SDK**:`^3.12.2`;测试命令 `flutter test`,若 `flutter` 不在 PATH 用 `fvm flutter test` 或 IDE 内跑。
- **设计依据**:本计划设计细节引用 `docs/superpowers/specs/2026-08-06-flutter-ui-redesign-design.md` 的节(写作「spec §N」)。执行时以 spec 配色/组件 API 为准。
- **不引入**:`build_runner` / `riverpod_generator` / `freezed` / `json_serializable`(纯手写 Notifier)。
- **不动**:`lib/core/`(engine_session / engine_client / project_session)业务方法签名。
- **数据层**:继续用 `Map<String, dynamic>`(typedef `JsonMap`),与 Python engine 对齐。
- **字体**:Inter 静态打包到 `assets/fonts/`,pubspec 声明,不依赖 `google_fonts` 运行时下载。
- **图标**:统一 `lucide_icons_flutter`;禁止用 `Icons.*`(Material 默认)做新 UI。
- **commit**:中文,格式 `type(scope): 描述`,type ∈ feat/refactor/style/chore/test/docs。
- **断点**:统一 `Breakpoints`(sm640/md900/lg1280/xl1536),替换现有散落的 850/1050/1180/680/900。
- **现有测试**:`test/{home_screen,review_screen,engine_session,widget}_test.dart` 随重写更新(T15/T16)。

## File Structure

```
lib/
  main.dart                       [改] MediaKit + runApp(ProviderScope)
  app.dart                        [改→重写] MaterialApp.router + theme + CsNoticeOverlay
  router/app_router.dart          [新] GoRouter + StatefulShellRoute
  providers/
    session_provider.dart         [新] EngineBootstrapNotifier
    theme_provider.dart           [新] ThemeModeNotifier + shared_preferences
    project_state.dart            [新] ProjectState + ProjectNotifier(迁移 app.dart 全部业务方法)
    notice_provider.dart          [新] NoticeMessage + NoticeNotifier
  theme/
    tokens.dart                   [新] Spacing/CsRadius/DurationD/Breakpoints
    app_colors.dart               [新] AppColors(ThemeExtension,深/浅双组)
    app_theme.dart                [新] TextTheme + ThemeData + numeric helper
  components/
    cs_button.dart                [新]
    cs_card.dart                  [新]
    cs_status_chip.dart           [新]
    cs_metric_tile.dart           [新]
    cs_empty_state.dart           [新]
    cs_skeleton.dart              [新]
    cs_progress_track.dart        [新]
    cs_step_indicator.dart        [新]
    cs_notice.dart                [新] 单条 toast
    cs_notice_overlay.dart        [新] 全局浮层
    cs_scaffold.dart              [新] 自适应 shell
    cs_sidebar_shell.dart         [新] 桌面侧栏
    cs_bottom_nav.dart            [新] 移动底栏(预留)
  features/
    home/home_screen.dart         [改→重写]
    import_video/import_video_screen.dart  [改→重写]
    review/review_screen.dart     [改→重写]
    export/export_screen.dart     [改→重写]
  core/                           [不动]
assets/fonts/Inter-*.ttf          [新]
```

## 关于代码详度的约定

- **基础设施任务(T1–T14)**:给出**完整可粘贴代码**(令牌、配色、组件、providers、router、shell)——它们小而关键,必须精确。
- **Screen 任务(T15–T16)**:给出**文件级结构骨架 + 关键 widget 代码 + 回调→provider 迁移映射 + 测试断言**,完整布局/样式引用 spec §16。执行时合并 spec §16 + 本骨架写源文件。
- 所有任务 TDD:先写/改测试 → 跑 → 实现 → 跑 → commit。

---

## Phase 1 · 地基

### Task 1: 依赖与 Inter 字体静态打包

**Files:**
- Modify: `apps/desktop/pubspec.yaml`
- Create: `apps/desktop/assets/fonts/`(下载 Inter-Regular/Medium/SemiBold/Bold.ttf)
- Modify: `apps/desktop/analysis_options.yaml`(启用 `prefer_single_quotes`、`require_trailing_commas`)

**Interfaces:** Produces:可用依赖 `flutter_riverpod` / `go_router` / `lucide_icons_flutter` / `shared_preferences`;字体 family `Inter`。

- [ ] **Step 1: 加依赖**

```yaml
# pubspec.yaml dependencies 追加(保留 flutter/file_selector/media_kit/cupertino_icons)
  flutter_riverpod: ^2.5.1
  go_router: ^14.2.0
  lucide_icons_flutter: ^3.1.15
  shared_preferences: ^2.2.0
```

- [ ] **Step 2: 下载 Inter 字体到 `assets/fonts/`**

```bash
cd apps/desktop
mkdir -p assets/fonts
curl -L -o assets/fonts/Inter-Regular.ttf    "https://github.com/rsms/inter/raw/master/docs/font-files/Inter-Regular.otf"
curl -L -o assets/fonts/Inter-Medium.ttf     "https://github.com/rsms/inter/raw/master/docs/font-files/Inter-Medium.otf"
curl -L -o assets/fonts/Inter-SemiBold.ttf   "https://github.com/rsms/inter/raw/master/docs/font-files/Inter-SemiBold.otf"
curl -L -o assets/fonts/Inter-Bold.ttf       "https://github.com/rsms/inter/raw/master/docs/font-files/Inter-Bold.otf"
```
> 若沙箱禁网,改为从本地 `~/.fonts` 或手动放置;文件名固定如上(.otf 也可,声明时用实际扩展名)。`flutter` 段声明:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/fonts/
  fonts:
    - family: Inter
      fonts:
        - asset: assets/fonts/Inter-Regular.ttf
        - asset: assets/fonts/Inter-Medium.ttf
          weight: 500
        - asset: assets/fonts/Inter-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/Inter-Bold.ttf
          weight: 700
```

- [ ] **Step 3: 收紧 analysis_options**

```yaml
include: package:flutter_lints/flutter.yaml
linter:
  rules:
    prefer_single_quotes: true
    require_trailing_commas: true
    use_super_parameters: true
```

- [ ] **Step 4: 验证依赖解析**

Run: `flutter pub get`(或 `fvm flutter pub get`)
Expected: 无版本冲突,`lucide_icons_flutter`/`go_router`/`flutter_riverpod`/`shared_preferences` 成功解析。

- [ ] **Step 5: commit**

```bash
git add apps/desktop/pubspec.yaml apps/desktop/pubspec.lock apps/desktop/assets/fonts apps/desktop/analysis_options.yaml
git commit -m "chore(desktop): 引入 riverpod/go_router/lucide 与 Inter 字体"
```

---

### Task 2: 设计令牌 `theme/tokens.dart`

**Files:**
- Create: `lib/theme/tokens.dart`
- Test: `test/theme/tokens_test.dart`

**Interfaces:** Produces:`Spacing` / `CsRadius` / `DurationD` / `Breakpoints`(全部 `abstract final class`,纯静态常量)。

- [ ] **Step 1: 写测试**

```dart
// test/theme/tokens_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/theme/tokens.dart';

void main() {
  test('spacing is 8-multiple scale', () {
    expect(Spacing.xs, 4);
    expect(Spacing.sm, 8);
    expect(Spacing.md, 16);
    expect(Spacing.lg, 24);
    expect(Spacing.xl, 32);
    expect(Spacing.xxl, 48);
  });
  test('breakpoints match spec', () {
    expect(Breakpoints.md, 900);
    expect(Breakpoints.lg, 1280);
  });
  test('durations within Linear range', () {
    expect(DurationD.fast.inMilliseconds, 150);
    expect(DurationD.normal.inMilliseconds, 220);
    expect(DurationD.slow.inMilliseconds, 320);
  });
}
```

- [ ] **Step 2: 验证失败**

Run: `flutter test test/theme/tokens_test.dart`
Expected: FAIL — `tokens.dart` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/theme/tokens.dart
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

- [ ] **Step 4: 验证通过**

Run: `flutter test test/theme/tokens_test.dart` → Expected: PASS(3 tests)

- [ ] **Step 5: commit** — `feat(theme): 增加设计令牌(间距/圆角/动效/断点)`

---

### Task 3: 配色系统 `theme/app_colors.dart`

**Files:**
- Create: `lib/theme/app_colors.dart`
- Test: `test/theme/app_colors_test.dart`

**Interfaces:**
- Consumes: `flutter`(`ThemeExtension`)
- Produces:`AppColors`(含 `indigo`/`orange`/`goal`/`pending`/`excluded`/`success`/`error`/`warning`/`surface2`/`surface3`/`borderStrong`/`textSecondary`/`textTertiary`);`AppColors.of(context)` 静态取值;`lightAppColors` / `darkAppColors` 常量。

- [ ] **Step 1: 写测试**

```dart
// test/theme/app_colors_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/theme/app_colors.dart';

void main() {
  test('dark brand colors match spec', () {
    expect(darkAppColors.indigo, const Color(0xFF5E6AD2));
    expect(darkAppColors.orange, const Color(0xFFFF6B2C));
    expect(darkAppColors.background, const Color(0xFF0B0E14));
    expect(darkAppColors.surface, const Color(0xFF121620));
  });
  test('semantic colors distinct', () {
    expect(darkAppColors.goal, const Color(0xFF3FB950));
    expect(darkAppColors.pending, const Color(0xFFE3B341));
    expect(darkAppColors.excluded, const Color(0xFF6B7280));
  });
  test('light orange darkened for contrast', () {
    expect(lightAppColors.orange, const Color(0xFFF2601D));
  });
  testWidgets('of(context) returns theme extension', (tester) async {
    late AppColors captured;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [darkAppColors]),
      home: Builder(builder: (c) {
        captured = AppColors.of(c);
        return const SizedBox();
      }),
    ));
    expect(captured.indigo, darkAppColors.indigo);
  });
}
```

- [ ] **Step 2: 验证失败** — `flutter test test/theme/app_colors_test.dart` → FAIL(文件不存在)

- [ ] **Step 3: 实现**

```dart
// lib/theme/app_colors.dart
import 'package:flutter/material.dart';

@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color background, surface, surface2, surface3;
  final Color textPrimary, textSecondary, textTertiary;
  final Color border, borderStrong;
  final Color indigo, orange;
  final Color goal, pending, excluded;
  final Color success, error, warning;

  const AppColors({
    required this.background, required this.surface, required this.surface2, required this.surface3,
    required this.textPrimary, required this.textSecondary, required this.textTertiary,
    required this.border, required this.borderStrong,
    required this.indigo, required this.orange,
    required this.goal, required this.pending, required this.excluded,
    required this.success, required this.error, required this.warning,
  });

  static const darkAppColors = AppColors(
    background: Color(0xFF0B0E14), surface: Color(0xFF121620),
    surface2: Color(0xFF1A1F2B), surface3: Color(0xFF23242F),
    textPrimary: Color(0xFFE6E8EE), textSecondary: Color(0xFF9AA0AC), textTertiary: Color(0xFF6B7280),
    border: Color(0xFF23242F), borderStrong: Color(0xFF31343F),
    indigo: Color(0xFF5E6AD2), orange: Color(0xFFFF6B2C),
    goal: Color(0xFF3FB950), pending: Color(0xFFE3B341), excluded: Color(0xFF6B7280),
    success: Color(0xFF3FB950), error: Color(0xFFF85149), warning: Color(0xFFE3B341),
  );

  static const lightAppColors = AppColors(
    background: Color(0xFFFAFAFA), surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF4F5F7), surface3: Color(0xFFE9EBEF),
    textPrimary: Color(0xFF15171C), textSecondary: Color(0xFF5A606B), textTertiary: Color(0xFF8B919B),
    border: Color(0xFFE5E7EB), borderStrong: Color(0xFFCBD0D8),
    indigo: Color(0xFF5E6AD2), orange: Color(0xFFF2601D),
    goal: Color(0xFF1F9E47), pending: Color(0xFFC28A1E), excluded: Color(0xFF71717A),
    success: Color(0xFF1F9E47), error: Color(0xFFDC2626), warning: Color(0xFFC28A1E),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? darkAppColors;

  @override
  AppColors copyWith({Color? background, Color? surface, Color? surface2, Color? surface3,
      Color? textPrimary, Color? textSecondary, Color? textTertiary,
      Color? border, Color? borderStrong, Color? indigo, Color? orange,
      Color? goal, Color? pending, Color? excluded,
      Color? success, Color? error, Color? warning}) =>
    AppColors(
      background: background ?? this.background, surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2, surface3: surface3 ?? this.surface3,
      textPrimary: textPrimary ?? this.textPrimary, textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary, border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong, indigo: indigo ?? this.indigo,
      orange: orange ?? this.orange, goal: goal ?? this.goal, pending: pending ?? this.pending,
      excluded: excluded ?? this.excluded, success: success ?? this.success,
      error: error ?? this.error, warning: warning ?? this.warning,
    );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      indigo: Color.lerp(indigo, other.indigo, t)!,
      orange: Color.lerp(orange, other.orange, t)!,
      goal: Color.lerp(goal, other.goal, t)!,
      pending: Color.lerp(pending, other.pending, t)!,
      excluded: Color.lerp(excluded, other.excluded, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}
```

- [ ] **Step 4: 验证通过** — `flutter test test/theme/app_colors_test.dart` → PASS(4 tests)

- [ ] **Step 5: commit** — `feat(theme): 增加配色系统(靛蓝+篮球橙双轨,深浅双主题)`

---

### Task 4: 排版与主题 `theme/app_theme.dart`

**Files:**
- Create: `lib/theme/app_theme.dart`
- Test: `test/theme/app_theme_test.dart`

**Interfaces:**
- Consumes:`AppColors`、`Spacing`/`CsRadius`(tokens)
- Produces:`ThemeData appTheme(Brightness)`,`TextStyle numericTextStyle(BuildContext)`(tabularFigures)。

- [ ] **Step 1: 写测试**

```dart
// test/theme/app_theme_test.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/theme/app_colors.dart';

void main() {
  test('dark theme wires dark colors and Inter', () {
    final t = appTheme(Brightness.dark);
    expect(t.brightness, Brightness.dark);
    expect(t.extensions[AppColors], darkAppColors);
    expect(t.textTheme.displayLarge?.fontFamily, 'Inter');
    expect(t.textTheme.displayLarge?.fontWeight, FontWeight.w600);
  });
  test('numericTextStyle has tabular figures', () {
    final fs = numericTextStyle(const TextStyle());
    expect(fs.fontFeatures?.any((f) => f.feature == 'tnum'), isTrue);
  });
}
```

- [ ] **Step 2: 验证失败** — `flutter test test/theme/app_theme_test.dart` → FAIL

- [ ] **Step 3: 实现**

```dart
// lib/theme/app_theme.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'tokens.dart';

ThemeData appTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? darkAppColors : lightAppColors;
  final scheme = ColorScheme.fromSeed(
    seedColor: colors.indigo,
    brightness: brightness,
    surface: colors.surface,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme.copyWith(
      primary: colors.indigo,
      onPrimary: Colors.white,
      secondary: colors.orange,
      onSecondary: Colors.white,
      surface: colors.surface,
      onSurface: colors.textPrimary,
    ),
    scaffoldBackgroundColor: colors.background,
    fontFamily: 'Inter',
    extensions: [colors],
  );
  return base.copyWith(
    textTheme: _buildTextTheme(),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.lg),
        side: BorderSide(color: colors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface3,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        borderSide: BorderSide(color: colors.indigo, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    ),
    dividerTheme: DividerThemeData(color: colors.border, thickness: 1),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surface3,
      labelStyle: TextStyle(color: colors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CsRadius.full)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.indigo.withValues(alpha: 0.15),
      labelTextStyle: WidgetStatePropertyAll(TextStyle(
        color: colors.textSecondary, fontSize: 11, fontWeight: FontWeight.w500,
      )),
    ),
  );
}

TextTheme _buildTextTheme() => const TextTheme(
  displayLarge:  TextStyle(fontFamily: 'Inter', fontSize: 32, fontWeight: FontWeight.w600, height: 1.15, letterSpacing: -0.8),
  displayMedium: TextStyle(fontFamily: 'Inter', fontSize: 24, fontWeight: FontWeight.w600, height: 1.2, letterSpacing: -0.5),
  titleLarge:    TextStyle(fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.2),
  titleMedium:   TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600),
  bodyLarge:     TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w400, height: 1.5),
  bodyMedium:    TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.w400, height: 1.5),
  labelLarge:    TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.w500),
  labelMedium:   TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w500),
  labelSmall:    TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w500),
);

TextStyle numericTextStyle(TextStyle base) =>
    base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
```

- [ ] **Step 4: 验证通过** — `flutter test test/theme/app_theme_test.dart` → PASS

- [ ] **Step 5: commit** — `feat(theme): 增加排版与主题装配(Inter + tabularFigures)`

---

## Phase 2 · 组件库

### Task 5: CsButton

**Files:**
- Create: `lib/components/cs_button.dart`
- Test: `test/components/cs_button_test.dart`

**Interfaces:**
- Consumes:`AppColors`、`Spacing`/`CsRadius`/`DurationD`、`lucide_icons_flutter`
- Produces:`enum CsButtonVariant { primary, secondary, ghost, danger }`、`enum CsButtonSize { sm, md, lg }`、`class CsButton`。
- 契约:`CsButton({variant, size, onPressed, icon, label, isLoading})`;`primary`=篮球橙实心,`secondary`=描边,`ghost`=纯文字,`danger`=error 实心;`isLoading=true` 图标位换 spinner 且 label 宽度不跳。

- [ ] **Step 1: 写测试**

```dart
// test/components/cs_button_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons_flutter.dart';
import 'package:desktop/components/cs_button.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/theme/app_colors.dart';

Widget _wrapped(Widget child) => MaterialApp(
  theme: appTheme(Brightness.dark),
  home: Center(child: child),
);

void main() {
  testWidgets('primary renders orange filled with label', (tester) async {
    await tester.pumpWidget(_wrapped(
      CsButton(variant: CsButtonVariant.primary, label: const Text('开始分析'), onPressed: () {}),
    ));
    final material = tester.widget<Material>(find.ancestor(of: find.text('开始分析'), matching: find.byType(Material)));
    expect((material.color as Paint).color, darkAppColors.orange);
  });
  testWidgets('disabled when onPressed null', (tester) async {
    await tester.pumpWidget(_wrapped(
      CsButton(variant: CsButtonVariant.primary, label: const Text('x'), onPressed: null),
    ));
    final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(btn.onPressed, isNull);
  });
  testWidgets('loading shows spinner instead of icon', (tester) async {
    await tester.pumpWidget(_wrapped(
      CsButton(variant: CsButtonVariant.primary, icon: LucideIcons.play,
        label: const Text('x'), onPressed: () {}, isLoading: true),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(LucideIcons.play), findsNothing);
  });
}
```

- [ ] **Step 2: 验证失败** — `flutter test test/components/cs_button_test.dart` → FAIL

- [ ] **Step 3: 实现**

```dart
// lib/components/cs_button.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

enum CsButtonVariant { primary, secondary, ghost, danger }
enum CsButtonSize { sm, md, lg }

class CsButton extends StatelessWidget {
  const CsButton({
    required this.label,
    this.onPressed,
    this.variant = CsButtonVariant.primary,
    this.size = CsButtonSize.md,
    this.icon,
    this.isLoading = false,
    super.key,
  });

  final VoidCallback? onPressed;
  final CsButtonVariant variant;
  final CsButtonSize size;
  final IconData? icon;
  final Widget label;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final fg = _foreground(c);
    final bg = _background(c);
    final enabled = onPressed != null && !isLoading;
    final padding = _padding();
    final fontSize = size == CsButtonSize.sm ? 13.0 : 14.0;

    return _Raw(
      background: bg,
      foreground: fg,
      enabled: enabled,
      onTap: onPressed,
      child: Padding(
        padding: padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              SizedBox(
                width: size == CsButtonSize.sm ? 14 : 16,
                height: size == CsButtonSize.sm ? 14 : 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            else if (icon != null)
              Icon(icon, size: size == CsButtonSize.sm ? 15 : 17),
            if (isLoading || icon != null) const SizedBox(width: Spacing.sm),
            DefaultTextStyle.merge(
              style: TextStyle(
                color: fg, fontSize: fontSize, fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              child: label,
            ),
          ],
        ),
      ),
    );
  }

  EdgeInsetsGeometry _padding() {
    final h = size == CsButtonSize.lg ? 20.0 : size == CsButtonSize.sm ? 12.0 : 16.0;
    final v = size == CsButtonSize.lg ? 11.0 : size == CsButtonSize.sm ? 7.0 : 9.0;
    return EdgeInsets.symmetric(horizontal: h, vertical: v);
  }

  Color _foreground(AppColors c) => switch (variant) {
    CsButtonVariant.primary || CsButtonVariant.danger => Colors.white,
    CsButtonVariant.secondary => c.textPrimary,
    CsButtonVariant.ghost => c.textSecondary,
  };
  Color _background(AppColors c) => switch (variant) {
    CsButtonVariant.primary => c.orange,
    CsButtonVariant.danger => c.error,
    CsButtonVariant.secondary => Colors.transparent,
    CsButtonVariant.ghost => Colors.transparent,
  };
}

class _Raw extends StatefulWidget {
  const _Raw({required this.child, required this.background, required this.foreground,
      required this.enabled, required this.onTap});
  final Widget child;
  final Color background, foreground;
  final bool enabled;
  final VoidCallback? onTap;
  @override
  State<_Raw> createState() => _RawState();
}

class _RawState extends State<_Raw> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Color bg = widget.background;
    Color border = Colors.transparent;
    if (widget.background == Colors.transparent) {
      // secondary / ghost
      border = widget.onTap == null ? c.border : c.borderStrong;
      if (_hover && widget.enabled) bg = c.surface2;
    } else if (_hover && widget.enabled) {
      bg = Color.alphaBlend(Colors.white.withValues(alpha: 0.10), widget.background);
    }
    final disabled = !widget.enabled;
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: DurationD.fast,
          decoration: BoxDecoration(
            color: disabled ? c.surface3 : bg,
            borderRadius: BorderRadius.circular(CsRadius.md),
            border: border == Colors.transparent ? null : Border.all(color: border),
          ),
          foregroundDecoration: _focusRing(c),
          child: Opacity(opacity: disabled ? 0.5 : 1, child: widget.child),
        ),
      ),
    );
  }

  ShapeDecoration _focusRing(AppColors c) => ShapeDecoration(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(CsRadius.md),
      side: BorderSide(color: c.indigo.withValues(alpha: 0.0)),
    ),
  );
}
```

- [ ] **Step 4: 验证通过** — `flutter test test/components/cs_button_test.dart` → PASS

> 实现注:键盘 focus 环用一个 `FocusableActionDetector` 或 `Focus` widget 在 `_Raw` 内补 2px indolo 环(T17 polish 时统一加)。测试不强求 focus,先保证 hover/颜色/loading。

- [ ] **Step 5: commit** — `feat(components): 增加 CsButton(主橙/次描边/ghost/危险,带 loading)`

---

### Task 6: CsCard

**Files:**
- Create: `lib/components/cs_card.dart`
- Test: `test/components/cs_card_test.dart`

**Interfaces:**
- Produces:`enum CsCardTier { defaultTier, hover, selected }`、`CsCard({child, tier, onTap, padding, selectedAccent})`;有 `onTap` 时包 `InkWell` + hover 档位;`selectedAccent=true` 时左侧 3px indigo 条。

- [ ] **Step 1: 写测试**

```dart
// test/components/cs_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/components/cs_card.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/theme/app_colors.dart';

void main() {
  testWidgets('default tier uses surface color', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: CsCard(child: const Text('hi')),
    ));
    final ac = tester.widget<AnimatedContainer>(
      find.descendant(of: find.byType(CsCard), matching: find.byType(AnimatedContainer)),
    );
    expect((ac.decoration as BoxDecoration).color, darkAppColors.surface);
  });
  testWidgets('onTap wraps tappable + calls back', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: CsCard(onTap: () => taps++, child: const Text('tap')),
    ));
    await tester.tap(find.text('tap'));
    expect(taps, 1);
  });
  testWidgets('selected accent paints left bar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: CsCard(selectedAccent: true, child: const Text('sel')),
    ));
    expect(
      find.descendant(of: find.byType(CsCard), matching: find.byType(Container)),
      findsOneWidget,
    );
  });
}
```

- [ ] **Step 2: 验证失败** → FAIL

- [ ] **Step 3: 实现**

```dart
// lib/components/cs_card.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

enum CsCardTier { defaultTier, hover, selected }

class CsCard extends StatelessWidget {
  const CsCard({
    required this.child,
    this.tier = CsCardTier.defaultTier,
    this.onTap,
    this.padding = const EdgeInsets.all(Spacing.lg),
    this.selectedAccent = false,
    this.accentColor,
    super.key,
  });
  final Widget child;
  final CsCardTier tier;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool selectedAccent;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final base = switch (tier) {
      CsCardTier.defaultTier => c.surface,
      CsCardTier.hover => c.surface2,
      CsCardTier.selected => c.surface3,
    };
    return _CardBox(
      color: base,
      border: c.border,
      accent: selectedAccent ? (accentColor ?? c.indigo) : null,
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    );
  }
}

class _CardBox extends StatefulWidget {
  const _CardBox({required this.child, required this.color, required this.border,
      this.accent, this.onTap});
  final Widget child;
  final Color color, border;
  final Color? accent;
  final VoidCallback? onTap;
  @override
  State<_CardBox> createState() => _CardBoxState();
}

class _CardBoxState extends State<_CardBox> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final interactive = widget.onTap != null;
    Color bg = widget.color;
    if (interactive && _hover) bg = Color.alphaBlend(Colors.white.withValues(alpha: 0.04), bg);
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: interactive ? (_) => setState(() => _hover = true) : null,
      onExit: interactive ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DurationD.fast,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(CsRadius.lg),
            border: Border.all(color: widget.border),
          ),
          child: IntrinsicWidth(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.accent != null)
                  Container(width: 3, color: widget.accent),
                Flexible(child: widget.child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 验证通过** → PASS

- [ ] **Step 5: commit** — `feat(components): 增加 CsCard(三档表面 + 选中强调条)`

---

### Task 7: CsStatusChip + CsMetricTile

**Files:**
- Create: `lib/components/cs_status_chip.dart`
- Create: `lib/components/cs_metric_tile.dart`
- Test: `test/components/cs_chips_test.dart`

**Interfaces:**
- Produces:`enum ReviewStatus { goal, pending, excluded }`、`CsStatusChip({status, compact})`(带 Lucide 图标 + 语义色);`CsMetricTile({label, value, icon})`(`value` 用 tabularFigures)。

- [ ] **Step 1: 写测试**

```dart
// test/components/cs_chips_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons_flutter.dart';
import 'package:desktop/components/cs_status_chip.dart';
import 'package:desktop/components/cs_metric_tile.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('goal chip shows 已确认 + check icon', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark), home: const CsStatusChip(status: ReviewStatus.goal)));
    expect(find.text('已确认'), findsOneWidget);
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
  });
  testWidgets('metric tile shows label and tabular value', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: const CsMetricTile(label: '进球', value: '4')));
    expect(find.text('进球'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 验证失败** → FAIL

- [ ] **Step 3: 实现**

```dart
// lib/components/cs_status_chip.dart
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons_flutter.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

enum ReviewStatus { goal, pending, excluded }

class CsStatusChip extends StatelessWidget {
  const CsStatusChip({required this.status, this.compact = false, super.key});
  final ReviewStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (label, color, icon) = switch (status) {
      ReviewStatus.goal     => ('已确认', c.goal,     LucideIcons.check),
      ReviewStatus.pending  => ('待审核', c.pending,  LucideIcons.hourglass),
      ReviewStatus.excluded => ('已排除', c.excluded, LucideIcons.ban),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? Spacing.sm : Spacing.md,
        vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(CsRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 11 : 13, color: color),
          SizedBox(width: compact ? 3 : 5),
          Text(label, style: TextStyle(
            color: color, fontSize: compact ? 10 : 12,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          )),
        ],
      ),
    );
  }
}
```

```dart
// lib/components/cs_metric_tile.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsMetricTile extends StatelessWidget {
  const CsMetricTile({required this.label, required this.value, this.icon, super.key});
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: c.textTertiary),
            const SizedBox(width: Spacing.sm),
          ],
          Text(label, style: TextStyle(color: c.textSecondary, fontSize: 13)),
          const Spacer(),
          Text(value, style: TextStyle(
            color: c.textPrimary, fontSize: 15, fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          )),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: 验证通过** → PASS

- [ ] **Step 5: commit** — `feat(components): 增加 CsStatusChip 与 CsMetricTile`

---

### Task 8: CsEmptyState + CsSkeleton + CsProgressTrack

**Files:**
- Create: `lib/components/cs_empty_state.dart`、`cs_skeleton.dart`、`cs_progress_track.dart`
- Test: `test/components/cs_misc_test.dart`

**Interfaces:**
- `CsEmptyState({icon, title, description?, action?})`
- `CsSkeleton({width, height})`(shimmer,尊重 `MediaQuery.disableAnimations`)
- `CsProgressTrack({value, indeterminate})`(value ∈ [0,1],null=indeterminate;轨道 `surface3`,填充 `indigo`)

- [ ] **Step 1: 写测试**

```dart
// test/components/cs_misc_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons_flutter.dart';
import 'package:desktop/components/cs_empty_state.dart';
import 'package:desktop/components/cs_skeleton.dart';
import 'package:desktop/components/cs_progress_track.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('empty state renders title and action', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.dark),
      home: const CsEmptyState(icon: LucideIcons.inbox, title: '空', description: '没数据')));
    expect(find.text('空'), findsOneWidget);
    expect(find.text('没数据'), findsOneWidget);
  });
  testWidgets('skeleton renders a box', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.dark),
      home: const CsSkeleton(width: 100, height: 20)));
    expect(find.byType(CsSkeleton), findsOneWidget);
  });
  testWidgets('progress track determinate shows value', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.dark),
      home: const CsProgressTrack(value: 0.5)));
    final linear = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(linear.value, 0.5);
  });
}
```

- [ ] **Step 2: 验证失败** → FAIL

- [ ] **Step 3: 实现**(3 个文件逐字落地)

```dart
// lib/components/cs_empty_state.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsEmptyState extends StatelessWidget {
  const CsEmptyState({required this.icon, required this.title, this.description, this.action, super.key});
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: c.textTertiary),
            const SizedBox(height: Spacing.md),
            Text(title, style: TextStyle(
              color: c.textPrimary, fontSize: 16, fontWeight: FontWeight.w600,
            )),
            if (description != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(description!, textAlign: TextAlign.center, style: TextStyle(
                color: c.textSecondary, fontSize: 13, height: 1.5,
              )),
            ],
            if (action != null) ...[
              const SizedBox(height: Spacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
```

```dart
// lib/components/cs_skeleton.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsSkeleton extends StatefulWidget {
  const CsSkeleton({required this.width, required this.height, super.key});
  final double width;
  final double height;

  @override
  State<CsSkeleton> createState() => _CsSkeletonState();
}

class _CsSkeletonState extends State<CsSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      reverseDuration: const Duration(milliseconds: 200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(CsRadius.sm),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CsRadius.sm),
          gradient: LinearGradient(
            colors: [c.surface2, c.surface3, c.surface2],
            stops: [0.0, _controller.value, 1.0],
          ),
        ),
      ),
    );
  }
}
```

```dart
// lib/components/cs_progress_track.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsProgressTrack extends StatelessWidget {
  const CsProgressTrack({this.value, this.indeterminate = false, super.key});
  final double? value;
  final bool indeterminate;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(CsRadius.full),
      child: LinearProgressIndicator(
        value: indeterminate ? null : value,
        minHeight: 6,
        backgroundColor: c.surface3,
        valueColor: AlwaysStoppedAnimation<Color>(c.indigo),
      ),
    );
  }
}
```

> 注:`CsProgressTrack` 用 `LinearProgressIndicator`(`minHeight: 6`,`borderRadius: full`,`backgroundColor: surface3`,`color: indigo`,`value: indeterminate ? null : value`)包裹即可。

- [ ] **Step 4: 验证通过** → PASS

- [ ] **Step 5: commit** — `feat(components): 增加 CsEmptyState/CsSkeleton/CsProgressTrack`

---

### Task 9: CsStepIndicator

**Files:**
- Create: `lib/components/cs_step_indicator.dart`
- Test: `test/components/cs_step_indicator_test.dart`

**Interfaces:** `CsStepIndicator({steps: List<({String index, String title, IconData icon, bool completed})>, direction: Axis})`;大序号 28px w700 indigo(完成态 → indigo 实心圆 + check),步骤间连接线。

- [ ] **Step 1: 写测试**

```dart
// test/components/cs_step_indicator_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:desktop/components/cs_step_indicator.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('renders indices for incomplete steps', (tester) async {
    final steps = <CsStep>[
      (index: '01', title: '导入', icon: LucideIcons.upload, completed: false),
      (index: '02', title: '审核', icon: LucideIcons.check, completed: false),
      (index: '03', title: '导出', icon: LucideIcons.download, completed: false),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: Center(child: CsStepIndicator(steps: steps)),
    ));
    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
    expect(find.text('03'), findsOneWidget);
  });
  testWidgets('completed step shows check icon', (tester) async {
    final steps = <CsStep>[
      (index: '01', title: '导入', icon: LucideIcons.check, completed: true),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: Center(child: CsStepIndicator(steps: steps)),
    ));
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
  });
}
```

- [ ] **Step 2: 验证失败** → FAIL

- [ ] **Step 3: 实现**

```dart
// lib/components/cs_step_indicator.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

typedef CsStep = ({String index, String title, IconData icon, bool completed});

class CsStepIndicator extends StatelessWidget {
  const CsStepIndicator({required this.steps, this.direction = Axis.horizontal, super.key});
  final List<CsStep> steps;
  final Axis direction;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final children = <Widget>[];
    for (var i = 0; i < steps.length; i++) {
      children.add(_StepNode(step: steps[i]));
      if (i < steps.length - 1) {
        if (direction == Axis.horizontal) {
          children.add(Expanded(
            child: Container(height: 2, color: steps[i].completed ? c.indigo : c.border),
          ));
        } else {
          children.add(Container(
            width: 2, height: 24,
            color: steps[i].completed ? c.indigo : c.border,
          ));
        }
      }
    }
    return switch (direction) {
      Axis.horizontal => Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
      Axis.vertical => Column(crossAxisAlignment: CrossAxisAlignment.center, children: children),
    };
  }
}

class _StepNode extends StatelessWidget {
  const _StepNode({required this.step});
  final CsStep step;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (step.completed) {
      return Container(
        width: 28, height: 28,
        decoration: BoxDecoration(color: c.indigo, shape: BoxShape.circle),
        child: Icon(step.icon, size: 14, color: Colors.white),
      );
    }
    return Container(
      width: 28, height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c.borderStrong),
      ),
      child: Text(step.index, style: TextStyle(
        color: c.indigo, fontSize: 13, fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      )),
    );
  }
}
```
- [ ] **Step 4: 验证通过**
- [ ] **Step 5: commit** — `feat(components): 增加 CsStepIndicator(大序号 + 连接线)`

---

### Task 10: noticeProvider + CsNotice + CsNoticeOverlay

**Files:**
- Create: `lib/providers/notice_provider.dart`
- Create: `lib/components/cs_notice.dart`
- Create: `lib/components/cs_notice_overlay.dart`
- Test: `test/providers/notice_provider_test.dart`、`test/components/cs_notice_test.dart`

**Interfaces:**
- `enum NoticeSeverity { success, error, warning, info }`
- `class NoticeMessage { id, severity, title, description?, action?, actionLabel?, duration }`
- `class NoticeNotifier extends Notifier<List<NoticeMessage>>` — `push(msg)`(自动定时 dismiss)、`dismiss(id)`;最多 4 条。
- `CsNotice({message, onDismiss})` — 单条 widget,左 3px severity 条 + Lucide 图标 + 标题/描述 + 可选 action + 关闭按钮;slide+fade 入场;`MouseRegion` hover 暂停计时。
- `CsNoticeOverlay` — `ref.watch(noticeProvider)` 渲染右下角堆叠;挂 `MaterialApp.builder`。

- [ ] **Step 1: 写 provider 测试**

```dart
// test/providers/notice_provider_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/providers/notice_provider.dart';

void main() {
  test('push appends and dismiss removes', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(noticeProvider), isEmpty);
    final notifier = container.read(noticeProvider.notifier);
    notifier.push(const NoticeMessage(id: '1', severity: NoticeSeverity.success, title: 'ok'));
    expect(container.read(noticeProvider).length, 1);
    notifier.dismiss('1');
    expect(container.read(noticeProvider), isEmpty);
  });
  test('queue capped at 4', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(noticeProvider.notifier);
    for (var i = 0; i < 6; i++) {
      notifier.push(NoticeMessage(id: '$i', severity: NoticeSeverity.info, title: '$i'));
    }
    expect(container.read(noticeProvider).length, 4);
  });
}
```

- [ ] **Step 2: 验证失败** → FAIL

- [ ] **Step 3: 实现 provider**

```dart
// lib/providers/notice_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum NoticeSeverity { success, error, warning, info }

class NoticeMessage {
  final String id;
  final NoticeSeverity severity;
  final String title;
  final String? description;
  final void Function()? action;
  final String? actionLabel;
  final Duration duration;
  const NoticeMessage({
    required this.id,
    required this.severity,
    required this.title,
    this.description,
    this.action,
    this.actionLabel,
    this.duration = const Duration(seconds: 4),
  });
}

class NoticeNotifier extends Notifier<List<NoticeMessage>> {
  @override
  List<NoticeMessage> build() => const [];
  void push(NoticeMessage msg) {
    var next = [...state, msg];
    if (next.length > 4) next = next.sublist(next.length - 4);
    state = next;
  }
  void dismiss(String id) {
    state = state.where((m) => m.id != id).toList();
  }
}
final noticeProvider = NotifierProvider<NoticeNotifier, List<NoticeMessage>>(NoticeNotifier.new);
```
> timer 不在 provider:自动消失与 hover 暂停完全由 `CsNotice` widget 自管(见 Step 4),provider 只做 list 增删 + cap。

- [ ] **Step 4: 实现 CsNotice / CsNoticeOverlay**(按 spec §14:右下 `Align` 堆叠,`SlideTransition`+`FadeTransition` 入场。`CsNotice` 为 `StatefulWidget`,内部自管 `Timer`:`initState` 启动 `effectiveDuration = message.severity == NoticeSeverity.error ? 6s : message.duration`;`MouseRegion` onEnter 取消 timer、onExit 重启;`dispose` 取消;关闭按钮调 `onDismiss`。`CsNoticeOverlay` = `ref.watch(noticeProvider)` → 右下角逐条渲染。)

- [ ] **Step 5: 验证 provider 测试通过**(push/dismiss 纯 list 操作 + cap 4;timer 由 widget 管,不影响 provider 测试)

- [ ] **Step 6: 写 CsNotice widget 测试** — 渲染 `CsNotice(message: success)`,断言标题 + `LucideIcons.circleCheck` 图标 + 关闭按钮存在;tap 关闭按钮调用 `onDismiss`。

- [ ] **Step 7: 验证 widget 测试通过**

- [ ] **Step 8: commit** — `feat(notice): 增加通知系统(provider + CsNotice + 全局浮层)`

---

## Phase 3 · 骨架

### Task 11: session_provider + theme_provider

**Files:**
- Create: `lib/providers/session_provider.dart`
- Create: `lib/providers/theme_provider.dart`
- Test: `test/providers/session_theme_provider_test.dart`

**Interfaces:**
- `engineClientProvider: Provider<EngineClient>`(onDispose → `client.dispose()`)
- `EngineBootstrapNotifier extends Notifier<AsyncValue<bool>>` — `ensure()` 迁移自 `app.dart:_ensureEngine/_findRuntimeRoot/_findPython`;`build()` 初值 `AsyncValue.loading()`。
- `engineBootstrapProvider: NotifierProvider<EngineBootstrapNotifier, AsyncValue<bool>>`
- `ThemeModeNotifier extends Notifier<ThemeMode>` — `build()` 读 `SharedPreferences.getString('courtside.theme_mode')`;`set(ThemeMode)` 写回。
- `themeModeProvider: NotifierProvider<ThemeModeNotifier, ThemeMode>`

- [ ] **Step 1: 写测试**
  - `engineBootstrapProvider`:`ensure()` 成功后状态为 `AsyncData(true)`;找不到 runtime 时为 `AsyncError`。用假 `EngineClient`(允许对子进程通信 mock——这是外部进程,非数据库;业务为「运行时定位」逻辑)。**对 `_findRuntimeRoot` 路径扫描与 `_findPython` 候选解析这种纯逻辑单独抽函数测真实分支。**
  - `themeModeProvider`:默认 `system`;`set(dark)` 后重读为 `dark`(用 `SharedPreferences.setMockInitialValues({})`)。
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现** — 迁移 `app.dart` 的 `_ensureEngine / _findRuntimeRoot / _findPython` 原样到 `EngineBootstrapNotifier`(逻辑不动,只改 setState→state),环境变量(`BHE_REPO_ROOT`/`BHE_RUNTIME_ROOT`/`BHE_PYTHON` 等)保留。`ThemeModeNotifier` 用 `SharedPreferencesAsync`(或 `SharedPreferences`,保持简单)。
- [ ] **Step 4: 验证通过**
- [ ] **Step 5: commit** — `feat(providers): 增加 session 与 theme provider(迁移 engine 启动逻辑)`

---

### Task 12: project_state(ProjectNotifier)

**Files:**
- Create: `lib/providers/project_state.dart`
- Test: `test/providers/project_state_test.dart`

**Interfaces:**
- `typedef JsonMap = Map<String, dynamic>;`
- `class ProjectState { video, videoPath, previewPath, job, candidates, recentProjects, exportHistory, busy, recentLoading, recentError }`(immutable,`copyWith`)
- `class ProjectNotifier extends Notifier<ProjectState>` — 迁移 `app.dart` 全部业务方法:`selectVideo/openProject/loadRecentProjects/saveRoi/startAnalysis/retryAnalysis/cancelAnalysis/reviewCandidate/updateClipRange/export/refreshCandidates/refreshExportHistory/pollJob/restoreActiveJob`。成功/失败改 `ref.read(noticeProvider.notifier).push(...)`,不再走 `_error`。
- Consumes:`EngineSession`/`ProjectSession`(via provider,封装 `engineBootstrapProvider` + `engineClientProvider`)、`noticeProvider`。
- Produces:`projectProvider: NotifierProvider<ProjectNotifier, ProjectState>`。

- [ ] **Step 1: 写测试**
  - 定义 `FakeProjectSession implements ProjectSession`(若 `ProjectSession` 是 class 可直接 fake;若是具象类,用 `mocktail` 或新建薄接口)。**业务逻辑测真实分支**:selectVideo 后 state.videoPath 更新、reviewCandidate(id,'goal') 后该候选 status 变 goal 且 push success notice、updateClipRange 校验。
  - 测 `noticeProvider` 收到对应 severity。
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现** — 从 `app.dart` 原样搬运方法体(`_pollJob` 流式逻辑保留),`ref.read(projectSessionProvider)` 取 session;`_showNotice(msg, error:true)` → `ref.read(noticeProvider.notifier).push(NoticeMessage(severity: error ? error : success, title: msg))`。
- [ ] **Step 4: 验证通过**
- [ ] **Step 5: commit** — `feat(providers): 增加 ProjectNotifier(迁移全部业务方法到 Riverpod)`

---

### Task 13: router + CsScaffold + CsSidebarShell + CsBottomNav

**Files:**
- Create: `lib/router/app_router.dart`
- Create: `lib/components/cs_scaffold.dart`、`cs_sidebar_shell.dart`、`cs_bottom_nav.dart`
- Test: `test/router/app_router_test.dart`

**Interfaces:**
- `appRouterProvider: Provider<GoRouter>` — `StatefulShellRoute.indexedStack`,4 branch `/home /import /review /export`,shell builder → `CsScaffold(shell: shell)`。
- `CsScaffold({shell})` — `LayoutBuilder`:`maxWidth >= Breakpoints.md` → `Row[CsSidebarShell, Expanded(child: shell.child)]`;否则内容 + 底部 `CsBottomNav`。
- `CsSidebarShell({shell, extended})` — 桌面侧栏(76↔232,`≥ lg` 展开),Logo + 4 `CsSidebarItem` + 底部隐私徽章。导航 `shell.goBranch(index)`。
- `CsBottomNav({shell})` — `NavigationBar` 4 项(Lucide 图标),`shell.goBranch`。
- `CsSidebarItem({label, icon, selectedIcon, selected, extended, onTap})` — 选中左 3px indigo 条 + 文字 w600;折叠态 `Tooltip`。

- [ ] **Step 1: 写测试**
  - `appRouter_test`:初始 location `/home`;`router.go('/review')` 后 `router.routerDelegate.currentConfiguration` 含 review branch。
  - `cs_scaffold_test`:宽窗(1200)渲染 `CsSidebarShell`;窄窗(700)渲染 `CsBottomNav`(用 `tester.view.physicalSize`)。
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现** — 4 个 branch 的 builder 各自返回对应 screen widget(此时 screen 还是旧的,可先用占位 `Scaffold(body: Text('/home'))`,T15 替换为真 screen;router 测试只验路由切换,不依赖 screen 内容)。`CsScaffold` 顶部还含 `CsTopBar`(标题 + Engine 状态胶囊 + 主题切换 + 隐私徽章)——`CsTopBar` 放 `cs_scaffold.dart` 内或单独,读 `engineBootstrapProvider` 与 `themeModeProvider`。
- [ ] **Step 4: 验证通过**
- [ ] **Step 5: commit** — `feat(router): 增加 go_router 路由与自适应 Scaffold/侧栏/底栏`

---

### Task 14: app.dart + main.dart 重写,删除旧 AppShell

**Files:**
- Modify(重写): `lib/app.dart`、`lib/main.dart`
- Delete: 旧 `app.dart` 内的 `AppShell / _Sidebar / _SidebarItem / _TopBar / _ErrorBanner / _BasketballHighlightAppState` 全部(逻辑已迁移到 providers/router/components)

**Interfaces:**
- `lib/main.dart`:`MediaKit.ensureInitialized(); runApp(ProviderScope(child: CourtsideApp()));`
- `lib/app.dart`:`class CourtsideApp extends ConsumerWidget` — `MaterialApp.router(routerConfig: ref.watch(appRouterProvider), theme: appTheme(light), darkTheme: appTheme(dark), themeMode: ref.watch(themeModeProvider), builder: (ctx, child) => CsNoticeOverlay(child: child!))`。

- [ ] **Step 1: 删除旧单体** — `app.dart` 全部旧类清空,仅留 `CourtsideApp`。`main.dart` 包 `ProviderScope`。
- [ ] **Step 2: 实现 CourtsideApp**(如上)
- [ ] **Step 3: 暂时让 4 个 screen 文件返回占位**(`Scaffold(body: Center(child: Text('home')))`)以便 app 能启动跑通路由 — 真实 screen 在 T15/T16 实现。
- [ ] **Step 4: 验证** — `flutter analyze` 无 error;`flutter run`(手动,记录是否启动;自动化用 `flutter test` 跑现有 test/ 暂时 skip 与 screen 相关的)。
- [ ] **Step 5: commit** — `refactor(app): 重写 app.dart 为 MaterialApp.router,删除旧单体 AppShell`

---

## Phase 4 · 逐屏

### Task 15: Home + Import screens 重写

**Files:**
- Modify(重写): `lib/features/home/home_screen.dart`、`lib/features/import_video/import_video_screen.dart`
- Modify(重写测试): `test/home_screen_test.dart`

**回调 → provider 迁移映射(Home):**
| 旧 callback | 新数据源 |
|---|---|
| `onNewProject` | `context.go('/import')` |
| `onOpenProject` | `ref.read(projectProvider.notifier).openProject(...)`(经目录选择器) |
| `recentProjects / loading / error` | `ref.watch(projectProvider.select(...))` |
| `onLoadRecentProjects` | `ProjectNotifier.loadRecentProjects()`(在 `build`/init 自动触发) |
| `onOpenRecentProject` | `ProjectNotifier.openProject(root)` |
| `goalCount/pendingCount/videoDurationMs` | 从 `ref.watch(projectProvider)` 计算 |

**Home build 结构(合并 spec §16.1):**
```
SingleChildScrollView padding:Spacing.xl
  Center maxWidth 1100
    Column start
      Hero: displayLarge slogan + bodyLarge 副标
      Spacing.xxl
      LayoutBuilder (≥ md 横排 else 纵排):
        CsCard(主 CTA,flex3): 图标 sparkles + titleLarge「从视频开始」+ bodyLarge 说明 + Wrap[CsButton primary「新建项目」(orange+plus), CsButton secondary「打开项目」(folderOpen)]
        Spacing.md
        CsCard(metrics,次级): titleMedium「当前项目」+ 3×CsMetricTile + 脚注
      Spacing.xxl
      最近项目: titleLarge「最近项目」+ 刷新 IconButton(refreshCw) + 网格(CsCard onTap 打开 / CsSkeleton 加载 / CsEmptyState 空)
      Spacing.xxl
      CsStepIndicator 五步(import/crop/scan/review/export)
```

**Import build 结构(合并 spec §16.2):**
```
SingleChildScrollView
  Column
    displayMedium「新建分析项目」+ 副标
    CsCard: CsStepIndicator 两步(01 选择视频 [✓ when hasVideo], 02 框选 ROI [✓ when hasRoi])
      视频选择行: Icon film + SelectableText(文件名/提示) + CsButton secondary「更换/选择视频」
      视频信息行(labelSmall tnum)
      _RoiCanvas(精致化:边框 border → 激活 indigo,选区 indigo 18% + 2px + 四角手柄 CustomPaint;逻辑保留)
      「保存 ROI」CsButton secondary(slidersHorizontal) + 说明
    右对齐: CsButton primary「开始分析」(orange+play, loading 内嵌 spinner),disabled until hasVideo && hasRoi && roiSaved && !busy
```
- `_RoiCanvas`/`_RoiPainter` 逻辑(`onPanStart/Update/End` + `_normalizedRect`)原样保留,仅 `Container` 颜色/边框换 `AppColors`,`_RoiPainter` stroke 颜色用 `indigo`、新增四角手柄。

- [ ] **Step 1: 重写 Home 测试** — 改 `ProviderScope` + `ProviderContainer` override `projectProvider` 为假 `ProjectNotifier`(返回固定 `ProjectState`);断言:渲染 slogan「把整场比赛,变成你的高光。」、最近项目卡片「周末训练赛」、点卡片触发 `openProject`(用假 notifier 记录调用)。
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现 Home + Import**(按上面结构 + spec §16.1/§16.2,用 `CsButton`/`CsCard`/`CsMetricTile`/`CsStepIndicator`/`CsEmptyState`/`CsSkeleton`/`AppColors`/`numericTextStyle`)
- [ ] **Step 4: 验证通过** — `flutter test test/home_screen_test.dart`
- [ ] **Step 5: commit** — `feat(home,import): 重写 Home 与 Import 屏为 Linear 风精致 UI`

---

### Task 16: Export + Review screens 重写

**Files:**
- Modify(重写): `lib/features/export/export_screen.dart`、`lib/features/review/review_screen.dart`
- Modify(重写测试): `test/review_screen_test.dart`

**回调 → provider 映射(Review):** `job/candidates/videoPath/busy` ← `ref.watch(projectProvider)`;`onCancelAnalysis/onRetryAnalysis/onReviewCandidate/onUpdateClipRange` → `ProjectNotifier` 对应方法;`onExport` → `context.go('/export')`。

**Export build 结构(spec §16.4):**
```
SingleScrollView maxWidth 900
  displayMedium「导出集锦」+ 副标
  CsCard: 4×CsMetricTile(已确认片段数/合计时长/输出编码/处理方式,值 tnum)
          Column[ CsButton primary「合并导出」(orange+merge,loading), Spacing.sm, CsButton secondary「分别导出」(files,loading) ]
  说明(labelSmall textSecondary)
  CsButton ghost「返回审核」(arrowLeft) → context.go('/review')
  历史: CsCard×N(history icon + 模式/片段数/时长/路径 SelectableText + 时间 tnum)
```

**Review build 结构(spec §16.3,核心,最复杂):**
```
Padding Spacing.lg
  Column
    if job analyzing||failed: CsAnalysisStatusCard(CsCard surface2:
       sparkles/circleAlert + titleMedium + stage+%(tnum) + CsProgressTrack + 取消/重试(CsButton))
    Expanded
      LayoutBuilder (≥ md Row[Expanded(preview), SizedBox(390, queue)] else Column[Expanded(preview), SizedBox(380, queue)]):
        _PreviewPanel(CsCard):
          if recoverable: warning CsCard + 重试 ghost
          Expanded: 视频容器(#080B0E + border) 或 CsEmptyState(movie/error)
          _PlayerControls 三段:
            Slider
            Row[ 时间码(labelLarge tnum textSecondary) " / " 时长,  上一/播放/下一(Icon 36 skipBack/play/pause/skipNext + tooltip),  Spacer,  CsButton secondary「播放候选片段」(film/square) ]
          候选信息行(labelSmall tnum)
        _QueuePanel(CsCard):
          Row[ titleLarge「候选审核」 + Spacer + CsStatusChip(N 待审核) ]
          ListView.separated:
            CsCard(onTap selectedAccent=true):
              Row[ #N(titleMedium tnum) + 时间(tnum) + Spacer + CsStatusChip ]
              Row[ Expanded CsButton primary「进球」(orange+check), Expanded CsButton secondary「排除」(ban) ]   ← 主次靠 variant
              CsButton ghost sm「调整片段范围」(slidersHorizontal) → 对话框
          CsButton primary「去导出」(orange+arrowUpRight,disabled if no goal) → context.go('/export')
```
- `_AnalysisStatusCard / _PreviewPanel / _PlayerControls / _QueuePanel` 子组件保留(改样式),`_editRange` 对话框逻辑保留(AlertDialog → 精致化 + `CsButton`)。
- 媒体播放逻辑(`Player`/`VideoController`/`_positionSubscription`/`_playClip`/`_seekToCandidate`)**原样不动**。

- [ ] **Step 1: 重写 Review 测试** — `ProviderScope` override,喂 `ProjectState(job: running@0.35, candidates: [])`;断言:渲染「正在分析视频」、`CsProgressTrack` value=0.35、候选队列空态 `CsEmptyState`;喂 2 候选时渲染 2 个 `#1/#2` + 点「进球」调用 `reviewCandidate(id,'goal')`(假 notifier 记录)。
- [ ] **Step 2: 验证失败**
- [ ] **Step 3: 实现 Export + Review**(按上面结构 + spec §16.3/§16.4)
- [ ] **Step 4: 验证通过** — `flutter test test/review_screen_test.dart` + 全量 `flutter test`
- [ ] **Step 5: commit** — `feat(review,export): 重写 Review 与 Export 屏,核心审核工作区精致化`

---

## Phase 5 · polish

### Task 17: 自适应 + 主题切换 + 空/错/加载 + analyze 全绿 + 启动验收

**Files:** 可能微调任意 screen/component;`test/widget_test.dart` / `test/engine_session_test.dart` 更新以适配新架构。

- [ ] **Step 1: `flutter analyze` 全绿** — 修复 lint(prefer_const、unused import、require_trailing_commas 等)。Run: `flutter analyze` → Expected: no issues。
- [ ] **Step 2: 全量测试** — `flutter test` → 全部 PASS(更新 `widget_test.dart`/`engine_session_test.dart` 以适配 providers;engine_session 若依赖旧 app.dart 类,移除该依赖或用 provider 注入)。
- [ ] **Step 3: 自适应验证** — `flutter run -d macos`,手动缩放窗口:
  - ≥ 1280:侧栏展开(232)+ 内容
  - 900–1280:侧栏折叠(76)
  - < 900:底栏 `CsBottomNav`
  - 记录异常布局,修。
- [ ] **Step 4: 主题切换验证** — 切 system/light/dark:
  - 浅色下篮球橙文字对比度(白字 + `#F2601D` 底,验证 ≥ 4.5:1)
  - 深浅切换无溢出、无残留硬编码色
  - 持久化:重启后保留上次模式
- [ ] **Step 5: 通知验证** — 触发各 notice(成功:保存 ROI;错误:engine 未就绪;warning:recoverable;info:分析开始)。右下角浮层 + slide/fade + 4s 自动消失 + hover 暂停。
- [ ] **Step 6: 空/错/加载态巡检** — 最近项目空、候选空、视频加载失败、分析失败 — 全用 `CsEmptyState`/`CsSkeleton`/`CsNotice`,无裸 `CircularProgressIndicator+Text`。
- [ ] **Step 7: commit** — `style(desktop): 自适应与主题切换 polish,全量 lint/test 通过`

---

## Self-Review(plan 作者自查)

**1. Spec 覆盖:**
- §5 令牌 → T2;§6 配色 → T3;§7 排版 → T4;§8 图标 → 各 component/screen 用 `lucide_icons_flutter`(T1 引入,全计划统一);§9 结构 → File Structure;§10 providers → T11/T12;§11 路由 → T13;§12 自适应 → T13+T17;§13 主题 → T4+T11+T14;§14 通知 → T10;§15 组件 → T5–T9;§16 各屏 → T15/T16;§17 错误空态 → T8+T15/T16+T17;§18 动效 → 各组件内 + T17;§19 a11y → 组件 tooltip/ExcludeSemantics(Semantics 覆盖在 T17 巡检);§20 阶段 → 本计划 Phase;§21 测试 → 每任务 TDD;§22 风险 → Global Constraints(锁版本/不引 freezed)。**无遗漏。**

**2. 占位符:** T8/T9 的组件实现写为「按 spec §15 实现完整」——为避免与 spec 重复,但给了 widget 测试与验收。执行时如发现不够自包含,补全代码。T15/T16 screen 给了结构骨架而非逐行,因 spec §16 已逐行描述布局,执行合并即可——已声明此约定。

**3. 类型一致性:** `AppColors.of`/`darkAppColors`/`lightAppColors`(T3)全计划统一;`CsButtonVariant`/`CsCardTier`/`ReviewStatus`/`NoticeSeverity` 枚举名跨任务一致;`projectProvider`/`noticeProvider`/`themeModeProvider`/`engineBootstrapProvider`/`appRouterProvider` 命名贯穿 T11–T16。

**4. 范围:** 单一实现计划,17 任务,5 阶段,聚焦 Flutter 层。无需拆子项目。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-06-courtside-ui-redesign.md`. Two execution options:

**1. Subagent-Driven (recommended)** — 每个 task 派一个 fresh subagent,任务间两阶段 review,快速迭代。

**2. Inline Execution** — 在当前会话用 executing-plans 批量执行 + checkpoint review。

Which approach?
