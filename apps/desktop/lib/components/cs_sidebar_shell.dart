// lib/components/cs_sidebar_shell.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsSidebarShell extends StatelessWidget {
  const CsSidebarShell({
    required this.shell,
    required this.extended,
    required this.onToggle,
    super.key,
  });

  final StatefulNavigationShell shell;
  final bool extended;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: extended
          ? WorkspaceMetrics.sidebarExpanded
          : WorkspaceMetrics.sidebarCollapsed,
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.82),
        border: Border(
          right: BorderSide(color: c.border.withValues(alpha: 0.68)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              extended ? Spacing.md : 6,
              Spacing.md,
              extended ? Spacing.sm : 6,
              Spacing.md,
            ),
            child: Row(
              mainAxisAlignment: extended
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.orange.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                  ),
                  child: Icon(
                    CupertinoIcons.sportscourt,
                    size: 17,
                    color: c.orange,
                  ),
                ),
                if (extended) ...<Widget>[
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      'Courtside',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.25,
                      ),
                    ),
                  ),
                ],
                if (extended) const SizedBox(width: Spacing.xs),
                SizedBox(
                  width: extended ? 28 : 18,
                  height: 30,
                  child: IconButton(
                    tooltip: extended ? '收缩侧栏' : '展开侧栏',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed: onToggle,
                    icon: Icon(
                      extended
                          ? CupertinoIcons.chevron_left
                          : CupertinoIcons.chevron_right,
                      size: 13,
                      color: c.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.xs),
          _NavItem(
            shell: shell,
            index: 0,
            label: '项目',
            icon: CupertinoIcons.rectangle_grid_2x2,
            extended: extended,
          ),
          _NavItem(
            shell: shell,
            index: 1,
            label: '导入',
            icon: CupertinoIcons.add_circled,
            extended: extended,
          ),
          _NavItem(
            shell: shell,
            index: 2,
            label: '审核',
            icon: CupertinoIcons.check_mark_circled,
            extended: extended,
          ),
          _NavItem(
            shell: shell,
            index: 3,
            label: '导出',
            icon: CupertinoIcons.arrow_down_to_line,
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
                  Icon(
                    CupertinoIcons.lock_shield,
                    size: 12,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    '本地处理',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.lg),
              child: Center(
                child: Icon(
                  CupertinoIcons.lock_shield,
                  size: 12,
                  color: c.textTertiary,
                ),
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
      color: selected ? c.indigo.withValues(alpha: 0.16) : Colors.transparent,
      borderRadius: BorderRadius.circular(CsRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(CsRadius.sm),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: extended ? 12 : Spacing.sm,
            vertical: 10,
          ),
          child: Row(
            mainAxisAlignment: extended
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: <Widget>[
              Icon(iconData, size: 16, color: fg),
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

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: extended ? Spacing.sm : Spacing.xs,
        vertical: 2,
      ),
      child: extended ? inner : Tooltip(message: label, child: inner),
    );
  }
}
