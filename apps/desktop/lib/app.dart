import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'components/cs_notice_overlay.dart';
import 'core/windows_caption_bar.dart';
import 'core/windows_title_bar.dart';
import 'providers/project_state.dart';
import 'providers/theme_provider.dart';
import 'router/app_router.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';

class CourtsideApp extends ConsumerStatefulWidget {
  const CourtsideApp({super.key});

  @override
  ConsumerState<CourtsideApp> createState() => _CourtsideAppState();
}

class _CourtsideAppState extends ConsumerState<CourtsideApp>
    with WindowListener {
  bool _confirmingClose = false;
  late final ProviderSubscription<ThemeMode> _themeSubscription;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_enableWindowCloseGuard());
    _themeSubscription = ref.listenManual<ThemeMode>(
      themeModeProvider,
      (_, next) => unawaited(_syncNativeWindowBrightness(next)),
      fireImmediately: true,
    );
  }

  Future<void> _syncNativeWindowBrightness(ThemeMode mode) async {
    final brightness = switch (mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    try {
      await windowManager.setBrightness(brightness);
      await windowManager.setBackgroundColor(
        brightness == Brightness.light
            ? lightAppColors.background
            : darkAppColors.background,
      );
    } catch (_) {
      // Widget tests and non-desktop hosts do not expose the native channel.
    }
    // window_manager 在 Windows 上按系统主题门控标题栏,可能在上面把
    // 标题栏刷回浅色;DWM 直调必须放在它之后兜底。
    applyWindowsTitleBarBrightness(brightness);
  }

  Future<void> _enableWindowCloseGuard() async {
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {
      // Widget tests and non-desktop hosts do not expose the native channel.
    }
  }

  @override
  void dispose() {
    _themeSubscription.close();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(_confirmWindowClose());
  }

  Future<void> _confirmWindowClose() async {
    if (_confirmingClose) return;
    _confirmingClose = true;
    try {
      final router = ref.read(appRouterProvider);
      final dialogContext = router.routerDelegate.navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) {
        final ready = await ref
            .read(projectProvider.notifier)
            .prepareForShutdown();
        if (ready) await windowManager.destroy();
        return;
      }
      final state = ref.read(projectProvider);
      final analyzing = state.analysisRunning;
      final exporting = state.exportRunning;
      final busy = analyzing || exporting || state.busy;
      final action = await showDialog<String>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: Text(busy ? '任务仍在进行' : '退出 BHE？'),
          content: Text(busy ? '当前任务还在进行，退出前需要先取消任务。' : '确认关闭软件吗？本地项目数据不会被删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'stay'),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'exit'),
              child: Text(busy ? '取消任务并退出' : '退出软件'),
            ),
          ],
        ),
      );
      if (action != 'exit') return;
      final ready = await ref
          .read(projectProvider.notifier)
          .prepareForShutdown();
      if (!ready) return;
      await windowManager.destroy();
    } finally {
      _confirmingClose = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      routerConfig: ref.watch(appRouterProvider),
      title: 'BHE',
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      builder: (context, child) {
        final wrapped = CsNoticeOverlay(child: child!);
        // Windows 隐藏原生标题栏后由应用自绘,消除 Win10 左/下/右的
        // 灰色 DWM 缩放边框;macOS 保持原生标题栏。
        if (!Platform.isWindows) return wrapped;
        return ExcludeSemantics(
          child: DragToResizeArea(
            resizeEdgeMargin: const EdgeInsets.only(top: 36),
            child: Column(
              children: [
                const WindowsCaptionBar(),
                Expanded(child: wrapped),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 兼容旧启动入口，避免旧的桌面测试和外部启动脚本在 UI 路由迁移期间失效。
class BasketballHighlightApp extends StatelessWidget {
  const BasketballHighlightApp({
    this.enableStartupProjectScan = true,
    super.key,
  });

  final bool enableStartupProjectScan;

  @override
  Widget build(BuildContext context) {
    return const ProviderScope(child: CourtsideApp());
  }
}
