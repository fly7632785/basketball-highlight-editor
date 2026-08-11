import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'components/cs_notice_overlay.dart';
import 'providers/project_state.dart';
import 'providers/theme_provider.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

class CourtsideApp extends ConsumerStatefulWidget {
  const CourtsideApp({super.key});

  @override
  ConsumerState<CourtsideApp> createState() => _CourtsideAppState();
}

class _CourtsideAppState extends ConsumerState<CourtsideApp>
    with WindowListener {
  bool _confirmingClose = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_enableWindowCloseGuard());
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
          title: Text(busy ? '任务仍在进行' : '退出 Courtside？'),
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
      title: 'Courtside',
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      builder: (context, child) => CsNoticeOverlay(child: child!),
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
