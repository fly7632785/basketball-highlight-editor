import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import 'components/cs_notice_overlay.dart';
import 'core/windows_caption_bar.dart';
import 'core/windows_title_bar.dart';
import 'features/update/update_dialog.dart';
import 'providers/notice_provider.dart';
import 'providers/project_state.dart';
import 'providers/locale_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/update_provider.dart';
import 'router/app_router.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'core/app_log.dart';

class CourtsideApp extends ConsumerStatefulWidget {
  const CourtsideApp({super.key});

  @override
  ConsumerState<CourtsideApp> createState() => _CourtsideAppState();
}

class _CourtsideAppState extends ConsumerState<CourtsideApp>
    with WindowListener {
  bool _confirmingClose = false;
  late final ProviderSubscription<ThemeMode> _themeSubscription;
  Timer? _updateCheckTimer;

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
    _updateCheckTimer = Timer(const Duration(seconds: 5), _autoCheckUpdate);
  }

  Future<void> _autoCheckUpdate() async {
    final found = await ref.read(updateProvider.notifier).autoCheck();
    final version = ref.read(updateProvider).targetVersion;
    if (!found || !mounted || version == null) return;
    final id = 'update-$version';
    ref.read(noticeProvider.notifier).push(
      NoticeMessage(
        id: id,
        severity: NoticeSeverity.info,
        title: '发现新版本 v$version',
        description: '点「查看」了解更新内容',
        actionLabel: '查看',
        duration: const Duration(seconds: 10),
        action: () {
          final context = ref
              .read(appRouterProvider)
              .routerDelegate
              .navigatorKey
              .currentContext;
          if (context == null) return;
          ref.read(noticeProvider.notifier).dismiss(id);
          showUpdateDialog(context);
        },
      ),
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
    } catch (error) {
      appLog('warn', 'app', '_syncNativeWindowBrightness 忽略了错误: $error');
      // Widget tests and non-desktop hosts do not expose the native channel.
    }
    // window_manager 在 Windows 上按系统主题门控标题栏,可能在上面把
    // 标题栏刷回浅色;DWM 直调必须放在它之后兜底。
    applyWindowsTitleBarBrightness(brightness);
  }

  Future<void> _enableWindowCloseGuard() async {
    try {
      await windowManager.setPreventClose(true);
    } catch (error) {
      appLog('warn', 'app', '_enableWindowCloseGuard 忽略了错误: $error');
      // Widget tests and non-desktop hosts do not expose the native channel.
    }
  }

  @override
  void dispose() {
    _updateCheckTimer?.cancel();
    _themeSubscription.close();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (ref.read(updateProvider).status == UpdateStatus.installing) return;
    unawaited(_confirmWindowClose());
  }

  Future<void> _confirmWindowClose() async {
    if (_confirmingClose) return;
    _confirmingClose = true;
    try {
      final router = ref.read(appRouterProvider);
      final dialogContext = router.routerDelegate.navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) {
        appLog('info', 'app', '关闭保护 无界面可确认，直接准备退出');
        final ready = await ref
            .read(projectProvider.notifier)
            .prepareForShutdown();
        if (ready) await windowManager.destroy();
        return;
      }
      final state = ref.read(projectProvider);
      final l10n = Localizations.of<BheLocalizations>(
        dialogContext,
        BheLocalizations,
      );
      final analyzing = state.analysisRunning;
      final exporting = state.exportRunning;
      final busy = analyzing || exporting || state.busy;
      final action = await showDialog<String>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: Text(
            busy
                ? (l10n?.taskInProgress ?? '任务仍在进行')
                : (l10n?.confirmExit ?? '退出 BHE？'),
          ),
          content: Text(
            busy
                ? (l10n?.exitBusyDescription ?? '当前任务还在进行，退出前需要先取消任务。')
                : (l10n?.exitDescription ?? '确认关闭软件吗？本地项目数据不会被删除。'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'stay'),
              child: Text(l10n?.returnAction ?? '返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'exit'),
              child: Text(
                busy
                    ? (l10n?.cancelTaskAndExit ?? '取消任务并退出')
                    : (l10n?.exitApp ?? '退出软件'),
              ),
            ),
          ],
        ),
      );
      appLog(
        'info',
        'app',
        '关闭保护 用户选择=${action == 'exit' ? '退出' : '返回'} 分析中=$analyzing 导出中=$exporting 忙=$busy',
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
      locale: ref.watch(appLocaleProvider),
      localizationsDelegates: BheLocalizations.localizationsDelegates,
      supportedLocales: BheLocalizations.supportedLocales,
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
