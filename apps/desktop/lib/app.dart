import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'components/cs_notice_overlay.dart';
import 'providers/theme_provider.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

class CourtsideApp extends ConsumerWidget {
  const CourtsideApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
  const BasketballHighlightApp({this.enableStartupProjectScan = true, super.key});

  final bool enableStartupProjectScan;

  @override
  Widget build(BuildContext context) {
    return const ProviderScope(child: CourtsideApp());
  }
}
