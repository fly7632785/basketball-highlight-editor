import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../components/cs_scaffold.dart';
import '../features/home/home_screen.dart';
import '../features/import_video/import_video_screen.dart';
import '../providers/project_state.dart';

/// 全局 GoRouter。
///
/// `StatefulShellRoute.indexedStack` 提供 4 branch(`/home /import /review
/// /export`),每个 branch 独立导航栈,shell(CsScaffold)持久化。导航通过
/// `context.go('/review')` 等触发。
///
/// T15:Home / Import 已接入真实 screen;Review / Export 暂用占位(T16)。
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    initialLocation: '/home',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, _, shell) => CsScaffold(shell: shell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                builder: (_, _) => const _HomeRoute(),
              ),
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
              GoRoute(
                path: '/review',
                builder: (_, _) =>
                    const _PlaceholderScreen(label: '/review'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/export',
                builder: (_, _) =>
                    const _PlaceholderScreen(label: '/export'),
              ),
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
  Widget build(BuildContext context) => const HomeScreen();
}

/// T16 将替换为真实 screen;此处仅占位以打通路由。
class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(label)));
}
