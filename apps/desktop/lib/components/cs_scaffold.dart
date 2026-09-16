// lib/components/cs_scaffold.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import '../providers/session_provider.dart';
import '../providers/project_state.dart';
import '../providers/locale_provider.dart';
import '../providers/sidebar_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';
import '../core/contact_actions.dart';
import '../features/about/about_dialog.dart';
import 'cs_bottom_nav.dart';
import 'cs_sidebar_shell.dart';

/// 自适应 shell:宽窗(≥ md)侧栏 + 内容;窄窗内容 + 底栏。
///
/// LayoutBuilder 切换两种布局。两种布局均在内容顶部保留 CsTopBar(标题 +
/// Engine 状态胶囊 + 隐私徽章 + 主题切换)。侧栏状态会持久化，创建项目后默认收缩。
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
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final title = switch (shell.currentIndex) {
      0 => l10n?.navProject ?? '项目',
      1 => l10n?.navImport ?? '导入',
      2 => l10n?.navReview ?? '审核',
      _ => l10n?.navExport ?? '导出',
    };
    final engineAsync = ref.watch(engineBootstrapProvider);
    final themeMode = ref.watch(themeModeProvider);
    final projectState = ref.watch(projectProvider);

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: c.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: Spacing.md),
          _EngineStatusChip(async: engineAsync),
          const Spacer(),
          if (shell.currentIndex != 0)
            IconButton(
              tooltip: l10n?.confirmCloseProject ?? '关闭当前项目',
              icon: Icon(LucideIcons.folderX, size: 17, color: c.textSecondary),
              onPressed: projectState.busy
                  ? null
                  : () => _confirmCloseProject(context, ref, shell),
            ),
          if (!compact) ...<Widget>[
            Icon(LucideIcons.shield, size: 12, color: c.textSecondary),
            const SizedBox(width: Spacing.xs),
            Text(
              l10n?.localProcessing ?? '本地处理',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(width: Spacing.md),
          ],
          PopupMenuButton<String>(
            tooltip: l10n?.more ?? '更多',
            icon: Icon(
              LucideIcons.moreHorizontal,
              size: 18,
              color: c.textSecondary,
            ),
            onSelected: (value) => _handleUtilityAction(context, value),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'feedback',
                child: Text(l10n?.feedback ?? '反馈'),
              ),
              PopupMenuItem(
                value: 'about',
                child: Text(l10n?.about ?? '关于 BHE'),
              ),
            ],
          ),
          IconButton(
            tooltip: l10n?.switchTheme ?? '切换主题',
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
          PopupMenuButton<Locale>(
            tooltip: l10n?.switchLanguage ?? '切换语言',
            icon: Icon(LucideIcons.languages, size: 18, color: c.textSecondary),
            onSelected: (locale) =>
                ref.read(appLocaleProvider.notifier).set(locale),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: BheLocale.zh,
                child: Text(l10n?.languageChinese ?? '简体中文'),
              ),
              PopupMenuItem(
                value: BheLocale.en,
                child: Text(l10n?.languageEnglish ?? 'English'),
              ),
            ],
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

  Future<void> _handleUtilityAction(BuildContext context, String value) async {
    if (value == 'about') {
      await showCourtsideAboutDialog(context);
      return;
    }
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final opened = await openExternalUri(
      feedbackMailto(english: l10n?.localeName.startsWith('en') == true),
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n?.feedbackMailClientMissing ??
                '未找到可用的邮件客户端，请手动联系反馈邮箱。',
          ),
        ),
      );
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
  final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
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
      title: Text(
        busy
            ? (l10n?.taskInProgress ?? '任务仍在进行')
            : (l10n?.confirmCloseProject ?? '关闭当前项目？'),
      ),
      content: Text(
        busy
            ? (l10n?.closeProjectBusyDescription ??
                  '关闭项目会先取消当前任务，项目数据和原始视频不会被删除。')
            : (l10n?.closeProjectDescription ?? '项目数据和原始视频会保留，下次可以从项目列表重新打开。'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n?.returnAction ?? '返回'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            busy
                ? (l10n?.cancelTaskAndClose ?? '取消任务并关闭')
                : (l10n?.closeProject ?? '关闭项目'),
          ),
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
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final (label, color, icon) = async.when(
      data: (v) => v
          ? (l10n?.engineReady ?? 'Engine 就绪', c.goal, LucideIcons.circleCheck)
          : (
              l10n?.engineNotStarted ?? 'Engine 未启动',
              c.excluded,
              LucideIcons.ban,
            ),
      loading: () => (
        l10n?.waitingEngine ?? '等待 Engine',
        c.pending,
        LucideIcons.hourglass,
      ),
      error: (_, _) =>
          (l10n?.engineError ?? 'Engine 错误', c.error, LucideIcons.circleAlert),
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
