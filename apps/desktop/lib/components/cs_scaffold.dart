// lib/components/cs_scaffold.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../providers/session_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';
import 'cs_bottom_nav.dart';
import 'cs_sidebar_shell.dart';

/// 自适应 shell:宽窗(≥ md)侧栏 + 内容;窄窗内容 + 底栏。
///
/// LayoutBuilder 切换两种布局。两种布局均在内容顶部保留 CsTopBar(标题 +
/// Engine 状态胶囊 + 隐私徽章 + 主题切换)。
class CsScaffold extends ConsumerWidget {
  const CsScaffold({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= Breakpoints.md;
        if (wide) {
          return Scaffold(
            body: Row(
              children: <Widget>[
                CsSidebarShell(
                  shell: shell,
                  // 审核页优先留给视频和候选队列，导航默认收缩为图标栏。
                  extended:
                      constraints.maxWidth >= Breakpoints.lg &&
                      shell.currentIndex != 2,
                ),
                Expanded(
                  child: Column(
                    children: <Widget>[
                      CsTopBar(shell: shell),
                      Expanded(child: shell),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          body: Column(
            children: <Widget>[
              CsTopBar(shell: shell, compact: true),
              Expanded(child: shell),
            ],
          ),
          bottomNavigationBar: CsBottomNav(shell: shell),
        );
      },
    );
  }
}

const List<String> _branchLabels = <String>['项目', '导入', '审核', '导出'];

/// 顶部条:branch 标题 + Engine 胶囊 + 隐私徽章 + 主题切换 IconButton。
///
/// 放在 cs_scaffold.dart 内(与 Scaffold 同文件,无独立 spec 章节)。Engine
/// 状态胶囊通过私有 _EngineStatusChip 渲染,使用 AppColors 的语义色而非
/// CsStatusChip 的 ReviewStatus(因为 Engine 的 loading/error/ready 三态
/// 语义不是 goal/pending/excluded,自定义胶囊更直接)。
class CsTopBar extends ConsumerWidget {
  const CsTopBar({required this.shell, this.compact = false, super.key});

  final StatefulNavigationShell shell;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppColors.of(context);
    final title = _branchLabels[shell.currentIndex];
    final engineAsync = ref.watch(engineBootstrapProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: c.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: Spacing.md),
          _EngineStatusChip(async: engineAsync),
          const Spacer(),
          if (!compact) ...<Widget>[
            Icon(LucideIcons.shield, size: 12, color: c.textSecondary),
            const SizedBox(width: Spacing.xs),
            Text(
              '本地处理',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(width: Spacing.md),
          ],
          IconButton(
            tooltip: '切换主题',
            icon: Icon(
              themeMode == ThemeMode.dark
                  ? LucideIcons.moon
                  : themeMode == ThemeMode.light
                  ? LucideIcons.sun
                  : LucideIcons.monitor,
              size: 18,
              color: c.textSecondary,
            ),
            onPressed: () {
              ref
                  .read(themeModeProvider.notifier)
                  .set(_nextThemeMode(themeMode));
            },
          ),
        ],
      ),
    );
  }

  static ThemeMode _nextThemeMode(ThemeMode current) {
    switch (current) {
      case ThemeMode.system:
        return ThemeMode.light;
      case ThemeMode.light:
        return ThemeMode.dark;
      case ThemeMode.dark:
        return ThemeMode.system;
    }
  }
}

class _EngineStatusChip extends StatelessWidget {
  const _EngineStatusChip({required this.async});

  final AsyncValue<bool> async;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (label, color, icon) = async.when(
      data: (v) => v
          ? ('Engine 就绪', c.goal, LucideIcons.circleCheck)
          : ('Engine 未启动', c.excluded, LucideIcons.ban),
      loading: () => ('等待 Engine', c.pending, LucideIcons.hourglass),
      error: (_, _) => ('Engine 错误', c.error, LucideIcons.circleAlert),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(CsRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
