// lib/components/cs_bottom_nav.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_colors.dart';

/// 移动/窄窗底栏:`< md(900)` 时由 CsScaffold 渲染。
///
/// M3 `NavigationBar`,4 destination(项目/导入/审核/导出 + Cupertino 图标)。
/// `onDestinationSelected` → `shell.goBranch(index)`。selected 图标与指示器
/// 用 indigo;unselected 用 textSecondary。
class CsBottomNav extends StatelessWidget {
  const CsBottomNav({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return NavigationBar(
      selectedIndex: shell.currentIndex,
      onDestinationSelected: (i) => shell.goBranch(i),
      backgroundColor: c.surface,
      indicatorColor: c.indigo.withValues(alpha: 0.16),
      destinations: <NavigationDestination>[
        NavigationDestination(
          icon: Icon(CupertinoIcons.house, color: c.textSecondary),
          selectedIcon: Icon(CupertinoIcons.house_fill, color: c.indigo),
          label: '项目',
        ),
        NavigationDestination(
          icon: Icon(CupertinoIcons.add_circled, color: c.textSecondary),
          selectedIcon: Icon(CupertinoIcons.add_circled_solid, color: c.indigo),
          label: '导入',
        ),
        NavigationDestination(
          icon: Icon(CupertinoIcons.check_mark_circled, color: c.textSecondary),
          selectedIcon: Icon(
            CupertinoIcons.check_mark_circled_solid,
            color: c.indigo,
          ),
          label: '审核',
        ),
        NavigationDestination(
          icon: Icon(CupertinoIcons.arrow_down_to_line, color: c.textSecondary),
          selectedIcon: Icon(
            CupertinoIcons.arrow_down_to_line,
            color: c.indigo,
          ),
          label: '导出',
        ),
      ],
    );
  }
}
