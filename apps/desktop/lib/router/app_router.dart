// lib/router/app_router.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../components/cs_scaffold.dart';

/// 全局 GoRouter。
///
/// `StatefulShellRoute.indexedStack` 提供 4 branch(`/home /import /review
/// /export`),每个 branch 独立导航栈,shell(CScaffold)持久化。导航通过
/// `context.go('/review')` 等触发,替换原 `AppSection` enum 切换。
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
                builder: (_, _) => const _PlaceholderScreen(label: '/home'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/import',
                builder: (_, _) => const _PlaceholderScreen(label: '/import'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/review',
                builder: (_, _) => const _PlaceholderScreen(label: '/review'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/export',
                builder: (_, _) => const _PlaceholderScreen(label: '/export'),
              ),
            ],
          ),
        ],
      ),
    ],
  ),
);

/// T15/T16 将替换为真实 screen;此处仅占位以打通路由。
class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}
