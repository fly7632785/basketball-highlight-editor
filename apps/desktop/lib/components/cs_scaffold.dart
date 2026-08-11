// lib/components/cs_scaffold.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/session_provider.dart';
import '../providers/project_state.dart';
import '../providers/sidebar_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';
import 'cs_bottom_nav.dart';
import 'cs_sidebar_shell.dart';

class CsScaffold extends ConsumerStatefulWidget {
  const CsScaffold({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<CsScaffold> createState() => _CsScaffoldState();
}

class _CsScaffoldState extends ConsumerState<CsScaffold> {
  @override
  Widget build(BuildContext context) {
    final shell = widget.shell;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= Breakpoints.md;
        if (wide) {
          final sidebarExtended = ref.watch(sidebarExtendedProvider);
          return Scaffold(
            body: Row(
              children: <Widget>[
                CsSidebarShell(
                  shell: shell,
                  extended: sidebarExtended,
                  onToggle: () =>
                      ref.read(sidebarExtendedProvider.notifier).toggle(),
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

class CsTopBar extends ConsumerWidget {
  const CsTopBar({required this.shell, this.compact = false, super.key});

  final StatefulNavigationShell shell;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppColors.of(context);
    final engineAsync = ref.watch(engineBootstrapProvider);
    final themeMode = ref.watch(themeModeProvider);
    final projectState = ref.watch(projectProvider);
    final projectLabel = _activeProjectLabel(projectState);

    return Container(
      height: WorkspaceMetrics.globalBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          bottom: BorderSide(color: c.border.withValues(alpha: 0.7)),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(CupertinoIcons.film, size: 14, color: c.textTertiary),
          const SizedBox(width: Spacing.sm),
          Flexible(
            child: Text(
              projectLabel ?? '本地视频工作区',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: projectLabel == null ? c.textTertiary : c.textSecondary,
              ),
            ),
          ),
          _EngineStatusChip(async: engineAsync),
          const Spacer(),
          if (shell.currentIndex != 0)
            IconButton(
              tooltip: '关闭当前项目',
              icon: Icon(
                CupertinoIcons.xmark_circle,
                size: 17,
                color: c.textSecondary,
              ),
              onPressed: projectState.busy
                  ? null
                  : () => _confirmCloseProject(context, ref, shell),
            ),
          if (!compact) ...<Widget>[
            Icon(CupertinoIcons.lock_shield, size: 12, color: c.textSecondary),
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
                  ? CupertinoIcons.moon
                  : themeMode == ThemeMode.light
                  ? CupertinoIcons.sun_max
                  : CupertinoIcons.device_desktop,
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

  static String? _activeProjectLabel(ProjectState state) {
    final video = state.video;
    if (video == null) return null;
    final values = <Object?>[
      video['display_name'],
      video['filename'],
      video['file_name'],
      video['name'],
    ];
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
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

Future<void> _confirmCloseProject(
  BuildContext context,
  WidgetRef ref,
  StatefulNavigationShell shell,
) async {
  final state = ref.read(projectProvider);
  final session = ref.read(projectSessionProvider);
  if (state.busy) return;
  if (session.projectRoot == null && state.video == null) {
    shell.goBranch(0);
    return;
  }

  final analyzing = state.analysisRunning;
  final exporting = state.exportRunning;
  final busy = analyzing || exporting;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(busy ? '任务仍在进行' : '关闭当前项目？'),
      content: Text(
        busy ? '关闭项目会先取消当前任务，项目数据和原始视频不会被删除。' : '项目数据和原始视频会保留，下次可以从项目列表重新打开。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('返回'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(busy ? '取消任务并关闭' : '关闭项目'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final closed = busy
      ? await ref.read(projectProvider.notifier).cancelTasksAndCloseProject()
      : await ref.read(projectProvider.notifier).closeProjectSafely();
  if (closed && context.mounted) shell.goBranch(0);
}

class _EngineStatusChip extends StatelessWidget {
  const _EngineStatusChip({required this.async});

  final AsyncValue<bool> async;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (label, color, icon) = async.when(
      data: (v) => v
          ? ('Engine 就绪', c.goal, CupertinoIcons.check_mark_circled_solid)
          : ('Engine 未启动', c.excluded, CupertinoIcons.xmark_circle),
      loading: () => ('等待 Engine', c.pending, CupertinoIcons.clock),
      error: (_, _) =>
          ('Engine 错误', c.error, CupertinoIcons.exclamationmark_circle),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(CsRadius.full),
        border: Border.all(color: color.withValues(alpha: 0.2)),
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
