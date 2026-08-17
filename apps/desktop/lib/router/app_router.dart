import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../components/cs_scaffold.dart';
import '../features/export/export_screen.dart';
import '../features/home/home_screen.dart';
import '../features/import_video/import_video_screen.dart';
import '../features/review/review_screen.dart';
import '../providers/project_state.dart';

/// 全局 GoRouter。
///
/// `StatefulShellRoute.indexedStack` 提供 4 branch(`/home /import /review
/// /export`),每个 branch 独立导航栈,shell(CsScaffold)持久化。导航通过
/// `context.go('/review')` 等触发。
///
/// 四个 branch 均绑定真实 screen，页面数据统一来自 projectProvider。
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    initialLocation: '/home',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, _, shell) => CsScaffold(shell: shell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/home', builder: (_, _) => const _HomeRoute()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/import',
                builder: (_, _) => const ImportVideoScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/review', builder: (_, _) => const _ReviewRoute()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/export', builder: (_, _) => const _ExportRoute()),
            ],
          ),
        ],
      ),
    ],
  ),
);

/// Home 路由壳:首次进入自动加载最近项目,随后渲染 HomeScreen。
class _HomeRoute extends ConsumerStatefulWidget {
  const _HomeRoute();

  @override
  ConsumerState<_HomeRoute> createState() => _HomeRouteState();
}

class _HomeRouteState extends ConsumerState<_HomeRoute> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(projectProvider.notifier).loadRecentProjects();
    });
  }

  @override
  Widget build(BuildContext context) => HomeScreen(
    onProjectOpened: () {
      if (!context.mounted) return;
      final state = ref.read(projectProvider);
      context.go(
        state.videoPath == null || state.videoPath!.isEmpty
            ? '/import'
            : '/review',
      );
    },
  );
}

/// Review 路由壳:直接渲染 ReviewScreen(ConsumerStatefulWidget 自行 watch provider)。
class _ReviewRoute extends ConsumerWidget {
  const _ReviewRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) => const ReviewScreen();
}

/// Export 路由壳:直接渲染 ExportScreen(ConsumerWidget 自行 watch provider)。
class _ExportRoute extends ConsumerWidget {
  const _ExportRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) => const ExportScreen();
}
