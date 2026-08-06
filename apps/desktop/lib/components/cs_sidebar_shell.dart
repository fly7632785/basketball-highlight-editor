// lib/components/cs_sidebar_shell.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/app_colors.dart';
import '../theme/tokens.dart';

/// 桌面侧栏:`≥ md(900)` 时显示,`≥ lg(1280)` 时展开(232)否则折叠(76)。
///
/// Logo(Courtside)+ 4 CsSidebarItem + 底部隐私徽章。导航通过
/// `shell.goBranch(index)` 切换 StatefulNavigationShell 的当前 branch。
class CsSidebarShell extends StatelessWidget {
  const CsSidebarShell({
    required this.shell,
    required this.extended,
    super.key,
  });

  final StatefulNavigationShell shell;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: extended ? 232 : 76,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.lg,
              Spacing.md,
              Spacing.lg,
            ),
            child: Row(
              mainAxisAlignment: extended
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: <Widget>[
                Icon(LucideIcons.volleyball, size: 22, color: c.orange),
                if (extended) ...<Widget>[
                  const SizedBox(width: Spacing.sm),
                  Text(
                    'Courtside',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
          _NavItem(
            shell: shell,
            index: 0,
            label: '项目',
            icon: LucideIcons.home,
            extended: extended,
          ),
          _NavItem(
            shell: shell,
            index: 1,
            label: '导入',
            icon: LucideIcons.upload,
            extended: extended,
          ),
          _NavItem(
            shell: shell,
            index: 2,
            label: '审核',
            icon: LucideIcons.folderCheck,
            extended: extended,
          ),
          _NavItem(
            shell: shell,
            index: 3,
            label: '导出',
            icon: LucideIcons.download,
            extended: extended,
          ),
          const Spacer(),
          if (extended)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                0,
                Spacing.md,
                Spacing.lg,
              ),
              child: Row(
                children: <Widget>[
                  Icon(LucideIcons.shield, size: 12, color: c.textTertiary),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    '本地处理',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.lg),
              child: Center(
                child: Icon(LucideIcons.shield, size: 12, color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.shell,
    required this.index,
    required this.label,
    required this.icon,
    required this.extended,
  });

  final StatefulNavigationShell shell;
  final int index;
  final String label;
  final IconData icon;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    return CsSidebarItem(
      label: label,
      icon: icon,
      selected: shell.currentIndex == index,
      extended: extended,
      onTap: () => shell.goBranch(index),
    );
  }
}

/// 单个侧栏项。
///
/// 选中态:左 3px indigo 条 + indigo 8% 背景 + 文字 w600 + 图标 indigo;
/// 未选中:textSecondary。折叠态(extended=false)只显示图标 + Tooltip(label)。
class CsSidebarItem extends StatelessWidget {
  const CsSidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.extended,
    required this.onTap,
    this.selectedIcon,
    super.key,
  });

  final String label;
  final IconData icon;
  final IconData? selectedIcon;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final fg = selected ? c.indigo : c.textSecondary;
    final iconData = selected ? (selectedIcon ?? icon) : icon;

    final inner = Material(
      color: selected ? c.indigo.withValues(alpha: 0.08) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: extended ? Spacing.md : Spacing.sm,
            vertical: Spacing.sm + 2,
          ),
          child: Row(
            mainAxisAlignment: extended
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: <Widget>[
              Icon(iconData, size: 18, color: fg),
              if (extended) ...<Widget>[
                const SizedBox(width: Spacing.sm + 2),
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: selected ? c.textPrimary : c.textSecondary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    final withMarker = Stack(
      children: <Widget>[
        inner,
        if (selected)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(width: 3, color: c.indigo),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: extended
          ? withMarker
          : Tooltip(message: label, child: withMarker),
    );
  }
}
