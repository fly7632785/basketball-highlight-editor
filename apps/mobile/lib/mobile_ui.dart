import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'app_updater.dart';
import 'clip_range_editor.dart';
import 'features/video_source/video_playback.dart';
import 'features/video_source/video_source_failure.dart';
import 'features/video_source/video_unavailable.dart';
import 'features/roi_editor/roi_video_preview.dart';
import 'mobile_app_state.dart';
import 'features/project_list/project_catalog.dart';
import 'features/project_list/project_video_metadata.dart';
import 'features/export/export_modes.dart';
import 'features/review_tiers/mobile_tiers.dart';
import 'features/diagnostics/mobile_diagnostics.dart';
import 'features/diagnostics/diagnostic_report.dart';
import 'mobile_theme.dart';
import 'features/diagnostics/friendly_error.dart' show portraitSourceAlreadyVertical;
import 'media_bridge.dart' show PortraitExportProgress, PortraitExportStep;
import 'features/game_stats/game_stats.dart';

export 'mobile_theme.dart' show BhePalette, bheTheme;

part 'features/toast/bhe_toast.dart';
part 'features/video_source/video_source_notice.dart';
part 'features/diagnostics/diagnostic_sheet.dart';
part 'features/video_source/review_video_source.dart';
part 'features/video_source/video_preview.dart';
part 'features/video_source/review_controls.dart';
part 'features/review_tiers/review_tier_controls.dart';
part 'features/export/export_audio_notice.dart';
part 'features/game_stats/game_stats_section.dart';
part 'features/export/untagged_reminder.dart';
part 'features/roi_editor/roi_editor_sheet.dart';
part 'features/review_undo/review_notice.dart';
part 'features/player_tags/player_tag_sheet.dart';
part 'features/project_rename/project_rename_dialog.dart';
part 'features/player_roster/roster_confirmation.dart';
part 'features/player_groups/player_groups_sheet.dart';
part 'features/player_groups/player_group_editor.dart';
part 'features/operation_status/uncertain_task_notice.dart';
part 'features/export/export_overlap_notice.dart';
part 'features/project_list/project_list_page.dart';
part 'features/project_list/project_info_page.dart';
part 'features/export/export_modes_ui.dart';
part 'features/export/export_settings_ui.dart';
part 'features/export/export_result_ui.dart';
part 'features/export/portrait_export_ui.dart';
part 'features/export_history/export_history_ui.dart';

// (Theme extracted to mobile_theme.dart for maintainability.)

enum _WorkspaceSection { project, review, export, exportGoals }

class BheMobileApp extends StatefulWidget {
  const BheMobileApp({super.key, this.appState, this.exportAllowanceBuilder});
  final MobileAppState? appState;
  final WidgetBuilder? exportAllowanceBuilder;

  @override
  State<BheMobileApp> createState() => _BheMobileAppState();
}

class _BheMobileAppState extends State<BheMobileApp> {
  late final state = widget.appState ?? MobileAppState();
  final updater = AppUpdater();
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  Timer? _updateCheckTimer;
  Timer? _closeNoticeTimer;
  bool _showCloseNotice = false;
  _WorkspaceSection section = _WorkspaceSection.project;
  bool dark = true;
  Locale _locale = BheLocale.fromSystem(
    WidgetsBinding.instance.platformDispatcher.locale,
  );
  String? _lastProjectId;
  String? _lastAnalysisStatus;
  DateTime? _lastBackPress;
  bool _wasExporting = false;
  bool _starPromptHandled = false;
  String? _lastHistoryWarning;
  String? _lastGallerySaveNotice;

  @override
  void initState() {
    super.initState();
    _lastProjectId = state.project.id;
    _lastAnalysisStatus = state.project.lastAnalysisStatus;
    state.addListener(_handleStateChange);
    unawaited(_loadLocale());
    _updateCheckTimer = Timer(const Duration(seconds: 5), _autoCheckUpdate);
  }

  Future<void> _autoCheckUpdate() async {
    if (!await updater.autoCheck() || !mounted) return;
    final context = _navigatorKey.currentContext;
    final version = updater.targetVersion;
    if (context == null || version == null || !context.mounted) return;
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(context.bheText('发现新版本 v$version')),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: context.bheText('查看'),
          onPressed: () {
            final sheetContext = _navigatorKey.currentContext;
            if (sheetContext != null) {
              unawaited(_showUpdateSheet(sheetContext, updater, state));
            }
          },
        ),
      ),
    );
  }

  Future<void> _loadLocale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('bhe.locale');
      if (saved != null && mounted) {
        setState(() => _locale = BheLocale.fromName(saved));
      }
      unawaited(MobileDiagnostics.instance.initialize(
        version: mobileAppVersion,
        language: _locale.toLanguageTag(),
      ));
    } catch (_) {
      // 读取失败时保留系统语言，不影响应用启动。
    }
  }

  Future<void> _setLocale(Locale locale) async {
    final normalized = BheLocale.fromName(locale.toLanguageTag());
    setState(() => _locale = normalized);
    unawaited(MobileDiagnostics.instance.initialize(
      version: mobileAppVersion,
      language: normalized.toLanguageTag(),
    ));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bhe.locale', normalized.toLanguageTag());
    } catch (_) {
      // 持久化失败时仍保留本次运行的语言选择。
    }
  }

  void _handleStateChange() {
    if (state.projectTransitioning && state.closingProject) {
      _closeNoticeTimer ??= Timer(const Duration(milliseconds: 600), () {
        if (mounted && state.projectTransitioning && state.closingProject) {
          setState(() => _showCloseNotice = true);
        }
      });
    } else {
      _closeNoticeTimer?.cancel();
      _closeNoticeTimer = null;
      if (_showCloseNotice && mounted) setState(() => _showCloseNotice = false);
    }
    final warning = state.exportHistoryWarning;
    final gallerySaveNotice = state.gallerySaveNotice;
    if (gallerySaveNotice != _lastGallerySaveNotice) {
      _lastGallerySaveNotice = gallerySaveNotice;
      if (gallerySaveNotice != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || state.gallerySaveNotice != gallerySaveNotice) return;
          final context = _navigatorKey.currentContext;
          if (context == null || !context.mounted) return;
          showBheToast(context, context.bheText(gallerySaveNotice));
        });
      }
    }
    if (warning != _lastHistoryWarning) {
      _lastHistoryWarning = warning;
      if (warning != null) {
        final diagnostic = state.exportHistoryDiagnostic;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || state.exportHistoryWarning != warning) return;
          final context = _navigatorKey.currentContext;
          if (context == null || !context.mounted) return;
          _messengerKey.currentState?.showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            content: Text(context.bheText(warning)),
            action: SnackBarAction(label: context.bheText('反馈'), onPressed: () => showMobileDiagnostics(context, error: diagnostic)),
          ));
        });
      }
    }
    final gallerySaved =
        _wasExporting &&
        !state.exporting &&
        state.exportedPaths.isNotEmpty &&
        state.errorMessage == null &&
        !state.exportCancelled;
    _wasExporting = state.exporting;
    if (gallerySaved) unawaited(_maybeShowStarPrompt());

    final projectChanged = state.project.id != _lastProjectId;
    if (projectChanged) {
      _lastProjectId = state.project.id;
      section = _WorkspaceSection.project;
    }
    final status = state.project.lastAnalysisStatus;
    var sectionChanged = projectChanged;
    if (status != _lastAnalysisStatus) {
      _lastAnalysisStatus = status;
      if (status == 'completed' && state.project.candidates.isNotEmpty) {
        section = _WorkspaceSection.review;
        sectionChanged = true;
      }
    }
    if (mounted && sectionChanged) setState(() {});
  }

  Future<void> _maybeShowStarPrompt() async {
    if (_starPromptHandled || !mounted) return;
    _starPromptHandled = true;
    final prefs = await SharedPreferences.getInstance();
    const key = 'bhe.github-star-prompt-shown';
    if (prefs.getBool(key) ?? false) return;
    await prefs.setBool(key, true);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_showStarPrompt());
    });
  }

  Future<void> _showStarPrompt() async {
    final dialogRoot = _navigatorKey.currentContext;
    if (dialogRoot == null || !dialogRoot.mounted) return;
    final l10n = Localizations.of<BheLocalizations>(dialogRoot, BheLocalizations);
    await showDialog<void>(
      context: dialogRoot,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(LucideIcons.heart, color: BhePalette.orange),
        title: Text(dialogRoot.bheText('如果 BHE 对你有帮助')),
        content: Text(
          dialogRoot.bheText(
            '如果 BHE 帮你省下了一些剪辑时间，欢迎在 GitHub 点个 Star，也可以分享给球友，让更多人知道这个项目。谢谢支持！',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n?.text('以后再说') ?? '以后再说'),
          ),
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await SharePlus.instance.share(
                ShareParams(
                  text: dialogRoot.bheText('我在用 BHE 整理篮球比赛集锦，推荐你看看：'),
                  uri: Uri.parse(
                    'https://github.com/fly7632785/basketball-highlight-editor',
                  ),
                ),
              );
            },
            icon: const Icon(LucideIcons.share2, size: 17),
            label: Text(l10n?.text('分享给球友') ?? '分享给球友'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await launchUrl(
                Uri.parse(
                  'https://github.com/fly7632785/basketball-highlight-editor',
                ),
                mode: LaunchMode.externalApplication,
              );
            },
            icon: const Icon(LucideIcons.star, size: 17),
            label: Text(l10n?.text('去 GitHub 点个 Star') ?? '去 GitHub 点个 Star'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _updateCheckTimer?.cancel();
    _closeNoticeTimer?.cancel();
    updater.dispose();
    state.removeListener(_handleStateChange);
    if (widget.appState == null) { state.dispose(); }
    super.dispose();
  }

  void _handleSystemBack(BuildContext context) {
    if (state.projectTransitioning) return;
    if (state.analysing) return;
    if (section != _WorkspaceSection.project) {
      setState(() => section = _WorkspaceSection.project);
      return;
    }
    final now = DateTime.now();
    final previous = _lastBackPress;
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    showBheToast(
      context,
      Localizations.of<BheLocalizations>(
            context,
            BheLocalizations,
          )?.pressBackAgainToExit ??
          '再按一次返回键退出 BHE',
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'BHE',
    navigatorKey: _navigatorKey,
    scaffoldMessengerKey: _messengerKey,
    locale: _locale,
    localizationsDelegates: BheLocalizations.localizationsDelegates,
    supportedLocales: BheLocalizations.supportedLocales,
    theme: bheTheme(Brightness.light),
    darkTheme: bheTheme(Brightness.dark),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, child) => AnimatedBuilder(
      animation: state,
      child: child,
      builder: (context, child) => Stack(children: [
        AbsorbPointer(
          absorbing: state.projectTransitioning,
          child: Opacity(opacity: state.projectTransitioning ? .55 : 1, child: child),
        ),
        if (state.projectTransitioning && (!state.closingProject || _showCloseNotice))
          Positioned(top: 0, left: 0, right: 0, child: SafeArea(
            child: Material(
              key: const ValueKey('project-transition-notice'),
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(context.bheText('正在切换项目，请稍候'), textAlign: TextAlign.center),
              ),
            ),
          )),
      ]),
    ),
    home: Builder(
      builder: (context) => PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _handleSystemBack(context);
        },
        child: AnimatedBuilder(
          animation: state,
          builder: (context, _) => _AppShell(
            state: state,
            exportAllowanceBuilder: widget.exportAllowanceBuilder,
            dark: dark,
            onToggleTheme: () => setState(() => dark = !dark),
            onLocaleChanged: _setLocale,
            section: state.analysing ? _WorkspaceSection.project : section,
            onSectionChanged: (value) => setState(() => section = value),
            onCreateProject: () {
              unawaited(_createManagedProject(context, state));
            },
            onCheckUpdate: () =>
                unawaited(_showUpdateSheet(context, updater, state)),
          ),
        ),
      ),
    ),
  );
}

class _AppShell extends StatelessWidget {
  const _AppShell({
    required this.state,
    required this.exportAllowanceBuilder,
    required this.dark,
    required this.onToggleTheme,
    required this.onLocaleChanged,
    required this.section,
    required this.onSectionChanged,
    required this.onCreateProject,
    required this.onCheckUpdate,
  });

  final MobileAppState state;
  final WidgetBuilder? exportAllowanceBuilder;
  final bool dark;
  final VoidCallback onToggleTheme;
  final ValueChanged<Locale> onLocaleChanged;
  final _WorkspaceSection section;
  final ValueChanged<_WorkspaceSection> onSectionChanged;
  final VoidCallback onCreateProject;
  final VoidCallback onCheckUpdate;

  @override
  Widget build(BuildContext context) {
    if (state.loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    if (state.analysing) return _AnalysisView(state: state);
    final page = switch (section) {
      _WorkspaceSection.project => _ProjectView(
        key: ValueKey(state.project.id),
        state: state,
        onOpenReview: () => onSectionChanged(_WorkspaceSection.review),
      ),
      _WorkspaceSection.review => VideoSourcePanel(
        state: state,
        child: _ReviewView(
          key: ValueKey(state.project.id),
          state: state,
          onOpenProject: () => onSectionChanged(_WorkspaceSection.project),
          onOpenExport: () => onSectionChanged(_WorkspaceSection.export),
          onExportGoals: () => onSectionChanged(_WorkspaceSection.exportGoals),
        ),
      ),
      _WorkspaceSection.export || _WorkspaceSection.exportGoals => _ExportView(
        key: ValueKey((section, state.project.id)),
        state: state,
        allowanceBuilder: exportAllowanceBuilder,
        goalsOnly: section == _WorkspaceSection.exportGoals,
        onBackToReview: () => onSectionChanged(_WorkspaceSection.review),
      ),
    };
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              state: state,
              dark: dark,
              onToggleTheme: onToggleTheme,
              onLocaleChanged: onLocaleChanged,
              section: section,
              onOpenProject: () => onSectionChanged(_WorkspaceSection.project),
              onOpenExport: state.project.candidates.isEmpty
                  ? null
                  : () => onSectionChanged(_WorkspaceSection.export),
              onCreateProject: onCreateProject,
              onCheckUpdate: onCheckUpdate,
            ),
            Expanded(child: page),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.dark,
    required this.onToggleTheme,
    required this.onLocaleChanged,
    required this.section,
    required this.onOpenProject,
    required this.onOpenExport,
    required this.onCreateProject,
    required this.onCheckUpdate,
  });

  final MobileAppState state;
  final bool dark;
  final VoidCallback onToggleTheme;
  final ValueChanged<Locale> onLocaleChanged;
  final _WorkspaceSection section;
  final VoidCallback onOpenProject;
  final VoidCallback? onOpenExport;
  final VoidCallback onCreateProject;
  final VoidCallback onCheckUpdate;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final exportSettings = section == _WorkspaceSection.export || section == _WorkspaceSection.exportGoals;
    final title = switch (section) {
      _WorkspaceSection.project => l10n?.appName ?? 'BHE',
      _WorkspaceSection.review => l10n?.navReview ?? '审核',
      _WorkspaceSection.export || _WorkspaceSection.exportGoals => l10n?.navExport ?? '导出',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 8),
      child: Row(
        children: [
          if (section != _WorkspaceSection.project)
            IconButton(
              onPressed: onOpenProject,
              tooltip: l10n?.backToProject ?? '返回项目',
              icon: const Icon(LucideIcons.chevronLeft, size: 23),
            ),
          Expanded(
            child: InkWell(
              onTap: onOpenProject,
              borderRadius: BorderRadius.circular(7),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    if (!exportSettings) Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: BhePalette.orange,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: const Icon(
                        LucideIcons.play,
                        color: Colors.white,
                        size: 15,
                      ),
                    ),
                    if (!exportSettings) const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Flexible(
            child: InkWell(
              key: const ValueKey('project-name-rename'),
              onTap: () => _showProjectActions(context, state),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Text(
                    state.project.video != null || state.recentProjects.any((p) => p.id == state.project.id)
                        ? state.project.name : context.bheText('项目列表'),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  )),
                  const Icon(LucideIcons.chevronDown, size: 16),
                ]),
              ),
            ),
          ),
          if (onOpenExport != null && !exportSettings)
            IconButton(
              onPressed: onOpenExport,
              tooltip: l10n?.navExport ?? '导出',
              icon: const Icon(LucideIcons.download, size: 19),
            ),
          if (!exportSettings) IconButton(
            onPressed: state.pickerBusy ? null : onCreateProject,
            tooltip: l10n?.newProject ?? '新建项目',
            icon: const Icon(LucideIcons.plus, size: 20),
          ),
          PopupMenuButton<String>(
            tooltip: l10n?.more ?? '更多操作',
            icon: const Icon(LucideIcons.ellipsis, size: 20),
            onSelected: (value) async {
              switch (value) {
                case 'theme':
                  onToggleTheme();
                  break;
                case 'language':
                  final locale = await showDialog<Locale>(
                    context: context,
                    builder: (dialog) => SimpleDialog(
                      title: Text(context.bheText('语言')),
                      children: [
                        SimpleDialogOption(onPressed: () => Navigator.pop(dialog, BheLocale.zh), child: const Text('简体中文')),
                        SimpleDialogOption(onPressed: () => Navigator.pop(dialog, BheLocale.en), child: const Text('English')),
                      ],
                    ),
                  );
                  if (locale != null) onLocaleChanged(locale);
                  break;
                case 'update':
                  onCheckUpdate();
                  break;
                case 'diagnostics':
                  await showMobileDiagnostics(
                    context, error: state.diagnosticError,
                  );
                  break;
                case 'about':
                  await _showAboutDialog(context, state);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'theme',
                child: Text(Localizations.localeOf(context).languageCode == 'zh'
                    ? '主题 · ${dark ? '深色' : '浅色'}'
                    : 'Theme · ${dark ? 'Dark' : 'Light'}'),
              ),
              PopupMenuItem(
                value: 'language',
                child: Text(Localizations.localeOf(context).languageCode == 'zh' ? '语言 · 简体中文' : 'Language · English'),
              ),
              PopupMenuItem(
                value: 'update',
                child: Text(context.bheText('检查更新')),
              ),
              PopupMenuItem(
                value: 'diagnostics',
                child: Text(context.bheText('反馈与诊断')),
              ),
              PopupMenuItem(
                value: 'about',
                child: Text(context.bheText('关于')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _showProjectActions(BuildContext context, MobileAppState state) async {
  final hasProject = state.project.video != null || state.recentProjects.any((p) => p.id == state.project.id);
  final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) {
      Widget row(String id, String label, {bool enabled = true, bool danger = false}) => InkWell(
        key: ValueKey('project-action-$id'),
        onTap: enabled ? () => Navigator.pop(sheet, id) : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          alignment: Alignment.centerLeft,
          child: Text(label, style: TextStyle(color: danger ? Theme.of(context).colorScheme.error : enabled ? null : Theme.of(context).disabledColor)),
        ),
      );
      Widget group(List<Widget> rows) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [for (final (i, item) in rows.indexed) ...[
          if (i > 0) const Padding(padding: EdgeInsets.only(left: 16), child: Divider(height: 1)), item,
        ]]),
      );
      return _SheetFrame(title: context.bheText('项目列表'), child: Column(children: [
        group([
          row('projects', context.bheText('项目列表')),
          if (hasProject) row('renameProject', context.bheText('重命名项目')),
          if (hasProject) row('projectInfo', context.bheText('项目信息')),
          row('import', l10n?.openPackage ?? '打开项目包', enabled: !state.pickerBusy),
          if (hasProject) row('closeProject', context.bheText('关闭项目')),
        ]),
        if (hasProject) ...[
          const SizedBox(height: 12),
          group([row('delete', l10n?.deleteProject ?? '删除项目', danger: true)]),
        ],
      ]));
    },
  );
  if (!context.mounted) return;
  switch (action) {
    case 'projects': await _showProjectList(context, state);
    case 'projectInfo': await _showProjectInfo(context, state, state.project);
    case 'renameProject': await _showProjectRename(context, state);
    case 'import':
      if (_canManageProjects(context, state)) {
        await state.importProject(requireIdle: true);
        if (context.mounted && state.projectManagementBlockReason != null) _canManageProjects(context, state);
      }
    case 'closeProject':
      if (_canManageProjects(context, state) && !await state.closeManagedProject() && context.mounted) _projectActionFailed(context, state);
    case 'delete':
      if (_canManageProjects(context, state)) await _confirmManagedDelete(context, state, state.project);
  }
}

class _ProjectView extends StatelessWidget {
  const _ProjectView({
    super.key,
    required this.state,
    required this.onOpenReview,
  });
  final MobileAppState state;
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width > 840 ? 900.0 : double.infinity;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
          children: [
            _PageIntro(
              eyebrow: l10n?.projectWorkspace ?? 'PROJECT WORKSPACE',
              title: state.project.video == null
                  ? (l10n?.startVideoProject ?? '开始一个视频项目')
                  : state.project.name,
              subtitle: state.project.video == null
                  ? context.bheText('新建项目，或从最近项目中打开一个')
                  : (l10n?.configureAnalysisDescription ?? '配置好分析区域后即可开始识别。'),
            ),
            VideoSourceNotice(state: state),
            if (state.hasUncertainExport) _UncertainExportNotice(state: state),
            if (state.hasUncertainAnalysis && state.project.video == null)
              _UncertainAnalysisNotice(state: state),
            if (state.preparingVideo)
              _VideoPreparationCard(message: state.preparingVideoMessage, onCancel: state.cancelVideoPreparation)
            else if (state.project.video == null)
              _EmptyProject(
                enabled: !state.pickerBusy,
                onPick: () { unawaited(_createManagedProject(context, state)); },
              )
            else
              _ProjectSetup(state: state, onOpenReview: onOpenReview),
            if (state.recentProjects.any(
              (item) => item.id != state.project.id,
            )) ...[
              const SizedBox(height: 24),
              _SectionHeader(
                title: l10n?.recentProjects ?? '最近项目',
                action: context.bheText('${state.recentProjects.length} 个'),
              ),
              const SizedBox(height: 8),
              for (final project in state.recentProjects.where(
                (item) => item.id != state.project.id,
              ))
                _RecentProjectRow(
                  project: project,
                  coverPath: state.coverPaths[project.id],
                  onTap: () { if (_canManageProjects(context, state)) state.openProject(project.id, requireIdle: true); },
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PageIntro extends StatelessWidget {
  const _PageIntro({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });
  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            letterSpacing: 1.2,
            color: BhePalette.orange,
          ),
        ),
        const SizedBox(height: 8),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 5),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _EmptyProject extends StatelessWidget {
  const _EmptyProject({required this.onPick, this.enabled = true});
  final VoidCallback onPick;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 30, 20, 30),
        child: Column(
          children: [
            const Icon(
              LucideIcons.fileVideo,
              size: 34,
              color: BhePalette.orange,
            ),
            const SizedBox(height: 16),
            Text(
              l10n?.selectMatchVideo ?? '选择一段比赛视频',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 7),
            Text(
              l10n?.mobileCandidateDescription ?? 'BHE 会在本机生成候选片段，之后由你快速审核。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: enabled ? onPick : null,
              icon: const Icon(LucideIcons.upload, size: 18),
              label: Text(l10n?.selectVideo ?? '选择视频'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectSetup extends StatelessWidget {
  const _ProjectSetup({required this.state, required this.onOpenReview});
  final MobileAppState state;
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) {
    final video = state.project.video!;
    final settings = state.project.settings;
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VideoPreview(
          key: const ValueKey('project-video-preview'),
          sourceRevision: state.videoSourceRevision,
          unavailable: state.videoSourceFailure != null,
          onFailure: state.markVideoFailure,
          path: video.path,
          aspectRatio: video.width / video.height,
          seekStepMs: 1500,
        ),
        const SizedBox(height: 12),
        Text(
          '${video.width} × ${video.height}  ·  ${_formatMs(video.durationMs)}  ·  ${_formatBytes(video.sizeBytes)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        _SectionHeader(
          title: l10n?.analysisConfig ?? '分析配置',
          action: l10n?.autoSave ?? '自动保存',
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              _SettingRow(
                icon: LucideIcons.scanLine,
                title: l10n?.analysisQuality ?? '分析质量',
                value: settings.mode == AnalysisMode.standard
                    ? (l10n?.standardQuality(
                            settings.modelInputSize,
                            settings.analysisFpsLabel,
                          ) ??
                          '标准 · ${settings.modelInputSize} 输入 / ${settings.analysisFpsLabel}fps')
                    : (l10n?.highQuality(
                            settings.modelInputSize,
                            settings.analysisFpsLabel,
                          ) ??
                          '高质量 · ${settings.modelInputSize} 输入 / ${settings.analysisFpsLabel}fps'),
                onTap: () => _showQualitySheet(context, state),
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: LucideIcons.clock3,
                title: l10n?.clipDuration ?? '片段时长',
                value:
                    '${settings.clip.beforeSeconds} ${context.bheText('秒')} ${context.bheText('前')} + ${settings.clip.afterSeconds} ${context.bheText('秒')} ${context.bheText('后')}',
                onTap: () => _showClipSheet(context, state),
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: LucideIcons.crosshair,
                title: l10n?.roiZones ?? '投篮分析区与篮网区',
                value: state.project.hoopRoi == null
                    ? (l10n?.notSet ?? '尚未设置')
                    : (l10n?.roiConfigured ?? '已设置，篮筐标定独立保存'),
                onTap: () => _showRoiEditor(context, state),
                accent: state.project.hoopRoi == null
                    ? BhePalette.warning
                    : BhePalette.green,
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: LucideIcons.scan,
                title: l10n?.analysisRange ?? '分析范围',
                value:
                    '${_formatMs(settings.startMs)} — ${_formatMs(settings.endMs ?? video.durationMs)}',
                onTap: () => _showRangeSheet(context, state),
              ),
            ],
          ),
        ),
        if (state.project.lastAnalysisStatus == 'completed' &&
            state.project.candidates.isEmpty) ...[
          const SizedBox(height: 12),
          _InlineNotice(
            message: l10n?.noCandidatesAdvice ?? '没有找到候选片段。建议检查检测区域或分析范围后重新分析。',
          ),
        ],
        if (state.project.lastAnalysisStatus == 'interrupted') ...[
          const SizedBox(height: 12),
          _InlineNotice(
            message: l10n?.analysisInterrupted ?? '上次分析未完成，可以重新开始。',
          ),
        ],
        if (state.hasUncertainAnalysis) _UncertainAnalysisNotice(state: state),
        if (!state.hasUncertainAnalysis &&
            state.analysisStartBlockReason != null)
          _InlineNotice(message: state.analysisStartBlockReason!),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('start-analysis'),
                onPressed: state.canStartAnalysis
                    ? () => unawaited(_confirmAndStartAnalysis(context, state))
                    : null,
                icon: const Icon(LucideIcons.play, size: 18),
                label: Text(
                  state.project.candidates.isEmpty
                      ? (l10n?.startAnalysis ?? '开始分析')
                      : (l10n?.redoAnalysis ?? '重新分析'),
                ),
              ),
            ),
            if (state.project.candidates.isNotEmpty) ...[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: onOpenReview,
                icon: const Icon(LucideIcons.listChecks, size: 18),
                label: Text(
                  l10n?.reviewCount(state.project.candidates.length) ??
                      '审核 ${state.project.candidates.length}',
                ),
              ),
            ],
          ],
        ),
        if (state.project.lastAnalysisDurationMs != null) ...[
          const SizedBox(height: 10),
          Text(
            l10n?.lastAnalysisDuration(
                  _formatMs(state.project.lastAnalysisDurationMs!),
                ) ??
                '上次分析耗时 ${_formatMs(state.project.lastAnalysisDurationMs!)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

Future<void> _confirmAndStartAnalysis(
  BuildContext context,
  MobileAppState state,
) async {
  final projectId = state.project.id;
  final session = state.projectSession;
  final videoGeneration = state.videoPreparationGeneration;
  if (!state.groupsLoaded) await state.groupsReady;
  if (!context.mounted || state.project.id != projectId || state.projectSession != session ||
      state.videoPreparationGeneration != videoGeneration) {
    return;
  }
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    isDismissible: false,
    builder: (_) => _RosterConfirmation(state: state),
  );
  if (confirmed != true || !context.mounted || state.project.id != projectId ||
      state.projectSession != session || state.videoPreparationGeneration != videoGeneration) {
    return;
  }
  final selection = state.rosterSelection;
  if (selection.groupChanged) return;
  await state.startAnalysis(
    rosterPlayers: selection.orderedPlayers,
    expectedRosterGroup: selection.groupName,
    expectedProjectId: projectId,
    expectedSession: session,
    expectedVideoGeneration: videoGeneration,
  );
}

class _RangeEditorSlider extends StatelessWidget {
  const _RangeEditorSlider({
    required this.start,
    required this.end,
    required this.position,
    required this.max,
    required this.onChanged,
  });
  final double start;
  final double end;
  final double position;
  final double max;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) {
    final boundedPosition = position.clamp(0.0, max).toDouble();
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 5),
          child: RangeSlider(
            min: 0,
            max: max,
            values: RangeValues(start, end),
            onChanged: onChanged,
          ),
        ),
        Row(
          children: [
            Text(
              '${context.bheText('播放位置')} ${_formatMs(boundedPosition.round())}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            Text(
              '${context.bheText('范围')} ${_formatMs(start.round())} — ${_formatMs(end.round())}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

int _movedRangeHandle({
  required RangeValues values,
  required double previousStart,
  required double previousEnd,
}) => (values.start - previousStart).abs() >= (values.end - previousEnd).abs()
    ? values.start.round()
    : values.end.round();

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.accent,
  });
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Icon(icon, size: 18, color: accent ?? BhePalette.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(
            LucideIcons.chevronRight,
            size: 16,
            color: BhePalette.textTertiary,
          ),
        ],
      ),
    ),
  );
}

class _RecentProjectRow extends StatelessWidget {
  const _RecentProjectRow({
    required this.project,
    required this.onTap,
    this.coverPath,
  });
  final ProjectSnapshot project;
  final String? coverPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 7),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: coverPath == null ? 14 : 10,
          vertical: coverPath == null ? 12 : 8,
        ),
        child: Row(
          children: [
            if (coverPath == null)
              const Icon(
                LucideIcons.fileVideo,
                size: 18,
                color: BhePalette.textSecondary,
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(coverPath!),
                  key: Key('project-cover-${project.id}'),
                  width: 72,
                  height: 48,
                  fit: BoxFit.cover,
                  cacheWidth: 216,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 72,
                    height: 48,
                    child: Icon(
                      LucideIcons.fileVideo,
                      size: 18,
                      color: BhePalette.textSecondary,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: _ProjectNameText(project.name),
            ),
            Text(
              context.bheText('候选 ${project.candidates.length}'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(width: 8),
            const Icon(
              LucideIcons.chevronRight,
              size: 16,
              color: BhePalette.textTertiary,
            ),
          ],
        ),
      ),
    ),
  );
}

class _AnalysisView extends StatefulWidget {
  const _AnalysisView({required this.state});
  final MobileAppState state;

  @override
  State<_AnalysisView> createState() => _AnalysisViewState();
}

class _AnalysisViewState extends State<_AnalysisView> {
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final percent = (state.progress * 100).round();
    final steps = <(AnalysisStage, String)>[
      (AnalysisStage.validateInput, l10n?.checkingVideo ?? '检查视频'),
      (AnalysisStage.prepareProxy, l10n?.prepareLocalAnalysis ?? '准备本地模型'),
      (AnalysisStage.coarseScan, context.bheText('扫描视频')),
      (AnalysisStage.generateCandidates, context.bheText('生成候选')),
      (AnalysisStage.refineCandidates, context.bheText('精筛候选')),
      (AnalysisStage.rimCheck, context.bheText('篮筐复核')),
      (AnalysisStage.persistCandidates, context.bheText('保存结果')),
    ];
    final current = steps.indexWhere((item) => item.$1 == state.stage);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _PageIntro(
                        eyebrow: 'LOCAL ANALYSIS',
                        title: l10n?.analysisInProgress ?? '正在分析视频',
                        subtitle:
                            l10n?.analysisLocalSaved ?? '分析在本机运行，完成后会自动保存结果。',
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(state.cancelAnalysis()),
                      child: Text(l10n?.cancel ?? '取消'),
                    ),
                  ],
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '$percent%',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const Spacer(),
                            Text(
                              l10n?.elapsed(
                                    _formatMs(
                                      state.analysisElapsed.inMilliseconds,
                                    ),
                                  ) ??
                                  '已用 ${_formatMs(state.analysisElapsed.inMilliseconds)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: state.progress.clamp(0, 1),
                          minHeight: 6,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                state.progressMessage.isEmpty
                                    ? (l10n?.prepareLocalAnalysis ?? '准备本地分析')
                                    : l10n?.text(state.progressMessage) ??
                                          state.progressMessage,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            if (state.eta != null)
                              Text(
                                l10n?.remaining(
                                      _formatMs(state.eta!.inMilliseconds),
                                    ) ??
                                    '还需 ${_formatMs(state.eta!.inMilliseconds)}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                        if (state.processedFrames != null &&
                            state.totalFrames != null) ...[
                          const SizedBox(height: 7),
                          Text(
                            l10n?.processedFrames(
                                  state.processedFrames!,
                                  state.totalFrames!,
                                ) ??
                                '${state.processedFrames} / ${state.totalFrames} 帧',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Column(
                    children: [
                      for (var index = 0; index < steps.length; index++)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            index < current
                                ? LucideIcons.circleCheck
                                : index == current
                                ? LucideIcons.loaderCircle
                                : LucideIcons.circle,
                            size: 18,
                            color: index <= current
                                ? BhePalette.orange
                                : BhePalette.textTertiary,
                          ),
                          title: Text(
                            steps[index].$2,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                    ],
                  ),
                ),
                if (state.exportStartBlockReason case final message?)
                  _InlineNotice(message: message),
                VideoSourceNotice(state: state),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewView extends StatefulWidget {
  const _ReviewView({
    super.key,
    required this.state,
    required this.onOpenProject,
    required this.onOpenExport,
    required this.onExportGoals,
  });
  final MobileAppState state;
  final VoidCallback onOpenProject;
  final VoidCallback onOpenExport;
  final VoidCallback onExportGoals;

  @override
  State<_ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<_ReviewView> {
  VideoPlayerController? controller;
  final _railController = ScrollController();
  final _candidateKeys = <GlobalKey>[];
  Future<void> _playerQueue = Future<void>.value();
  bool _disposed = false;
  int selectedIndex = 0;
  String? _selectedId;
  bool annotations = false;
  bool autoReplay = true;
  bool clipOnly = true;
  double speed = 1;
  bool _stoppingAtCandidateEnd = false;
  bool _seeking = false;
  bool _completionPromptShown = false;
  Timer? _completionTimer;
  int _completionGeneration = 0;
  bool _fullscreen = false;
  int _undoRevision = 0;
  int _reviewNoticeRevision = 0;
  int _playerMutationRevision = 0;
  DateTime _lastVideoPaint = DateTime.fromMillisecondsSinceEpoch(0);
  String statusFilter = 'uncertain';
  String rimFilter = 'all';
  String playerFilter = 'all';
  bool foldedExpanded = false;

  MobileAppState get state => widget.state;
  Set<String> get foldedIds => state.likelyMissCandidateIds;
  List<Candidate> get allCandidates =>
      [...state.project.candidates]
        ..sort((a, b) => a.eventMs.compareTo(b.eventMs));
  List<Candidate> get candidates => candidatesInTier
      .where(
        (candidate) => _matchesReviewFilters(
          candidate,
          rim: rimFilter,
          player: playerFilter,
        ),
      )
      .toList();
  List<Candidate> get candidatesInTier {
    final items = allCandidates;
    if (statusFilter != 'uncertain') {
      return items
          .where(
            (candidate) => switch (statusFilter) {
              'included' => mobileTier(candidate) == MobileTier.goal,
              'excluded' => mobileTier(candidate) == MobileTier.excluded,
              _ => true,
            },
          )
          .toList();
    }
    final showingFolded =
        foldedExpanded &&
        items.any((candidate) => isFoldedCandidate(candidate, foldedIds));
    return items
        .where(
          (candidate) =>
              mobileTier(candidate) == MobileTier.uncertain &&
              isFoldedCandidate(candidate, foldedIds) == showingFolded,
        )
        .toList();
  }

  bool get filtering => rimFilter != 'all' || playerFilter != 'all';

  Future<void> _changeFilters({
    String? status,
    String? rim,
    String? player,
    bool? folded,
  }) async {
    final anchorMs = controller?.value.isPlaying == true
        ? controller!.value.position.inMilliseconds
        : selected?.startMs ?? 0;
    _cancelCompletionPrompt();
    setState(() {
      if (status != null) statusFilter = status;
      if (folded != null || status != null) foldedExpanded = folded ?? false;
      rimFilter = rim ?? rimFilter;
      playerFilter = player ?? playerFilter;
      final items = candidates;
      final nearest = nearestReviewCandidate(
        items,
        anchorMs: anchorMs,
        startMs: (candidate) => candidate.startMs,
      );
      selectedIndex = nearest == null ? 0 : items.indexOf(nearest);
      _selectedId = nearest?.id;
      _completionPromptShown = false;
    });
    final candidate = selected;
    if (candidate != null) {
      unawaited(_scrollToSelected());
      await _replay(candidate);
    } else {
      await _pausePlayback();
    }
  }

  Candidate? get selected {
    final items = candidates;
    if (items.isEmpty) return null;
    final index = items.indexWhere((candidate) => candidate.id == _selectedId);
    return items[index >= 0 ? index : selectedIndex.clamp(0, items.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]),
    );
    _undoRevision = state.undoRevision;
    _reviewNoticeRevision = state.reviewRevision;
    _playerMutationRevision = state.playerMutationRevision;
    state.addListener(_onUndo);
    _openVideo();
  }

  void _onUndo() {
    if (!mounted) return;
    if (_reviewNoticeRevision != state.reviewRevision) {
      _reviewNoticeRevision = state.reviewRevision;
      if (state.reviewNotice == '保存失败，请重试') {
        final failure = state.reviewDiagnosticError;
        final session = state.projectSession;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && state.projectSession == session) {
            _showReviewSaveFailure(context, failure);
          }
        });
      }
    }
    if (_playerMutationRevision != state.playerMutationRevision) {
      _playerMutationRevision = state.playerMutationRevision;
      if (playerFilter == 'player:${state.lastPlayerOldName}') {
        setState(() => playerFilter = state.lastPlayerNewName == null ? 'all' : 'player:${state.lastPlayerNewName}');
      }
    }
    final visibleIndex = candidates.indexWhere((item) => item.id == _selectedId);
    if (visibleIndex >= 0 && visibleIndex != selectedIndex) {
      setState(() => selectedIndex = visibleIndex);
    }
    if (_undoRevision == state.undoRevision) return;
    _undoRevision = state.undoRevision;
    final id = state.undoFocusId;
    if (state.undoFoldedView case final expanded?) {
      setState(() {
        statusFilter = 'uncertain';
        foldedExpanded = expanded;
        rimFilter = 'all';
        playerFilter = 'all';
      });
    }
    if (state.undoFoldedView == null && !candidates.any((item) => item.id == id)) {
      setState(() { statusFilter = 'all'; foldedExpanded = false; rimFilter = 'all'; playerFilter = 'all'; });
    }
    _cancelCompletionPrompt();
    final index = candidates.indexWhere((item) => item.id == id);
    if (index >= 0) unawaited(_select(index));
  }

  String? _openedVideoPath;
  int _openedSourceRevision = -1;
  int _videoOpenGeneration = 0;
  @override
  void didUpdateWidget(covariant _ReviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_openedVideoPath != state.project.video?.path || _openedSourceRevision != state.videoSourceRevision) {
      unawaited(_openVideo());
    }
  }

  Future<void> _openVideo() => _loadReviewVideo(this);
  void _installSourcePlayer(VideoPlayerController? next) => setState(() {
    controller = next;
  });

  void _videoChanged() {
    if (!mounted) return;
    final candidate = selected;
    final value = controller?.value;
    if (candidate != null &&
        clipOnly &&
        value != null &&
        value.isPlaying &&
        value.position.inMilliseconds >= candidate.endMs &&
        !_stoppingAtCandidateEnd &&
        !_seeking) {
      _stoppingAtCandidateEnd = true;
      unawaited(
        _enqueuePlayer((player) async {
          if (autoReplay) {
            await player.seekTo(Duration(milliseconds: candidate.startMs));
            await player.setPlaybackSpeed(speed);
            await player.play();
            _stoppingAtCandidateEnd = false;
            return;
          }
          if (player.value.isPlaying) await player.pause();
        }),
      );
    }
    final now = DateTime.now();
    if (now.difference(_lastVideoPaint) < const Duration(milliseconds: 80)) {
      return;
    }
    _lastVideoPaint = now;
    setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelCompletionPrompt();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]),
    );
    final player = controller;
    controller = null;
    player?.removeListener(_videoChanged);
    final queue = _playerQueue;
    _playerQueue = Future<void>.value();
    unawaited(() async {
      await queue;
      await player?.dispose();
    }());
    state.removeListener(_onUndo);
    _railController.dispose();
    super.dispose();
  }

  Future<void> _select(int index) async {
    if (index < 0 || index >= candidates.length) return;
    _stoppingAtCandidateEnd = false;
    final candidate = candidates[index];
    setState(() { selectedIndex = index; _selectedId = candidate.id; });
    unawaited(_scrollToSelected());
    await _replay(candidate);
  }

  Future<void> _replay(Candidate candidate) async {
    _stoppingAtCandidateEnd = false;
    await _enqueuePlayer((player) async {
      await player.setLooping(false);
      await player.setPlaybackSpeed(speed);
      await player.seekTo(Duration(milliseconds: candidate.startMs));
      await player.play();
    });
    if (mounted) setState(() {});
  }

  Future<void> _seek(int milliseconds) async {
    await _enqueuePlayer((player) async {
      final value = player.value;
      final candidate = selected;
      final lower = clipOnly && candidate != null
          ? Duration(milliseconds: candidate.startMs)
          : Duration.zero;
      final upper = clipOnly && candidate != null
          ? Duration(
              milliseconds: math.max(candidate.startMs, candidate.endMs - 1),
            )
          : value.duration;
      final next = value.position + Duration(milliseconds: milliseconds);
      final bounded = next < lower
          ? lower
          : next > upper
          ? upper
          : next;
      _seeking = true;
      try {
        await player.seekTo(bounded);
      } finally {
        _seeking = false;
      }
    });
  }

  Future<void> _seekTo(int milliseconds) async {
    final candidate = selected;
    final lower = clipOnly && candidate != null ? candidate.startMs : 0;
    final upper = clipOnly && candidate != null
        ? math.max(candidate.startMs, candidate.endMs - 1)
        : (controller?.value.duration.inMilliseconds ?? milliseconds);
    final bounded = milliseconds.clamp(lower, upper).toInt();
    await _enqueuePlayer((player) async {
      _seeking = true;
      try {
        await player.seekTo(Duration(milliseconds: bounded));
      } finally {
        _seeking = false;
      }
    });
  }

  Future<void> _toggleSource() async {
    final next = !clipOnly;
    setState(() {
      clipOnly = next;
      _stoppingAtCandidateEnd = false;
    });
    if (next && selected != null) await _replay(selected!);
  }

  Future<void> _openFullscreen() async {
    final player = controller;
    if (player == null || !player.value.isInitialized || !mounted) return;
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    setState(() => _fullscreen = true);
    bool? exportGoals;
    try {
      exportGoals = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (pageContext) =>
              _FullscreenReviewPage(controller: player, review: this),
        ),
      );
    } finally {
      if (mounted) setState(() => _fullscreen = false);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (exportGoals == true && mounted) widget.onExportGoals();
  }

  Future<void> _togglePlay() async {
    await _enqueuePlayer((player) async {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        await player.setPlaybackSpeed(speed);
        await player.play();
      }
    });
    if (mounted) setState(() {});
  }

  Future<void> _pausePlayback() async {
    await _enqueuePlayer((player) async {
      if (player.value.isPlaying) await player.pause();
    });
  }

  Future<void> _resumePlayback() async {
    await _enqueuePlayer((player) async {
      if (player.value.isPlaying) return;
      await player.setPlaybackSpeed(speed);
      await player.play();
    });
  }

  Future<void> _enqueuePlayer(
    Future<void> Function(VideoPlayerController player) action,
  ) {
    final task = _playerQueue.then((_) async {
      if (_disposed) return;
      final player = controller;
      if (player == null || !player.value.isInitialized) return;
      final projectId = state.project.id;
      try {
        await action(player);
      } catch (error, stack) {
        final record = MobileDiagnostics.instance.error(
          error, stack, operation: 'playback',
        );
        if (mounted && !_disposed && controller == player && state.project.id == projectId) {
          state.markVideoFailure(
            VideoSourceFailure.unplayable, diagnostic: record,
          );
        }
      }
    });
    _playerQueue = task.then<void>((_) {}, onError: (_, _) {});
    return task;
  }

  Future<void> _scrollToSelected() async {
    if (!mounted) return;
    final index = selectedIndex;
    final items = candidates;
    if (index < 0 || index >= items.length) {
      return;
    }
    final id = items[index].id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = candidates;
      if (selectedIndex != index ||
          index < 0 ||
          index >= current.length ||
          index >= _candidateKeys.length ||
          current[index].id != id ||
          selected?.id != id) {
        return;
      }
      final target = _candidateKeys[index].currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target,
          alignment: .45,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _showBatchRangeSheet(BuildContext context) async {
    if (candidates.isEmpty) return;
    final scoped = filtering || statusFilter != 'all';
    final scopeIds = scoped
        ? candidates.map((candidate) => candidate.id).toList()
        : null;
    final current = state.project.settings.clip;
    var before = math.min(current.beforeSeconds, 10).toDouble();
    var after = math.min(current.afterSeconds, 10).toDouble();
    var overwriteManual = false;
    final manualCount = candidates
        .where((candidate) => candidate.rangeEdited)
        .length;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => _SheetFrame(
          title: context.bheText('批量设置片段时长'),
          child: Column(
            children: [
              Text(
                context.bheText(
                  scoped
                      ? '当前筛选的 ${candidates.length} 个候选片段'
                      : '全部 ${candidates.length} 个候选片段',
                ),
              ),
              const SizedBox(height: 8),
              _BatchSecondsSlider(
                label: context.bheText('进球前'),
                value: before,
                onChanged: (value) => setSheetState(() => before = value),
              ),
              _BatchSecondsSlider(
                label: context.bheText('进球后'),
                value: after,
                onChanged: (value) => setSheetState(() => after = value),
              ),
              Text(
                context.bheText(
                  overwriteManual
                      ? scoped
                            ? '将覆盖筛选出的 ${candidates.length} 个片段，其中 $manualCount 个曾手动调整。'
                            : '将覆盖全部 ${candidates.length} 个片段，其中 $manualCount 个曾手动调整。'
                      : '将更新 ${candidates.length - manualCount} 个片段，保留 $manualCount 个手动调整片段。',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: overwriteManual,
                onChanged: (value) =>
                    setSheetState(() => overwriteManual = value ?? false),
                title: Text(context.bheText('覆盖手动调整过的片段')),
                subtitle: Text(context.bheText('关闭时会保留手动调整的范围')),
              ),
              FilledButton(
                onPressed: before.round() == 0 && after.round() == 0
                    ? null
                    : () => Navigator.pop(context, true),
                child: Text(
                  context.bheText(
                    '应用到 ${overwriteManual ? candidates.length : candidates.length - manualCount} 个片段',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == true && mounted) {
      final updated = await state.applyBatchClipRange(
        beforeSeconds: before.round(),
        afterSeconds: after.round(),
        candidateIds: scopeIds,
        overwriteManual: overwriteManual,
        focusId: selected?.id,
      );
      if (updated > 0) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) return const SizedBox.shrink();
    final candidate = selected;
    if (candidate == null && allCandidates.isEmpty) {
      return _ReviewEmpty(
        onOpenProject: widget.onOpenProject,
        onAddManual: state.project.video == null
            ? null
            : () => unawaited(_addManualCandidate(context)),
      );
    }
    final rail = _buildRail(context);
    if (candidate == null) {
      if (!state.canUndoReview) return rail;
      return Column(
        children: [
          Expanded(child: rail),
          SafeArea(
            top: false,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 12, bottom: 8),
                child: _ReviewUndoButton(
                  onPressed: state.canUndoReview
                      ? () => unawaited(state.undoReview())
                      : null,
                  highlighted: state.reviewBatchNoticeCount > 0,
                ),
              ),
            ),
          ),
        ],
      );
    }
    final video = state.project.video!;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _ReviewSourceBody(
                    rail: rail,
                    hasReviewFooter: state.reviewBatchNoticeCount > 0 ||
                        (statusFilter == 'uncertain' &&
                            allCandidates.any((item) => isFoldedCandidate(item, foldedIds))),
                    video: _ReviewVideoStage(
                      controller: controller,
                      unavailable: state.videoSourceFailure != null,
                      candidate: candidate,
                      rim: state.project.rimRoi,
                      annotations: annotations,
                      clipOnly: clipOnly,
                      aspectRatio: video.width / video.height,
                      onToggle: () => _togglePlay(),
                      onPause: _pausePlayback,
                      onScrubTo: _seekTo,
                      onResume: _resumePlayback,
                      onFullscreen: _openFullscreen,
                      onSwipeVertical: (velocity) => _select(
                        velocity < 0 ? selectedIndex + 1 : selectedIndex - 1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _ReviewActionBar(
            candidate: candidate,
            canUndo: state.canUndoReview,
            highlightUndo: state.reviewBatchNoticeCount > 0,
            onUndo: () => unawaited(state.undoReview()),
            controller: controller,
            annotations: annotations,
            autoReplay: autoReplay,
            clipOnly: clipOnly,
            speed: speed,
            onToggle: _togglePlay,
            onReplay: () => _replay(candidate),
            onSeekBack: () => _seek(-1500),
            onSeekForward: () => _seek(1500),
            onSeekTo: _seekTo,
            onToggleAnnotations: () =>
                setState(() => annotations = !annotations),
            onToggleAutoReplay: () => setState(() => autoReplay = !autoReplay),
            onToggleSource: _toggleSource,
            onSpeed: (value) async {
              setState(() => speed = value);
              await _enqueuePlayer((player) => player.setPlaybackSpeed(value));
            },
            onInclude: () => _review(CandidateSelection.included),
            onExclude: statusFilter == 'excluded'
                ? null
                : () => _review(CandidateSelection.excluded),
            onDetails: () => _showEvidence(context, candidate),
            onEditRange: () => _editRange(context, candidate),
            onPlayer: () => _showPlayerPicker(context, state, candidate),
            onExport: widget.onOpenExport,
            onShortcuts: () => _showShortcuts(context),
          ),
        ],
      ),
    );
  }

  Widget _buildRail(
    BuildContext context, {
    bool landscape = false,
    VoidCallback? refresh,
  }) {
    final items = candidates;
    final selectedId = selected?.id;
    while (_candidateKeys.length < items.length) {
      _candidateKeys.add(GlobalKey());
    }
    if (_candidateKeys.length > items.length) {
      _candidateKeys.removeRange(items.length, _candidateKeys.length);
    }
    final folded = allCandidates
        .where((candidate) => isFoldedCandidate(candidate, foldedIds))
        .toList();
    void change({String? status, String? rim, String? player, bool? expanded}) {
      unawaited(
        _changeFilters(
          status: status,
          rim: rim,
          player: player,
          folded: expanded,
        ),
      );
      refresh?.call();
    }

    final session = state.projectSession;
    final foldedCount = folded.length;
    return _CandidateRail(
      controller: landscape ? null : _railController,
      itemKeys: landscape ? const [] : _candidateKeys,
      candidates: items,
      allCandidates: allCandidates,
      tierCandidates: candidatesInTier,
      players: state.project.players,
      statusFilter: statusFilter,
      rimFilter: rimFilter,
      playerFilter: playerFilter,
      onTier: (status) => change(status: status),
      onFilters: (rim, player) => change(rim: rim, player: player),
      selectedIndex: items.indexWhere((item) => item.id == selectedId),
      onSelect: (index) {
        unawaited(_select(index));
        refresh?.call();
      },
      onAdd: () => _addManualCandidate(context),
      onBatchRange: () => _showBatchRangeSheet(context),
      onExportGoals: landscape
          ? () => Navigator.of(context).pop(true)
          : widget.onExportGoals,
      landscape: landscape,
      foldedCount: foldedCount,
      foldedExpanded: foldedExpanded && foldedCount > 0,
      onToggleFold: () => change(expanded: !foldedExpanded),
      onMarkFolded: () async {
        final choice = await _confirmFoldedMisses(
          context,
          foldedCount,
          landscape: landscape,
        );
        if (!context.mounted ||
            !mounted ||
            state.projectSession != session ||
            choice == null)
          return;
        if (!choice) {
          change(expanded: true);
          return;
        }
        final result = await state.markLikelyMissed(
          folded.map((candidate) => candidate.id).toSet(),
          expanded: foldedExpanded,
          focusId: selected?.id,
        );
        if (context.mounted &&
            mounted &&
            state.projectSession == session &&
            result == ReviewActionResult.changed &&
            foldedExpanded) {
          change(expanded: false);
        }
      },
      batchNoticeCount: state.reviewBatchNoticeCount,
    );
  }

  Future<void> _showShortcuts(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (context) {
        final l10n = Localizations.of<BheLocalizations>(
          context,
          BheLocalizations,
        );
        return _SheetFrame(
          title: l10n?.shortcuts ?? '操作提示',
          child: Column(
            children: [
              _ShortcutRow(
                icon: LucideIcons.arrowUp,
                title: l10n?.text('上滑 / 下滑') ?? '上滑 / 下滑',
                detail: l10n?.text('切换上一个 / 下一个候选片段') ?? '切换上一个 / 下一个候选片段',
              ),
              _ShortcutRow(
                icon: LucideIcons.moveHorizontal,
                title: l10n?.text('左右拖动视频') ?? '左右拖动视频',
                detail: l10n?.text('拖动预览位置，松手后跳转到对应时间') ?? '拖动预览位置，松手后跳转到对应时间',
              ),
              _ShortcutRow(
                icon: LucideIcons.play,
                title: l10n?.text('点击视频') ?? '点击视频',
                detail: l10n?.text('播放或暂停当前片段') ?? '播放或暂停当前片段',
              ),
              _ShortcutRow(
                icon: LucideIcons.check,
                title: l10n?.text('选中 / 不选') ?? '选中 / 不选',
                detail: l10n?.text('完成当前候选后自动进入下一个') ?? '完成当前候选后自动进入下一个',
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addManualCandidate(BuildContext context) async {
    final video = state.project.video;
    if (video == null) return;
    final player = controller;
    final currentPosition = player?.value.isInitialized == true
        ? player!.value.position.inMilliseconds
        : 0;
    final clip = state.project.settings.clip;
    var start = (currentPosition - clip.beforeSeconds * 1000)
        .clamp(0, video.durationMs)
        .toDouble();
    var end = (currentPosition + clip.afterSeconds * 1000)
        .clamp(0, video.durationMs)
        .toDouble();
    if (end - start < 1000) {
      end = (start + 1000).clamp(0, video.durationMs).toDouble();
      start = (end - 1000).clamp(0, video.durationMs).toDouble();
    }
    await _pausePlayback();
    if (!context.mounted) return;
    final range = await showClipRangeEditor(
      context,
      videoPath: video.path,
      onFeedback: (error) {
        if (context.mounted) {
          unawaited(showMobileDiagnostics(context, error: error));
        }
      },
      aspectRatio: video.width / video.height,
      durationMs: video.durationMs,
      startMs: start.round(),
      endMs: end.round(),
      title: context.bheText('补漏候选'),
      description: '用视频控制确认时间，再拖动两端确定要审核的片段。',
      confirmLabel: context.bheText('加入审核列表'),
      confirmIcon: LucideIcons.plus,
    );
    if (range == null) return;
    final id = 'manual_${DateTime.now().microsecondsSinceEpoch}';
    final added = await state.addCandidate(
      Candidate(
        id: id,
        startMs: range.start,
        endMs: range.end,
        eventMs: ((range.start + range.end) / 2).round(),
        reason: 'manual',
        verdict: 'manual',
        evidenceSource: 'manual',
        reviewed: true,
      ),
    );
    if (!added || !mounted) return;
    setState(() {
      statusFilter = 'included';
      foldedExpanded = false;
      rimFilter = 'all';
      playerFilter = 'all';
    });
    final index = candidates.indexWhere((candidate) => candidate.id == id);
    if (index >= 0) await _select(index);
  }

  void _review(CandidateSelection selection) {
    final candidate = selected;
    if (candidate != null) _reviewAt(candidate.id, selection);
  }

  void _cancelCompletionPrompt() {
    _completionGeneration++;
    _completionTimer?.cancel();
    _completionTimer = null;
    _completionPromptShown = false;
  }

  void _reviewAt(String id, CandidateSelection selection) {
    if (state.projectTransitioning) {
      showBheToast(context, context.bheText('正在切换项目，请稍候'));
      return;
    }
    final items = candidates;
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _cancelCompletionPrompt();
    final generation = _completionGeneration;
    final projectId = state.project.id;
    // Choose the next stable ID before the queued edit can change visibility.
    final nextId = index + 1 < items.length ? items[index + 1].id : null;
    final saved = state.toggleCandidate(id, selection);
    unawaited(
      saved.then((result) {
        if (!mounted ||
            generation != _completionGeneration ||
            projectId != state.project.id)
          return;
        if (result == ReviewActionResult.rejected) {
          final current = selected;
          if (nextId == null || current?.id == nextId) {
            final restored = candidates.indexWhere((item) => item.id == id);
            if (restored >= 0) unawaited(_select(restored));
          }
          if (state.reviewNotice != '保存失败，请重试') {
            showBheToast(context, context.bheText('本次审核未保存'));
          }
          return;
        }
        if (nextId != null) return;
        if (statusFilter != 'all') {
          final next = selected;
          if (next != null) {
            unawaited(
              _select(candidates.indexWhere((item) => item.id == next.id)),
            );
          } else {
            unawaited(_pausePlayback());
          }
          return;
        }
        final revision = state.reviewRevision;
        _completionTimer = Timer(const Duration(seconds: 5), () {
          if (mounted &&
              generation == _completionGeneration &&
              revision == state.reviewRevision &&
              !_completionPromptShown) {
            _completionPromptShown = true;
            unawaited(_showReviewCompletePrompt(context));
          }
        });
      }),
    );
    if (nextId != null) unawaited(_select(index + 1));
  }

  Future<void> _showReviewCompletePrompt(BuildContext context) async {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final export = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n?.reviewComplete ?? '审核完成'),
        content: Text(
          l10n?.reviewCompleteDescription(candidates.length) ??
              '已处理 ${candidates.length} 个候选片段，可以进入导出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n?.laterExport ?? '稍后导出'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(LucideIcons.download, size: 17),
            label: Text(l10n?.goExport ?? '去导出'),
          ),
        ],
      ),
    );
    if (export == true && mounted) widget.onOpenExport();
  }

  Future<void> _editRange(BuildContext context, Candidate candidate) async {
    final video = state.project.video;
    if (video == null) return;
    await _pausePlayback();
    if (!context.mounted) return;
    final result = await showClipRangeEditor(
      context,
      videoPath: video.path,
      onFeedback: (error) {
        if (context.mounted) {
          unawaited(showMobileDiagnostics(context, error: error));
        }
      },
      aspectRatio: video.width / video.height,
      durationMs: video.durationMs,
      startMs: candidate.startMs,
      endMs: candidate.endMs,
      eventMs: candidate.eventMs,
      defaultStartMs: candidate.defaultStartMs,
      defaultEndMs: candidate.defaultEndMs,
      title: context.bheText('调整片段范围'),
      confirmLabel: context.bheText('应用'),
    );
    if (result != null) {
      await state.updateCandidate(
        candidate.copyWith(startMs: result.start, endMs: result.end),
      );
    }
  }

  Future<void> _showEvidence(BuildContext context, Candidate candidate) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _EvidenceSheet(candidate: candidate, state: state),
    );
  }
}

class _ReviewVideoStage extends StatefulWidget {
  const _ReviewVideoStage({
    required this.controller,
    this.unavailable = false,
    required this.candidate,
    required this.rim,
    required this.annotations,
    required this.clipOnly,
    required this.aspectRatio,
    required this.onToggle,
    required this.onPause,
    required this.onScrubTo,
    required this.onResume,
    required this.onFullscreen,
    required this.onSwipeVertical,
  });
  final VideoPlayerController? controller;
  final bool unavailable;
  final Candidate candidate;
  final Roi? rim;
  final bool annotations;
  final bool clipOnly;
  final double aspectRatio;
  final VoidCallback onToggle;
  final Future<void> Function() onPause;
  final Future<void> Function(int) onScrubTo;
  final Future<void> Function() onResume;
  final VoidCallback onFullscreen;
  final ValueChanged<double> onSwipeVertical;

  @override
  State<_ReviewVideoStage> createState() => _ReviewVideoStageState();
}

class _ReviewVideoStageState extends State<_ReviewVideoStage> {
  Timer? _feedbackTimer;
  bool _showFeedback = true;
  bool _scrubbing = false;
  double _dragStartX = 0;
  int _dragStartPosition = 0;
  int _scrubPosition = 0;
  bool _resumeAfterScrub = false;

  @override
  void initState() {
    super.initState();
    _scheduleFeedbackHide();
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _scheduleFeedbackHide() {
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showFeedback = false);
    });
  }

  void _toggle() {
    setState(() => _showFeedback = true);
    _scheduleFeedbackHide();
    widget.onToggle();
  }

  void _startScrub(DragStartDetails details) {
    final player = widget.controller;
    _feedbackTimer?.cancel();
    setState(() {
      _scrubbing = true;
      _dragStartX = details.globalPosition.dx;
      _dragStartPosition =
          player?.value.position.inMilliseconds ?? widget.candidate.startMs;
      _scrubPosition = _dragStartPosition;
      _resumeAfterScrub = player?.value.isPlaying == true;
    });
    if (_resumeAfterScrub) unawaited(widget.onPause());
  }

  void _updateScrub(DragUpdateDetails details, double width) {
    if (!_scrubbing || width <= 0) return;
    final fullDuration =
        widget.controller?.value.duration.inMilliseconds ?? 6000;
    final travel = math.max(
      widget.clipOnly ? widget.candidate.duration.inMilliseconds : fullDuration,
      6000,
    );
    final delta = ((details.globalPosition.dx - _dragStartX) / width * travel)
        .round();
    final playerDuration =
        widget.controller?.value.duration.inMilliseconds ??
        widget.candidate.endMs;
    final start = widget.clipOnly ? widget.candidate.startMs : 0;
    final end = widget.clipOnly ? widget.candidate.endMs : playerDuration;
    final next = (_dragStartPosition + delta).clamp(start, end);
    if (next == _scrubPosition) return;
    setState(() => _scrubPosition = next);
  }

  void _endScrub() {
    if (!_scrubbing) return;
    final position = _scrubPosition;
    final resume = _resumeAfterScrub;
    setState(() => _scrubbing = false);
    unawaited(() async {
      await widget.onScrubTo(position);
      if (resume) await widget.onResume();
    }());
    _scheduleFeedbackHide();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.controller;
    final unavailable = widget.unavailable || player?.value.hasError == true;
    final ratio = widget.aspectRatio.isFinite && widget.aspectRatio > 0
        ? widget.aspectRatio
        : 16 / 9;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: unavailable ? null : _toggle,
          onHorizontalDragStart: _startScrub,
          onHorizontalDragUpdate: (details) =>
              _updateScrub(details, MediaQuery.sizeOf(context).width),
          onHorizontalDragEnd: (_) => _endScrub(),
          onHorizontalDragCancel: _endScrub,
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity.abs() > 120) widget.onSwipeVertical(velocity);
          },
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!unavailable && player?.value.isInitialized == true)
                  Center(
                    child: AspectRatio(
                      aspectRatio: ratio,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VideoPlayer(player!),
                          if (widget.annotations &&
                              (widget.candidate.trajectory.isNotEmpty ||
                                  widget.rim != null ||
                                  widget.candidate.crossingPoint != null))
                            CustomPaint(
                              painter: _CandidateOverlayPainter(
                                candidate: widget.candidate,
                                rim: widget.rim,
                                positionMs:
                                    player.value.position.inMilliseconds,
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                else if (unavailable)
                  const VideoUnavailablePlaceholder()
                else
                  const Center(child: CircularProgressIndicator()),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PlaybackTimeBadge(
                        positionMs:
                            player?.value.position.inMilliseconds ??
                            widget.candidate.startMs,
                      ),
                      const SizedBox(width: 6),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .62),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: IconButton(
                          onPressed: unavailable ? null : widget.onFullscreen,
                          icon: const Icon(
                            LucideIcons.maximize,
                            color: Colors.white,
                            size: 18,
                          ),
                          tooltip: context.bheText('横屏全屏'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 10,
                  bottom: 22,
                  child: _CompactEvidence(candidate: widget.candidate),
                ),
                if (_scrubbing)
                  Positioned(
                    left: _scrubPosition < _dragStartPosition ? 28 : null,
                    right: _scrubPosition >= _dragStartPosition ? 28 : null,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _scrubPosition >= _dragStartPosition
                                ? LucideIcons.fastForward
                                : LucideIcons.rewind,
                            color: Colors.white,
                            size: 30,
                            shadows: const [Shadow(blurRadius: 6)],
                          ),
                          const SizedBox(width: 7),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _formatMs(_scrubPosition),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  shadows: [Shadow(blurRadius: 6)],
                                ),
                              ),
                              Text(
                                context.bheText(
                                  _resumeAfterScrub ? '松手后继续播放' : '松手后定位并暂停',
                                ),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                  shadows: [Shadow(blurRadius: 6)],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: player?.value.isPlaying == true && !_showFeedback
                          ? 0
                          : .92,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        player?.value.isPlaying == true
                            ? LucideIcons.pause
                            : LucideIcons.play,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

double videoAspectRatio(VideoInfo? video) {
  if (video == null || video.height <= 0) return 16 / 9;
  return video.width / video.height;
}

class _FullscreenReviewPage extends StatefulWidget {
  const _FullscreenReviewPage({required this.controller, required this.review});

  final VideoPlayerController controller;
  final _ReviewViewState review;

  @override
  State<_FullscreenReviewPage> createState() => _FullscreenReviewPageState();
}

class _FullscreenReviewPageState extends State<_FullscreenReviewPage> {
  bool _railVisible = true;
  _ReviewViewState get review => widget.review;
  Candidate? get _candidate => review.selected;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    review.state.addListener(_refresh);
  }

  @override
  void dispose() {
    review.state.removeListener(_refresh);
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _reviewCandidate(CandidateSelection selection) {
    review._review(selection);
    _refresh();
  }

  Future<void> _editPlayerTags(Candidate candidate) async {
    final session = review.state.projectSession;
    final wasPlaying = widget.controller.value.isPlaying;
    if (wasPlaying) await review._pausePlayback();
    if (!mounted || review.state.projectSession != session) return;
    try {
      await _showPlayerPicker(context, review.state, candidate);
    } finally {
      if (wasPlaying &&
          mounted &&
          review.state.projectSession == session &&
          _candidate?.id == candidate.id) {
        await review._resumePlayback();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const railWidth = 220.0;
    final candidate = _candidate;
    final value = widget.controller.value;
    final lower = review.clipOnly ? candidate?.startMs ?? 0 : 0;
    final upper = review.clipOnly && candidate != null
        ? candidate.endMs
        : value.duration.inMilliseconds;
    final maxValue = math.max(lower + 1, upper);
    final position = value.position.inMilliseconds
        .clamp(lower, maxValue)
        .toDouble();

    return Scaffold(
      backgroundColor: const Color(0xFF090A0C),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: _buildVideoPanel(
                            context,
                            position: position.round(),
                            lower: lower,
                            upper: upper,
                            maxValue: maxValue,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_railVisible) ...[
                    const SizedBox(width: 1),
                    SizedBox(
                      width: railWidth,
                      child: review._buildRail(
                        context,
                        landscape: true,
                        refresh: _refresh,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _buildBottomBar(
              context,
              position: position.round(),
              lower: lower,
              upper: upper,
              maxValue: maxValue,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPanel(
    BuildContext context, {
    required int position,
    required int lower,
    required int upper,
    required int maxValue,
  }) {
    final candidate = _candidate;
    final playerReady = widget.controller.value.isInitialized;
    final playing = widget.controller.value.isPlaying;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: review._togglePlay,
            child: Center(
              child: playerReady
                  ? AspectRatio(
                      aspectRatio: videoAspectRatio(review.state.project.video),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VideoPlayer(widget.controller),
                          if (review.annotations &&
                              candidate != null &&
                              (candidate.trajectory.isNotEmpty ||
                                  review.state.project.rimRoi != null ||
                                  candidate.crossingPoint != null))
                            CustomPaint(
                              painter: _CandidateOverlayPainter(
                                candidate: candidate,
                                rim: review.state.project.rimRoi,
                                positionMs: position,
                              ),
                            ),
                        ],
                      ),
                    )
                  : widget.controller.value.hasError
                  ? const VideoUnavailablePlaceholder()
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
          Positioned(
            top: 10,
            left: 12,
            child: _LandscapeChip(
              icon: LucideIcons.listVideo,
              label: context.bheText(
                '审核 ${candidate == null ? 0 : review.candidates.indexWhere((item) => item.id == candidate.id) + 1}/${review.candidates.length}',
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LandscapeIconButton(
                  icon: _railVisible
                      ? LucideIcons.panelRightClose
                      : LucideIcons.panelRightOpen,
                  tooltip: context.bheText(_railVisible ? '收起候选列表' : '打开候选列表'),
                  onPressed: () => setState(() => _railVisible = !_railVisible),
                ),
                const SizedBox(width: 6),
                _LandscapeIconButton(
                  icon: review.annotations
                      ? LucideIcons.scanLine
                      : LucideIcons.scan,
                  tooltip: context.bheText(
                    review.annotations ? '关闭标注' : '打开标注',
                  ),
                  selected: review.annotations,
                  onPressed: () =>
                      setState(() => review.annotations = !review.annotations),
                ),
                const SizedBox(width: 6),
                _LandscapeIconButton(
                  icon: LucideIcons.minimize,
                  tooltip: context.bheText('退出横屏审核'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (review.state.reviewBatchNoticeCount > 0)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _ReviewBatchNotice(
                count: review.state.reviewBatchNoticeCount,
              ),
            )
          else if (candidate != null)
            Positioned(
              left: 12,
              bottom: 12,
              child: _CompactEvidence(candidate: candidate),
            ),
          if (!playing)
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .42),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: review._togglePlay,
                  icon: const Icon(
                    LucideIcons.play,
                    color: Colors.white,
                    size: 34,
                  ),
                  tooltip: context.bheText('播放'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(
    BuildContext context, {
    required int position,
    required int lower,
    required int upper,
    required int maxValue,
  }) {
    final value = widget.controller.value;
    final candidate = _candidate;
    final excluded = review.statusFilter == 'excluded';
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 750;
        final controls = <Widget>[
          _LandscapeIconButton(
            icon: LucideIcons.rotateCcw,
            tooltip: context.bheText('重播当前片段'),
            onPressed: candidate == null
                ? null
                : () => review._replay(candidate),
          ),
          _LandscapeIconButton(
            icon: LucideIcons.chevronLeft,
            tooltip: '${context.bheText('后退')} 1.5 ${context.bheText('秒')}',
            onPressed: () => review._seek(-1500),
          ),
          _LandscapeIconButton(
            icon: value.isPlaying ? LucideIcons.pause : LucideIcons.play,
            tooltip: context.bheText(value.isPlaying ? '暂停' : '播放'),
            selected: value.isPlaying,
            onPressed: review._togglePlay,
          ),
          _LandscapeIconButton(
            icon: LucideIcons.chevronRight,
            tooltip: '${context.bheText('前进')} 1.5 ${context.bheText('秒')}',
            onPressed: () => review._seek(1500),
          ),
          const SizedBox(width: 6),
          if (!compact)
            Text(
              _formatMs(position),
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          Expanded(
            child: Slider(
              min: lower.toDouble(),
              max: maxValue.toDouble(),
              value: position
                  .clamp(lower.toDouble(), maxValue.toDouble())
                  .toDouble(),
              onChanged: (next) => review._seekTo(next.round()),
            ),
          ),
          if (!compact)
            Text(
              _formatMs(upper - lower),
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          const SizedBox(width: 5),
          _LandscapeIconButton(
            icon: review.autoReplay ? LucideIcons.repeat1 : LucideIcons.repeat,
            tooltip: context.bheText(review.autoReplay ? '关闭循环播放' : '开启循环播放'),
            selected: review.autoReplay,
            onPressed: () =>
                setState(() => review.autoReplay = !review.autoReplay),
          ),
          PopupMenuButton<double>(
            tooltip: context.bheText('播放速度'),
            initialValue: review.speed,
            onSelected: (value) {
              setState(() => review.speed = value);
              unawaited(
                review._enqueuePlayer(
                  (player) => player.setPlaybackSpeed(value),
                ),
              );
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: .75, child: Text('0.75×')),
              PopupMenuItem(value: 1, child: Text('1.0×')),
              PopupMenuItem(value: 1.25, child: Text('1.25×')),
              PopupMenuItem(value: 1.5, child: Text('1.5×')),
              PopupMenuItem(value: 2, child: Text('2.0×')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '${review.speed.toStringAsFixed(review.speed == review.speed.roundToDouble() ? 1 : 2)}×',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
          ),
        ];
        final decisions = <Widget>[
          _ReviewUndoButton(
            onPressed: review.state.canUndoReview
                ? () => unawaited(review.state.undoReview())
                : null,
            highlighted: review.state.reviewBatchNoticeCount > 0,
          ),
          const SizedBox(width: 7),
          _LandscapeIconButton(
            icon: LucideIcons.tag,
            tooltip: context.bheText('选择球员标签'),
            onPressed: candidate == null
                ? null
                : () => _editPlayerTags(candidate),
          ),
          const SizedBox(width: 7),
          SizedBox(
            width: 108,
            child: OutlinedButton.icon(
              onPressed: candidate == null || excluded
                  ? null
                  : () => _reviewCandidate(CandidateSelection.excluded),
              icon: const Icon(LucideIcons.x, size: 17),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(context.bheText(excluded ? '已排除' : '不选')),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                minimumSize: const Size(78, 38),
                side: BorderSide(color: Colors.white.withValues(alpha: .28)),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: excluded ? 146 : 108,
            child: FilledButton.icon(
              onPressed: candidate == null
                  ? null
                  : () => _reviewCandidate(CandidateSelection.included),
              icon: const Icon(LucideIcons.check, size: 17),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(context.bheText(excluded ? '恢复·算进球' : '选中')),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size(82, 38),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ),
        ];
        return ColoredBox(
          color: const Color(0xFF111318),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 8, 8),
            child: compact
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: controls),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: decisions,
                      ),
                    ],
                  )
                : Row(children: [...controls, ...decisions]),
          ),
        );
      },
    );
  }
}

class _LandscapeIconButton extends StatelessWidget {
  const _LandscapeIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    isSelected: selected,
    visualDensity: VisualDensity.compact,
    icon: Icon(icon, size: 18),
    style: IconButton.styleFrom(
      foregroundColor: selected ? BhePalette.orange : Colors.white70,
      backgroundColor: Colors.white.withValues(alpha: .08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
  );
}

class _LandscapeChip extends StatelessWidget {
  const _LandscapeChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    ),
  );
}

class _PlaybackTimeBadge extends StatelessWidget {
  const _PlaybackTimeBadge({required this.positionMs});
  final int positionMs;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .62),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: BhePalette.orange,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            context.bheText('当前 ${_formatMs(positionMs)}'),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _CompactEvidence extends StatelessWidget {
  const _CompactEvidence({required this.candidate});
  final Candidate candidate;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .58),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      child: Text(
        context.bheText(
          '置信度 ${_score(candidate.confidence)}  ·  轨迹 ${_score(candidate.trajectoryScore)}  ·  穿框 ${_score(candidate.crossingScore)}  ·  篮网 ${_score(candidate.netMotionScore)}',
        ),
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
    ),
  );
}

class _CandidateOverlayPainter extends CustomPainter {
  const _CandidateOverlayPainter({
    required this.candidate,
    required this.rim,
    required this.positionMs,
  });

  final Candidate candidate;
  final Roi? rim;
  final int positionMs;

  @override
  void paint(Canvas canvas, Size size) {
    final sourcePoints = candidate.trajectory.isNotEmpty
        ? candidate.trajectory
        : [
            if (candidate.abovePoint != null) candidate.abovePoint!,
            if (candidate.belowPoint != null) candidate.belowPoint!,
          ];
    final points =
        sourcePoints
            .where(
              (point) =>
                  point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1,
            )
            .where((point) => point.timeMs <= positionMs + 20)
            .toList()
          ..sort((a, b) => a.timeMs.compareTo(b.timeMs));

    final trajectoryPaint = Paint()
      ..color = BhePalette.orange.withValues(alpha: .8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final rimRoi = rim;
    if (rimRoi != null) {
      final rimPaint = Paint()
        ..color = BhePalette.orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final rimRect = Rect.fromLTRB(
        rimRoi.left * size.width,
        rimRoi.top * size.height,
        rimRoi.right * size.width,
        rimRoi.bottom * size.height,
      );
      canvas.drawRect(rimRect, rimPaint);
      canvas.drawLine(
        Offset(rimRect.left, (rimRect.top + rimRect.bottom) / 2),
        Offset(rimRect.right, (rimRect.top + rimRect.bottom) / 2),
        rimPaint,
      );
    }
    if (points.length >= 2) {
      final path = Path()
        ..moveTo(points.first.x * size.width, points.first.y * size.height);
      for (var index = 0; index + 1 < points.length; index++) {
        final point = points[index];
        final next = points[index + 1];
        final midpoint = Offset(
          (point.x + next.x) * size.width / 2,
          (point.y + next.y) * size.height / 2,
        );
        path.quadraticBezierTo(
          point.x * size.width,
          point.y * size.height,
          midpoint.dx,
          midpoint.dy,
        );
      }
      path.lineTo(points.last.x * size.width, points.last.y * size.height);
      canvas.drawPath(path, trajectoryPaint);
    }

    if (points.isNotEmpty) {
      final current = points.last;
      final currentOffset = Offset(
        current.x * size.width,
        current.y * size.height,
      );
      canvas.drawCircle(currentOffset, 3, Paint()..color = BhePalette.orange);
      canvas.drawCircle(
        currentOffset,
        5,
        Paint()
          ..color = BhePalette.orange.withValues(alpha: .35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final crossing = candidate.crossingPoint;
    if (crossing != null &&
        candidate.completeCrossing == true &&
        crossing.timeMs <= positionMs + 200 &&
        crossing.x >= 0 &&
        crossing.x <= 1 &&
        crossing.y >= 0 &&
        crossing.y <= 1) {
      final crossingOffset = Offset(
        crossing.x * size.width,
        crossing.y * size.height,
      );
      final crossingColor = candidate.verdict == 'made'
          ? BhePalette.green
          : BhePalette.orange;
      canvas.drawCircle(
        crossingOffset,
        6,
        Paint()
          ..color = crossingColor.withValues(alpha: .35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      canvas.drawCircle(crossingOffset, 3, Paint()..color = crossingColor);
    }
  }

  @override
  bool shouldRepaint(covariant _CandidateOverlayPainter oldDelegate) =>
      oldDelegate.candidate.trajectory != candidate.trajectory ||
      oldDelegate.rim != rim ||
      oldDelegate.candidate.crossingPoint != candidate.crossingPoint ||
      oldDelegate.positionMs != positionMs;
}

class _BatchSecondsSlider extends StatelessWidget {
  const _BatchSecondsSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 56, child: Text(label)),
      Expanded(
        child: Slider(
          min: 0,
          max: 10,
          divisions: 10,
          value: value,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 44,
        child: Text('${value.round()} ${context.bheText('秒')}'),
      ),
    ],
  );
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, size: 19, color: BhePalette.orange),
    title: Text(title),
    subtitle: Text(detail),
  );
}

class _ReviewEmpty extends StatelessWidget {
  const _ReviewEmpty({required this.onOpenProject, this.onAddManual});
  final VoidCallback onOpenProject;
  final VoidCallback? onAddManual;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            LucideIcons.listChecks,
            size: 34,
            color: BhePalette.textSecondary,
          ),
          const SizedBox(height: 14),
          Text(
            context.bheText('还没有候选片段'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            onAddManual == null
                ? context.bheText('先完成视频分析，结果会自动出现在这里。')
                : context.bheText('分析没有找到候选，也可以手动补一个片段。'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            children: [
              OutlinedButton(
                onPressed: onOpenProject,
                child: Text(context.bheText('返回项目')),
              ),
              if (onAddManual != null)
                FilledButton.icon(
                  onPressed: onAddManual,
                  icon: const Icon(LucideIcons.plus, size: 17),
                  label: Text(context.bheText('补漏候选')),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _EvidenceSheet extends StatelessWidget {
  const _EvidenceSheet({required this.candidate, required this.state});
  final Candidate candidate;
  final MobileAppState state;

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: context.bheText('候选判断依据'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '#${candidate.id}  ·  ${candidate.displayTime}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 14),
        _EvidenceRow(
          label: context.bheText('综合置信度'),
          value: '${(candidate.confidence * 100).toStringAsFixed(0)}%',
        ),
        _EvidenceRow(
          label: context.bheText('轨迹分数'),
          value: _score(candidate.trajectoryScore),
        ),
        _EvidenceRow(
          label: context.bheText('穿框分数'),
          value: _score(candidate.crossingScore),
        ),
        _EvidenceRow(
          label: context.bheText('篮网运动'),
          value: _score(candidate.netMotionScore),
        ),
        if (candidate.verdict != null)
          _EvidenceRow(
            label: context.bheText('算法结论'),
            value: _verdictLabel(candidate.verdict!),
          ),
        if (candidate.reason != null)
          _EvidenceRow(
            label: context.bheText('审核提示'),
            value: _reasonLabel(candidate.reason!),
          ),
        if (candidate.trajectory.isNotEmpty)
          _EvidenceRow(
            label: context.bheText('轨迹点'),
            value: '${candidate.trajectory.length}',
          ),
        const Divider(height: 24),
        Text(
          context.bheText('颜色说明'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        _LegendDot(color: BhePalette.green, text: context.bheText('绿色：确认穿框点')),
        const SizedBox(height: 6),
        _LegendDot(
          color: BhePalette.orange,
          text: context.bheText('橙色：篮球轨迹、当前位置或推定穿框点'),
        ),
        const SizedBox(height: 12),
        Text(
          context.bheText('最终是否保留由你审核决定，算法结果只是候选建议。'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _showNoteEditor(context),
          icon: const Icon(LucideIcons.notebookPen, size: 17),
          label: Text(context.bheText(candidate.note == null ? '写备注' : '编辑备注')),
        ),
        const SizedBox(height: 8),
        if (candidate.effectivePlayers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final label in candidate.effectivePlayers)
                  _PlayerTagChip(player: label),
              ],
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => _showPlayerEditor(context),
          icon: const Icon(LucideIcons.tag, size: 17),
          label: Text(context.bheText('选择球员标签')),
        ),
      ],
    ),
  );

  Future<void> _showNoteEditor(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _NoteSheet(initialNote: candidate.note),
    );
    if (value != null && context.mounted) {
      await state.updateCandidateNote(candidate.id, value);
    }
  }

  Future<void> _showPlayerEditor(BuildContext context) async {
    await _showPlayerPicker(context, state, candidate);
  }
}

class _NoteSheet extends StatefulWidget {
  const _NoteSheet({this.initialNote});
  final String? initialNote;

  @override
  State<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<_NoteSheet> {
  late final TextEditingController _input;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialNote ?? '');
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _close(String value) {
    if (mounted) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOut,
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _SheetFrame(
      title: context.bheText('备注'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _input,
            autofocus: true,
            maxLines: 4,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: context.bheText('记录这个候选的情况'),
              alignLabelWithHint: true,
            ),
            onSubmitted: (value) => _close(value),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.bheText('取消')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => _close(_input.text),
                  child: Text(context.bheText('保存备注')),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Color _playerTagColor(String player) {
  const colors = [
    BhePalette.orange,
    BhePalette.gold,
    BhePalette.green,
    Color(0xFF62A9FF),
    Color(0xFFC084FC),
  ];
  return colors[(player.hashCode & 0x7fffffff) % colors.length];
}

class _ScopeChoiceChip extends StatelessWidget {
  const _ScopeChoiceChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final int count;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text('$label  $count'),
    selected: selected,
    onSelected: onSelected,
    showCheckmark: false,
    selectedColor: BhePalette.orange.withValues(alpha: .28),
    side: BorderSide(
      color: selected ? BhePalette.orange : BhePalette.borderStrong,
    ),
  );
}

class _PlayerChoiceChip extends StatelessWidget {
  const _PlayerChoiceChip({
    required this.player,
    required this.count,
    required this.selected,
    required this.onSelected,
  });
  final String player;
  final int count;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    final color = _playerTagColor(player);
    return InputChip(
      label: Text('$player  $count'),
      selected: selected,
      onSelected: onSelected,
      side: BorderSide(color: color.withValues(alpha: .65)),
      backgroundColor: color.withValues(alpha: .10),
      selectedColor: color.withValues(alpha: .28),
      labelStyle: TextStyle(color: selected ? Colors.white : color),
      avatar: Icon(LucideIcons.tag, size: 14, color: color),
    );
  }
}

class _PlayerTagChip extends StatelessWidget {
  const _PlayerTagChip({required this.player});
  final String player;

  @override
  Widget build(BuildContext context) {
    final color = _playerTagColor(player);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: .55)),
      ),
      child: Text(
        player,
        style: TextStyle(color: color, fontSize: 11),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

Future<void> _showPlayerPicker(
  BuildContext context,
  MobileAppState state,
  Candidate candidate,
) async {
  final session = state.projectSession;
  final labels = await showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (_) => _PlayerTagSheet(
      state: state,
      players: state.project.players,
      initialPlayers: candidate.effectivePlayers,
    ),
  );
  if (labels == null || !context.mounted || session != state.projectSession) return;
  final saved = await state.setCandidatePlayers(candidate.id, labels);
  if (!context.mounted || session != state.projectSession) return;
  if (!saved) {
    _showReviewSaveFailure(context, state.reviewDiagnosticError);
  }
}


String _verdictLabel(String value) => switch (value) {
  'made' => '疑似进球',
  'missed' => '疑似未进',
  'ambiguous' => '需要审核',
  _ => value,
};

String _reasonLabel(String value) => switch (value) {
  'net_no_motion' => '篮网运动较弱',
  'rebound' => '可能反弹',
  'pass_ball' => '可能横向离开',
  'no_shot' => '投篮轨迹不足',
  'rim_out' => '可能擦框偏出',
  'uncertain' => '证据不足，建议人工确认',
  'coarse_crossing_fine_review' => '粗扫通过',
  _ => value,
};

class _EvidenceRow extends StatelessWidget {
  const _EvidenceRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
    ],
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 10, 20, 20),
    this.titleStyle,
    this.canClose = true,
  });
  final String title;
  final Widget child;
  final EdgeInsets padding;
  final TextStyle? titleStyle;
  final bool canClose;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: padding,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 34,
                height: 3,
                decoration: BoxDecoration(
                  color: BhePalette.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: titleStyle ?? Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: canClose ? () => Navigator.pop(context) : null,
                  tooltip: context.bheText('返回上一步'),
                  icon: const Icon(LucideIcons.x, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    ),
  );
}

Future<void> _showQualitySheet(
  BuildContext context,
  MobileAppState state,
) async {
  final current = state.project.settings;
  final value = await showModalBottomSheet<AnalysisMode>(
    context: context,
    builder: (context) => _SheetFrame(
      title: context.bheText('分析质量'),
      child: Column(
        children: [
          _ChoiceRow(
            title: context.bheText('标准'),
            subtitle: context.bheText('640 输入 / 10fps，候选窗口精筛'),
            selected: current.mode == AnalysisMode.standard,
            onTap: () => Navigator.pop(context, AnalysisMode.standard),
          ),
          _ChoiceRow(
            title: context.bheText('高质量'),
            subtitle: context.bheText('640 输入 / 10fps，更高质量代理'),
            selected: current.mode == AnalysisMode.highQuality,
            onTap: () => Navigator.pop(context, AnalysisMode.highQuality),
          ),
        ],
      ),
    ),
  );
  if (value != null) {
    state.updateSettings(current.copyWith(mode: value, sampleFps: 10), fields: {'mode', 'sampleFps'});
  }
}

Future<void> _showClipSheet(BuildContext context, MobileAppState state) async {
  final current = state.project.settings;
  var before = math.min(current.clip.beforeSeconds, 10).toDouble();
  var after = math.min(current.clip.afterSeconds, 10).toDouble();
  final value = await showModalBottomSheet<ClipSettings>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => _SheetFrame(
        title: context.bheText('片段时长'),
        child: Column(
          children: [
            Text(
              '${before.round()} ${context.bheText('秒')} ${context.bheText('前')} + ${after.round()} ${context.bheText('秒')} ${context.bheText('后')}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(width: 56, child: Text(context.bheText('进球前'))),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(trackHeight: 5),
                    child: Slider(
                      min: 0,
                      max: 10,
                      divisions: 10,
                      value: before,
                      onChanged: (value) => setSheetState(() => before = value),
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${before.round()} ${context.bheText('秒')}'),
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(width: 56, child: Text(context.bheText('进球后'))),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(trackHeight: 5),
                    child: Slider(
                      min: 0,
                      max: 10,
                      divisions: 10,
                      value: after,
                      onChanged: (value) => setSheetState(() => after = value),
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${after.round()} ${context.bheText('秒')}'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                ClipSettings(
                  beforeSeconds: before.round(),
                  afterSeconds: after.round(),
                ),
              ),
              child: Text(context.bheText('应用')),
            ),
          ],
        ),
      ),
    ),
  );
  if (value != null) {
    state.updateSettings(current.copyWith(clip: value), fields: {'clip'});
  }
}

Future<void> _showRangeSheet(BuildContext context, MobileAppState state) async {
  final video = state.project.video;
  if (video == null) return;
  final current = state.project.settings;
  var start = current.startMs.toDouble();
  var end = (current.endMs ?? video.durationMs).toDouble();
  var previewPosition = start.round();
  var requestedPosition = previewPosition;
  final value = await showModalBottomSheet<({int start, int end})>(
    context: context,
    isScrollControlled: true,
    builder: (context) => AnimatedBuilder(
      animation: state,
      builder: (context, _) => StatefulBuilder(
        builder: (context, setSheetState) => _SheetFrame(
          title: context.bheText('分析范围'),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: _VideoPreview(
                  key: const ValueKey('analysis-range-preview'),
                  sourceRevision: state.videoSourceRevision,
                  unavailable: state.videoSourceFailure != null,
                  onFailure: state.markVideoFailure,
                  path: video.path,
                  aspectRatio: video.width / video.height,
                  seekStepMs: 1500,
                  initialPositionMs: start.round(),
                  requestedPositionMs: requestedPosition,
                  stopAtMs: end.round(),
                  onPositionChanged: (position) {
                    if (context.mounted) {
                      setSheetState(() => previewPosition = position);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${_formatMs(start.round())} — ${_formatMs(end.round())}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              _RangeEditorSlider(
                max: video.durationMs.toDouble().clamp(1, double.infinity),
                start: start,
                end: end,
                position: previewPosition.toDouble(),
                onChanged: (values) {
                  if (values.end - values.start < 1000) return;
                  final seekTo = _movedRangeHandle(
                    values: values,
                    previousStart: start,
                    previousEnd: end,
                  );
                  setSheetState(() {
                    start = values.start;
                    end = values.end;
                    previewPosition = seekTo;
                    requestedPosition = seekTo;
                  });
                },
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setSheetState(() {
                      start = 0;
                      end = video.durationMs.toDouble();
                      previewPosition = 0;
                      requestedPosition = 0;
                    }),
                    child: Text(context.bheText('使用全片')),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, (
                      start: start.round(),
                      end: end.round(),
                    )),
                    child: Text(context.bheText('完成')),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                context.bheText('跳过热身或无关片段，修改会自动保存。'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (value != null) {
    state.updateSettings(
      current.copyWith(startMs: value.start, endMs: value.end),
      fields: {'startMs', 'endMs'},
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    enabled: onTap != null,
    onTap: onTap,
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      selected ? LucideIcons.circleCheck : LucideIcons.circle,
      color: selected ? BhePalette.orange : BhePalette.textTertiary,
    ),
    title: Text(title),
    subtitle: Text(subtitle),
  );
}

Future<void> _showRoiEditor(BuildContext context, MobileAppState state) async {
  final video = state.project.video;
  if (video == null) return;
  final result = await showModalBottomSheet<({Roi hoop, Roi net})>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    isDismissible: false,
    builder: (context) => _RoiEditorSheet(
      video: video,
      hoop: state.project.hoopRoi,
      rim: state.project.rimRoi,
      net: state.project.netRoi,
      initialPositionMs: state.project.settings.startMs,
      onVideoFailure: state.markVideoFailure,
      onRelink: () { Navigator.pop(context); unawaited(state.relinkVideo()); },
    ),
  );
  if (result != null) state.updateRois(hoop: result.hoop, net: result.net);
}

Future<void> _showAboutDialog(BuildContext context, MobileAppState state) async {
  final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
  String? engineVersion;
  try {
    final snapshot = await MobileDiagnostics.instance.snapshot();
    final value = snapshot.environment['native_package_version'];
    if (value is String && value.isNotEmpty && value != 'unknown') {
      engineVersion = value;
    }
  } catch (_) {}
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dialogContext.bheText('关于')),
      content: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${dialogContext.bheText('版本')}：'
            '${mobileAppVersion == 'dev' ? dialogContext.bheText('开发版') : mobileAppVersion}',
          ),
          const SizedBox(height: 8),
          if (engineVersion != null)
            Text('${dialogContext.bheText('分析引擎版本')}：$engineVersion'),
          const Divider(height: 28),
          const SizedBox(height: 8),
          Material(
            color: Theme.of(dialogContext).brightness == Brightness.dark
                ? BhePalette.surface2
                : Theme.of(dialogContext).colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(dialogContext).brightness == Brightness.dark
                    ? const Color(0xFF31343F)
                    : const Color(0xFFE5E7EB),
              ),
            ),
            child: InkWell(
              key: const ValueKey('about-third-party-notices'),
              onTap: () => showLicensePage(
                context: dialogContext,
                applicationName: 'BHE',
                applicationVersion: 'v$mobileAppVersion',
              ),
              child: SizedBox(
                height: 52,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          Localizations.localeOf(dialogContext).languageCode == 'zh'
                              ? '第三方许可'
                              : 'Third-party notices',
                        ),
                      ),
                      Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: Theme.of(dialogContext).colorScheme.onSurface,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      )),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.onSurface,
            minimumSize: const Size(64, 44),
          ),
          child: Text(l10n?.text('关闭') ?? '关闭'),
        ),
        OutlinedButton(
          style: _aboutOutlinedStyle(dialogContext, const Size(96, 44)),
          onPressed: () {
            Navigator.pop(dialogContext);
            unawaited(
              showMobileDiagnostics(context, error: state.diagnosticError),
            );
          },
          child: Text(l10n?.text('现在反馈') ?? '现在反馈'),
        ),
      ],
    ),
  );
}

ButtonStyle _aboutOutlinedStyle(BuildContext context, Size minimumSize) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return OutlinedButton.styleFrom(
    foregroundColor: Theme.of(context).colorScheme.onSurface,
    minimumSize: minimumSize,
    side: BorderSide(
      color: dark ? const Color(0xFF6B7180) : const Color(0xFF6B7280),
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );
}


class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.updater, required this.state});

  final AppUpdater updater;
  final MobileAppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final english = l10n?.localeName.startsWith('en') == true;
    final manifest = updater.manifest;
    final package = updater.package;
    final status = updater.status;
    final hasUpdate = manifest != null &&
        package != null &&
        status != UpdateStatus.checking &&
        status != UpdateStatus.upToDate;
    final busy = state.analysing || state.exporting;
    String megabytes(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(0);

    final children = <Widget>[];
    if (status == UpdateStatus.idle || status == UpdateStatus.checking) {
      children.add(
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(context.bheText('正在检查更新…')),
          ],
        ),
      );
    } else if (status == UpdateStatus.upToDate) {
      children.add(
        Text(context.bheText('已经是最新版本（v${updater.currentVersion}）')),
      );
    } else if (!hasUpdate) {
      children.addAll([
        Text(
          context.bheText(updater.error ?? ''),
          style: theme.textTheme.bodySmall?.copyWith(color: BhePalette.error),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => updater.check(manual: true),
          child: Text(context.bheText('重新检查')),
        ),
      ]);
    }

    if (hasUpdate) {
      children.addAll([
        Text(
          context.bheText('新版本 v${updater.targetVersion}'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 2),
        Text(
          '${context.bheText('当前版本')} v${updater.currentVersion} · ${megabytes(package.size)} MB',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (final line in updater
            .notesFor(english: english)
            .split(RegExp('[；;]'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('· $line', style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 16),
      ]);
      switch (status) {
        case UpdateStatus.available:
          children.addAll([
            FilledButton.icon(
              onPressed: updater.download,
              icon: const Icon(LucideIcons.download, size: 17),
              label: Text(context.bheText('下载更新')),
            ),
            TextButton(
              onPressed: () async {
                await updater.skip();
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(context.bheText('跳过这个版本')),
            ),
          ]);
        case UpdateStatus.downloading:
          children.addAll([
            LinearProgressIndicator(value: updater.received / package.size),
            const SizedBox(height: 6),
            Text(
              context.bheText(
                '已下载 ${megabytes(updater.received)} / ${megabytes(package.size)} MB',
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: updater.cancelDownload,
              child: Text(context.bheText('取消')),
            ),
          ]);
        case UpdateStatus.failed:
          children.addAll([
            Text(
              context.bheText(updater.error ?? ''),
              style: theme.textTheme.bodySmall?.copyWith(color: BhePalette.error),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: updater.download,
              child: Text(context.bheText('继续下载')),
            ),
          ]);
        case UpdateStatus.ready:
          children.addAll([
            Text(
              context.bheText(
                busy
                    ? '现在有分析或导出在进行，等它完成再安装，安装时 BHE 会被关闭。'
                    : '下载完成。安装时 BHE 会被关闭，项目会保留。第一次安装需要允许 BHE「安装未知应用」。',
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : updater.install,
              icon: const Icon(LucideIcons.packageOpen, size: 17),
              label: Text(context.bheText('安装更新')),
            ),
          ]);
        default:
          break;
      }
    }

    if (status == UpdateStatus.failed) {
      children.add(TextButton(
        onPressed: () => showMobileDiagnostics(context, error: updater.diagnosticError),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: Text(context.bheText('反馈')),
      ));
    }
    return _SheetFrame(
      title: context.bheText('检查更新'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
