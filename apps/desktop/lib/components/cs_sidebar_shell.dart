// lib/components/cs_sidebar_shell.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/app_colors.dart';
import '../theme/tokens.dart';
import '../core/contact_actions.dart';
import '../features/about/about_dialog.dart';

/// 桌面侧栏:`≥ md(900)` 时显示；展开/收缩由用户控制，宽度不足时自动使用折叠态。
///
/// Logo(Courtside)+ 4 CsSidebarItem + 底部隐私徽章。导航通过
/// `shell.goBranch(index)` 切换 StatefulNavigationShell 的当前 branch。
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
      width: extended ? 224 : 76,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SidebarBrand(extended: extended, onToggle: onToggle),
          const SizedBox(height: 2),
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
          _UtilityItem(
            label: '反馈',
            icon: LucideIcons.messageCircle,
            extended: extended,
            onTap: () => _openFeedback(context),
          ),
          _UtilityItem(
            label: '关于',
            icon: LucideIcons.info,
            extended: extended,
            onTap: () => showCourtsideAboutDialog(context),
          ),
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
                  LucideIcons.shield,
                  size: 12,
                  color: c.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openFeedback(BuildContext context) async {
    final opened = await openExternalUri(feedbackMailto());
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未找到可用的邮件客户端，请手动联系反馈邮箱。')));
    }
  }
}

class _UtilityItem extends StatelessWidget {
  const _UtilityItem({
    required this.label,
    required this.icon,
    required this.extended,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final child = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: extended ? 10 : 12,
        vertical: 1,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(CsRadius.sm),
          onTap: onTap,
          child: SizedBox(
            height: 34,
            child: Row(
              mainAxisAlignment: extended
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: c.textTertiary),
                if (extended) ...[
                  const SizedBox(width: Spacing.sm + 2),
                  Text(
                    label,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return extended ? child : Tooltip(message: label, child: child);
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

class _SidebarBrand extends StatelessWidget {
  const _SidebarBrand({required this.extended, required this.onToggle});

  final bool extended;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final brand = Container(
      height: 46,
      padding: EdgeInsets.symmetric(horizontal: extended ? 10 : 6),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Container(
            width: extended ? 30 : 32,
            height: extended ? 30 : 32,
            decoration: BoxDecoration(
              color: c.orange.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(CsRadius.sm),
            ),
            child: Icon(
              Icons.sports_basketball_rounded,
              size: 19,
              color: c.orange,
            ),
          ),
          if (extended) ...[
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'BHE',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.1,
                ),
              ),
            ),
          ],
          if (extended) ...[
            const SizedBox(width: 2),
            SizedBox(
              width: 26,
              height: 30,
              child: IconButton(
                tooltip: '收缩侧栏',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: onToggle,
                icon: Icon(
                  LucideIcons.chevronLeft,
                  size: 15,
                  color: c.textSecondary,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(width: 2),
            Expanded(
              child: Tooltip(
                message: '展开侧栏',
                child: InkWell(
                  hoverColor: Colors.transparent,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(CsRadius.sm),
                  child: const SizedBox(
                    height: 32,
                    child: Center(
                      child: Icon(LucideIcons.chevronRight, size: 14),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(extended ? 10 : 0, 8, extended ? 10 : 0, 4),
      child: extended ? brand : Center(child: brand),
    );
  }
}

/// 单个侧栏项。
///
/// 选中态:局部橙色背景 + 文字 w600 + 图标橙色;
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
    final fg = selected ? c.orange : c.textSecondary;
    final iconData = selected ? (selectedIcon ?? icon) : icon;

    final inner = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: extended ? 14 : 12,
        vertical: extended ? 2 : 1,
      ),
      child: Material(
        color: selected ? c.orange.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(CsRadius.sm),
        child: InkWell(
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          borderRadius: BorderRadius.circular(CsRadius.sm),
          onTap: onTap,
          child: SizedBox(
            height: extended ? 38 : 36,
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
      ),
    );
    return extended ? inner : Tooltip(message: label, child: inner);
  }
}
