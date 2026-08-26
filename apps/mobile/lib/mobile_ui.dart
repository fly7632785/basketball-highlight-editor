import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

import 'mobile_app_state.dart';

abstract final class BhePalette {
  static const background = Color(0xFF0B0E14);
  static const surface = Color(0xFF121620);
  static const surface2 = Color(0xFF1A1F2B);
  static const surface3 = Color(0xFF23242F);
  static const text = Color(0xFFE6E8EE);
  static const textSecondary = Color(0xFF9AA0AC);
  static const textTertiary = Color(0xFF6B7280);
  static const border = Color(0xFF23242F);
  static const borderStrong = Color(0xFF31343F);
  static const orange = Color(0xFFFF6B2C);
  static const gold = Color(0xFFF0B35A);
  static const green = Color(0xFF3FB950);
  static const warning = Color(0xFFE3B341);
  static const error = Color(0xFFF85149);
}

ThemeData bheTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: BhePalette.orange,
        brightness: brightness,
        surface: dark ? BhePalette.surface : const Color(0xFFFFFFFF),
      ).copyWith(
        primary: dark ? BhePalette.orange : const Color(0xFFF2601D),
        onPrimary: Colors.white,
        secondary: dark ? BhePalette.gold : const Color(0xFFA86418),
        surface: dark ? BhePalette.surface : const Color(0xFFFFFFFF),
        onSurface: dark ? BhePalette.text : const Color(0xFF15171C),
        error: dark ? BhePalette.error : const Color(0xFFDC2626),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? BhePalette.background
        : const Color(0xFFFAFAFA),
    fontFamily: 'Inter',
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? BhePalette.background : const Color(0xFFFAFAFA),
      foregroundColor: dark ? BhePalette.text : const Color(0xFF15171C),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: dark ? BhePalette.surface : Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? BhePalette.surface : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: dark ? BhePalette.borderStrong : const Color(0xFFE5E7EB),
        ),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: dark ? BhePalette.orange : const Color(0xFFF2601D),
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: dark ? BhePalette.text : const Color(0xFF15171C),
        minimumSize: const Size(44, 44),
        side: BorderSide(
          color: dark ? BhePalette.borderStrong : const Color(0xFFCBD0D8),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: dark
            ? BhePalette.textSecondary
            : const Color(0xFF5A606B),
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? BhePalette.surface3 : const Color(0xFFF4F5F7),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(
          color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(
          color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(
          color: dark ? BhePalette.orange : const Color(0xFFF2601D),
          width: 1.5,
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? BhePalette.surface : Colors.white,
      indicatorColor: (dark ? BhePalette.orange : const Color(0xFFF2601D))
          .withValues(alpha: .16),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          color: dark ? BhePalette.textSecondary : const Color(0xFF5A606B),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
      thickness: 1,
      space: 1,
    ),
    textTheme: TextTheme(
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      headlineSmall: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      titleLarge: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      bodyLarge: TextStyle(
        fontSize: 14,
        height: 1.5,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        height: 1.45,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.45,
        color: dark ? BhePalette.textSecondary : const Color(0xFF5A606B),
      ),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.textSecondary : const Color(0xFF5A606B),
      ),
    ),
  );
}

enum _WorkspaceSection { project, review, export }

class BheMobileApp extends StatefulWidget {
  const BheMobileApp({super.key});

  @override
  State<BheMobileApp> createState() => _BheMobileAppState();
}

class _BheMobileAppState extends State<BheMobileApp> {
  final state = MobileAppState();
  _WorkspaceSection section = _WorkspaceSection.project;
  bool dark = true;
  String? _lastAnalysisStatus;
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();
    state.addListener(_handleStateChange);
  }

  void _handleStateChange() {
    final status = state.project.lastAnalysisStatus;
    if (status != _lastAnalysisStatus) {
      _lastAnalysisStatus = status;
      if (status == 'completed' && state.project.candidates.isNotEmpty) {
        if (mounted) setState(() => section = _WorkspaceSection.review);
      }
    }
  }

  @override
  void dispose() {
    state.removeListener(_handleStateChange);
    state.dispose();
    super.dispose();
  }

  void _handleSystemBack(BuildContext context) {
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('再按一次返回键退出 BHE'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'BHE',
    theme: bheTheme(Brightness.light),
    darkTheme: bheTheme(Brightness.dark),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
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
            dark: dark,
            onToggleTheme: () => setState(() => dark = !dark),
            section: state.analysing ? _WorkspaceSection.project : section,
            onSectionChanged: (value) => setState(() => section = value),
          ),
        ),
      ),
    ),
  );
}

class _AppShell extends StatelessWidget {
  const _AppShell({
    required this.state,
    required this.dark,
    required this.onToggleTheme,
    required this.section,
    required this.onSectionChanged,
  });

  final MobileAppState state;
  final bool dark;
  final VoidCallback onToggleTheme;
  final _WorkspaceSection section;
  final ValueChanged<_WorkspaceSection> onSectionChanged;

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
        state: state,
        onOpenReview: () => onSectionChanged(_WorkspaceSection.review),
      ),
      _WorkspaceSection.review => _ReviewView(
        state: state,
        onOpenProject: () => onSectionChanged(_WorkspaceSection.project),
        onOpenExport: () => onSectionChanged(_WorkspaceSection.export),
      ),
      _WorkspaceSection.export => _ExportView(state: state),
    };
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              state: state,
              dark: dark,
              onToggleTheme: onToggleTheme,
              section: section,
              onOpenProject: () => onSectionChanged(_WorkspaceSection.project),
              onOpenExport: state.project.candidates.isEmpty
                  ? null
                  : () => onSectionChanged(_WorkspaceSection.export),
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
    required this.section,
    required this.onOpenProject,
    required this.onOpenExport,
  });

  final MobileAppState state;
  final bool dark;
  final VoidCallback onToggleTheme;
  final _WorkspaceSection section;
  final VoidCallback onOpenProject;
  final VoidCallback? onOpenExport;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 10, 8),
    child: Row(
      children: [
        if (section != _WorkspaceSection.project)
          IconButton(
            onPressed: onOpenProject,
            tooltip: '返回项目',
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
                  Container(
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
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      section == _WorkspaceSection.project
                          ? 'BHE'
                          : section == _WorkspaceSection.review
                          ? '审核'
                          : '导出',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (state.project.video != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                state.project.name,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        if (onOpenExport != null)
          IconButton(
            onPressed: onOpenExport,
            tooltip: '导出',
            icon: const Icon(LucideIcons.download, size: 19),
          ),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          icon: const Icon(LucideIcons.ellipsis, size: 20),
          onSelected: (value) async {
            switch (value) {
              case 'theme':
                onToggleTheme();
                break;
              case 'import':
                await state.importProject();
                break;
              case 'delete':
                await _confirmDelete(context, state);
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'theme',
              child: Text(dark ? '切换浅色主题' : '切换深色主题'),
            ),
            const PopupMenuItem(value: 'import', child: Text('打开项目包')),
            const PopupMenuItem(value: 'delete', child: Text('删除当前项目')),
          ],
        ),
      ],
    ),
  );
}

Future<void> _confirmDelete(BuildContext context, MobileAppState state) async {
  if (state.project.video == null && state.recentProjects.isEmpty) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除当前项目？'),
      content: Text('“${state.project.name}”及其审核记录会从本机移除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed == true) await state.clearProject();
}

class _ProjectView extends StatelessWidget {
  const _ProjectView({required this.state, required this.onOpenReview});
  final MobileAppState state;
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width > 840 ? 900.0 : double.infinity;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
          children: [
            _PageIntro(
              eyebrow: 'PROJECT WORKSPACE',
              title: state.project.video == null
                  ? '开始一个视频项目'
                  : state.project.name,
              subtitle: state.project.video == null
                  ? '本地完成分析、审核和导出。'
                  : '配置好分析区域后即可开始识别。',
            ),
            if (state.project.video == null)
              _EmptyProject(
                onPick: () => unawaited(state.createNewProjectAndPickVideo()),
              )
            else
              _ProjectSetup(state: state, onOpenReview: onOpenReview),
            if (state.recentProjects.length > 1) ...[
              const SizedBox(height: 24),
              _SectionHeader(
                title: '最近项目',
                action: '${state.recentProjects.length} 个',
              ),
              const SizedBox(height: 8),
              for (final project in state.recentProjects.where(
                (item) => item.id != state.project.id,
              ))
                _RecentProjectRow(
                  project: project,
                  onTap: () => state.openProject(project.id),
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
  const _EmptyProject({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 30),
      child: Column(
        children: [
          const Icon(LucideIcons.fileVideo, size: 34, color: BhePalette.orange),
          const SizedBox(height: 16),
          Text('选择一段比赛视频', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 7),
          Text(
            'BHE 会在本机生成候选片段，之后由你快速审核。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onPick,
            icon: const Icon(LucideIcons.upload, size: 18),
            label: const Text('选择视频'),
          ),
        ],
      ),
    ),
  );
}

class _ProjectSetup extends StatelessWidget {
  const _ProjectSetup({required this.state, required this.onOpenReview});
  final MobileAppState state;
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) {
    final video = state.project.video!;
    final settings = state.project.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VideoPreview(
          path: video.path,
          aspectRatio: video.width / video.height,
        ),
        const SizedBox(height: 12),
        Text(
          '${video.width} × ${video.height}  ·  ${_formatMs(video.durationMs)}  ·  ${_formatBytes(video.sizeBytes)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        _SectionHeader(title: '分析配置', action: '自动保存'),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              _SettingRow(
                icon: LucideIcons.scanLine,
                title: '分析质量',
                value: settings.mode == AnalysisMode.standard
                    ? '标准 · 640×480 / 3fps'
                    : '高质量 · 960×720 / 5fps',
                onTap: () => _showQualitySheet(context, state),
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: LucideIcons.clock3,
                title: '片段时长',
                value:
                    '${settings.clip.beforeSeconds} 秒前 + ${settings.clip.afterSeconds} 秒后',
                onTap: () => _showClipSheet(context, state),
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: LucideIcons.crosshair,
                title: '篮筐与篮网区域',
                value: state.project.hoopRoi == null ? '尚未设置' : '已设置，可微调',
                onTap: () => _showRoiEditor(context, state),
                accent: state.project.hoopRoi == null
                    ? BhePalette.warning
                    : BhePalette.green,
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: LucideIcons.scan,
                title: '分析范围',
                value:
                    '${_formatMs(settings.startMs)} — ${_formatMs(settings.endMs ?? video.durationMs)}',
                onTap: () => _showRangeSheet(context, state),
              ),
            ],
          ),
        ),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineNotice(message: state.errorMessage!, error: true),
        ],
        if (state.project.lastAnalysisStatus == 'completed' &&
            state.project.candidates.isEmpty) ...[
          const SizedBox(height: 12),
          const _InlineNotice(message: '没有找到候选片段。建议检查检测区域或分析范围后重新分析。'),
        ],
        if (state.project.lastAnalysisStatus == 'interrupted') ...[
          const SizedBox(height: 12),
          const _InlineNotice(message: '上次分析未完成，可以重新开始。'),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: state.analysing
                    ? null
                    : () => unawaited(state.startAnalysis()),
                icon: const Icon(LucideIcons.play, size: 18),
                label: Text(state.project.candidates.isEmpty ? '开始分析' : '重新分析'),
              ),
            ),
            if (state.project.candidates.isNotEmpty) ...[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: onOpenReview,
                icon: const Icon(LucideIcons.listChecks, size: 18),
                label: Text('审核 ${state.project.candidates.length}'),
              ),
            ],
          ],
        ),
        if (state.project.lastAnalysisDurationMs != null) ...[
          const SizedBox(height: 10),
          Text(
            '上次分析耗时 ${_formatMs(state.project.lastAnalysisDurationMs!)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({
    required this.path,
    required this.aspectRatio,
    this.initialPositionMs,
    this.requestedPositionMs,
    this.stopAtMs,
    this.onPositionChanged,
  });
  final String path;
  final double aspectRatio;
  final int? initialPositionMs;
  final int? requestedPositionMs;
  final int? stopAtMs;
  final ValueChanged<int>? onPositionChanged;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? controller;
  Future<void> _playerQueue = Future<void>.value();
  int _lastReportedPosition = -1;
  bool _positionCallbackScheduled = false;

  @override
  void initState() {
    super.initState();
    final player = VideoPlayerController.file(File(widget.path));
    controller = player;
    player.addListener(_changed);
    unawaited(
      player.initialize().then((_) async {
        final initial = widget.initialPositionMs;
        if (initial != null) {
          await player.seekTo(Duration(milliseconds: initial));
        }
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void didUpdateWidget(covariant _VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final position = widget.requestedPositionMs;
    if (position != null && position != oldWidget.requestedPositionMs) {
      unawaited(_seekTo(position));
    }
  }

  @override
  void dispose() {
    controller?.removeListener(_changed);
    controller?.dispose();
    super.dispose();
  }

  void _changed() {
    final player = controller;
    final stopAt = widget.stopAtMs;
    if (player?.value.isInitialized == true &&
        stopAt != null &&
        player!.value.isPlaying &&
        player.value.position.inMilliseconds >= stopAt) {
      unawaited(player.pause());
    }
    final position = player?.value.position.inMilliseconds;
    if (position != null && (position - _lastReportedPosition).abs() >= 100) {
      _lastReportedPosition = position;
      if (widget.onPositionChanged != null && !_positionCallbackScheduled) {
        _positionCallbackScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _positionCallbackScheduled = false;
          if (!mounted) return;
          widget.onPositionChanged?.call(
            controller?.value.position.inMilliseconds ?? position,
          );
        });
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    await _enqueuePlayer((player) async {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        await player.play();
      }
    });
  }

  Future<void> _seek(int milliseconds) async {
    await _enqueuePlayer((player) async {
      final next = player.value.position + Duration(milliseconds: milliseconds);
      final bounded = next < Duration.zero
          ? Duration.zero
          : next > player.value.duration
          ? player.value.duration
          : next;
      await player.seekTo(bounded);
    });
  }

  Future<void> _seekTo(int milliseconds) async {
    await _enqueuePlayer(
      (player) => player.seekTo(Duration(milliseconds: milliseconds)),
    );
  }

  Future<void> _replay() async {
    await _enqueuePlayer((player) async {
      await player.seekTo(Duration.zero);
      await player.play();
    });
  }

  Future<void> _enqueuePlayer(
    Future<void> Function(VideoPlayerController player) action,
  ) {
    final task = _playerQueue.then((_) async {
      final player = controller;
      if (player == null || !player.value.isInitialized) return;
      await action(player);
    });
    _playerQueue = task.then<void>((_) {}, onError: (_, _) {});
    return task;
  }

  @override
  Widget build(BuildContext context) {
    final player = controller;
    final ratio = widget.aspectRatio.isFinite && widget.aspectRatio > 0
        ? widget.aspectRatio
        : 16 / 9;
    final initialized = player?.value.isInitialized == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
          child: AspectRatio(
            aspectRatio: ratio,
            child: ColoredBox(
              color: Colors.black,
              child: initialized
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(
                          onTap: _toggle,
                          child: VideoPlayer(player!),
                        ),
                        IgnorePointer(
                          child: Align(
                            alignment: Alignment.center,
                            child: AnimatedOpacity(
                              opacity: player.value.isPlaying ? .18 : .9,
                              duration: const Duration(milliseconds: 150),
                              child: Icon(
                                player.value.isPlaying
                                    ? LucideIcons.pause
                                    : LucideIcons.play,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
        if (initialized)
          Container(
            decoration: const BoxDecoration(
              color: BhePalette.surface3,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(9)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    value: player!.value.position.inMilliseconds
                        .toDouble()
                        .clamp(
                          0,
                          player.value.duration.inMilliseconds.toDouble().clamp(
                            1,
                            double.infinity,
                          ),
                        ),
                    max: player.value.duration.inMilliseconds.toDouble().clamp(
                      1,
                      double.infinity,
                    ),
                    onChanged: (value) => _seekTo(value.round()),
                  ),
                ),
                Row(
                  children: [
                    Text(
                      '${_formatMs(player.value.position.inMilliseconds)} / ${_formatMs(player.value.duration.inMilliseconds)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => _seek(-1500),
                      icon: const Icon(LucideIcons.rotateCcw, size: 17),
                      tooltip: '后退 1.5 秒',
                    ),
                    IconButton.filledTonal(
                      onPressed: _toggle,
                      icon: Icon(
                        player.value.isPlaying
                            ? LucideIcons.pause
                            : LucideIcons.play,
                        size: 18,
                      ),
                      tooltip: '播放/暂停',
                    ),
                    IconButton(
                      onPressed: () => _seek(1500),
                      icon: const Icon(LucideIcons.rotateCw, size: 17),
                      tooltip: '前进 1.5 秒',
                    ),
                    IconButton(
                      onPressed: _replay,
                      icon: const Icon(LucideIcons.refreshCw, size: 17),
                      tooltip: '重播',
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
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
              '播放位置 ${_formatMs(boundedPosition.round())}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            Text(
              '范围 ${_formatMs(start.round())} — ${_formatMs(end.round())}',
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
  const _RecentProjectRow({required this.project, required this.onTap});
  final ProjectSnapshot project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 7),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            const Icon(
              LucideIcons.fileVideo,
              size: 18,
              color: BhePalette.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(project.name, overflow: TextOverflow.ellipsis),
            ),
            Text(
              '${project.candidates.length} 个候选',
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});
  final String title;
  final String? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const Spacer(),
      if (action != null)
        Text(action!, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message, this.error = false});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: (error ? BhePalette.error : BhePalette.warning).withValues(
        alpha: .10,
      ),
      border: Border(
        left: BorderSide(
          color: error ? BhePalette.error : BhePalette.warning,
          width: 2,
        ),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          error ? LucideIcons.circleAlert : LucideIcons.info,
          size: 16,
          color: error ? BhePalette.error : BhePalette.warning,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
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
    final percent = (state.progress * 100).round();
    const steps = <(AnalysisStage, String)>[
      (AnalysisStage.validateInput, '检查视频'),
      (AnalysisStage.prepareProxy, '准备本地模型'),
      (AnalysisStage.coarseScan, '扫描视频'),
      (AnalysisStage.generateCandidates, '生成候选'),
      (AnalysisStage.refineCandidates, '精筛候选'),
      (AnalysisStage.persistCandidates, '保存结果'),
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
                    const Expanded(
                      child: _PageIntro(
                        eyebrow: 'LOCAL ANALYSIS',
                        title: '正在分析视频',
                        subtitle: '分析在本机运行，完成后会自动保存结果。',
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(state.cancelAnalysis()),
                      child: const Text('取消'),
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
                                    ? '准备本地分析'
                                    : state.progressMessage,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            if (state.eta != null)
                              Text(
                                '还需 ${_formatMs(state.eta!.inMilliseconds)}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                        if (state.processedFrames != null &&
                            state.totalFrames != null) ...[
                          const SizedBox(height: 7),
                          Text(
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
                if (state.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  _InlineNotice(message: state.errorMessage!, error: true),
                ],
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
    required this.state,
    required this.onOpenProject,
    required this.onOpenExport,
  });
  final MobileAppState state;
  final VoidCallback onOpenProject;
  final VoidCallback onOpenExport;

  @override
  State<_ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<_ReviewView> {
  VideoPlayerController? controller;
  final _railController = ScrollController();
  final _candidateKeys = <GlobalKey>[];
  Future<void> _playerQueue = Future<void>.value();
  int selectedIndex = 0;
  bool annotations = true;
  bool autoReplay = true;
  double speed = 1;
  bool _stoppingAtCandidateEnd = false;
  bool _completionPromptShown = false;
  DateTime _lastVideoPaint = DateTime.fromMillisecondsSinceEpoch(0);

  MobileAppState get state => widget.state;
  List<Candidate> get candidates =>
      [...state.project.candidates]
        ..sort((a, b) => a.eventMs.compareTo(b.eventMs));
  Candidate? get selected => candidates.isEmpty
      ? null
      : candidates[selectedIndex.clamp(0, candidates.length - 1)];

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]),
    );
    _openVideo();
  }

  Future<void> _openVideo() async {
    final path = state.project.video?.path;
    if (path == null) return;
    final next = VideoPlayerController.file(File(path));
    await next.initialize();
    next.addListener(_videoChanged);
    if (!mounted) {
      await next.dispose();
      return;
    }
    await controller?.dispose();
    setState(() {
      controller = next;
      selectedIndex = 0;
    });
    if (candidates.isNotEmpty) await _replay(candidates.first);
  }

  void _videoChanged() {
    if (!mounted) return;
    final candidate = selected;
    final value = controller?.value;
    if (candidate != null &&
        value != null &&
        value.isPlaying &&
        value.position.inMilliseconds >= candidate.endMs &&
        !_stoppingAtCandidateEnd) {
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
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]),
    );
    controller?.removeListener(_videoChanged);
    controller?.dispose();
    _railController.dispose();
    super.dispose();
  }

  Future<void> _select(int index) async {
    if (index < 0 || index >= candidates.length) return;
    _stoppingAtCandidateEnd = false;
    setState(() => selectedIndex = index);
    unawaited(_scrollToSelected());
    await _replay(candidates[index]);
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
      final next = value.position + Duration(milliseconds: milliseconds);
      final bounded = next < Duration.zero
          ? Duration.zero
          : next > value.duration
          ? value.duration
          : next;
      await player.seekTo(bounded);
    });
  }

  Future<void> _seekTo(int milliseconds) async {
    await _enqueuePlayer(
      (player) => player.seekTo(Duration(milliseconds: milliseconds)),
    );
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
      final player = controller;
      if (player == null || !player.value.isInitialized) return;
      await action(player);
    });
    _playerQueue = task.then<void>((_) {}, onError: (_, _) {});
    return task;
  }

  Future<void> _scrollToSelected() async {
    if (selectedIndex >= _candidateKeys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _candidateKeys[selectedIndex].currentContext;
      if (target != null && mounted) {
        Scrollable.ensureVisible(
          target,
          alignment: .45,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final candidate = selected;
    if (candidate == null) {
      return _ReviewEmpty(
        onOpenProject: widget.onOpenProject,
        onAddManual: state.project.video == null
            ? null
            : () => unawaited(_addManualCandidate(context)),
      );
    }
    while (_candidateKeys.length < candidates.length) {
      _candidateKeys.add(GlobalKey());
    }
    if (_candidateKeys.length > candidates.length) {
      _candidateKeys.removeRange(candidates.length, _candidateKeys.length);
    }
    final video = state.project.video!;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  flex: 4,
                  child: _CandidateRail(
                    controller: _railController,
                    itemKeys: _candidateKeys,
                    candidates: candidates,
                    selectedIndex: selectedIndex,
                    onSelect: _select,
                    onAdd: () => _addManualCandidate(context),
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: _ReviewVideoStage(
                    controller: controller,
                    candidate: candidate,
                    annotations: annotations,
                    aspectRatio: video.width / video.height,
                    onToggle: () => _togglePlay(),
                    onScrubTo: _seekTo,
                    onResume: _resumePlayback,
                    onSwipeVertical: (velocity) => _select(
                      velocity < 0 ? selectedIndex + 1 : selectedIndex - 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _ReviewActionBar(
            candidate: candidate,
            controller: controller,
            annotations: annotations,
            autoReplay: autoReplay,
            speed: speed,
            onToggle: _togglePlay,
            onReplay: () => _replay(candidate),
            onSeekBack: () => _seek(-1500),
            onSeekForward: () => _seek(1500),
            onSeekTo: _seekTo,
            onToggleAnnotations: () =>
                setState(() => annotations = !annotations),
            onToggleAutoReplay: () => setState(() => autoReplay = !autoReplay),
            onSpeed: (value) async {
              setState(() => speed = value);
              await _enqueuePlayer((player) => player.setPlaybackSpeed(value));
            },
            onInclude: () => _review(CandidateSelection.included),
            onExclude: () => _review(CandidateSelection.excluded),
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

  Future<void> _showShortcuts(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (_) => _SheetFrame(
        title: '操作提示',
        child: Column(
          children: const [
            _ShortcutRow(
              icon: LucideIcons.arrowUp,
              title: '上滑 / 下滑',
              detail: '切换上一个 / 下一个候选片段',
            ),
            _ShortcutRow(
              icon: LucideIcons.moveHorizontal,
              title: '左右拖动视频',
              detail: '拖动预览位置，松手后跳转到对应时间',
            ),
            _ShortcutRow(
              icon: LucideIcons.play,
              title: '点击视频',
              detail: '播放或暂停当前片段',
            ),
            _ShortcutRow(
              icon: LucideIcons.check,
              title: '选中 / 不选',
              detail: '完成当前候选后自动进入下一个',
            ),
          ],
        ),
      ),
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
    var previewPosition = start.round();
    var requestedPosition = previewPosition;
    final range = await showModalBottomSheet<({int start, int end})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => _SheetFrame(
          title: '补漏候选',
          child: Column(
            children: [
              Text(
                '用视频控制确认时间，再拖动两端确定要审核的片段。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              _VideoPreview(
                path: video.path,
                aspectRatio: video.width / video.height,
                initialPositionMs: start.round(),
                requestedPositionMs: requestedPosition,
                stopAtMs: end.round(),
                onPositionChanged: (position) {
                  if (context.mounted) {
                    setSheetState(() => previewPosition = position);
                  }
                },
              ),
              const SizedBox(height: 10),
              Text(
                '${_formatMs(start.round())} — ${_formatMs(end.round())}  ·  ${_formatMs((end - start).round())}',
                style: Theme.of(context).textTheme.titleMedium,
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
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, (
                    start: start.round(),
                    end: end.round(),
                  )),
                  icon: const Icon(LucideIcons.plus, size: 18),
                  label: const Text('加入审核列表'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (range == null) return;
    final id = 'manual_${DateTime.now().microsecondsSinceEpoch}';
    state.addCandidate(
      Candidate(
        id: id,
        startMs: range.start,
        endMs: range.end,
        eventMs: ((range.start + range.end) / 2).round(),
        reason: 'manual',
        verdict: 'manual',
        evidenceSource: 'manual',
      ),
    );
    final index = state.project.candidates.indexWhere(
      (candidate) => candidate.id == id,
    );
    if (index >= 0) await _select(index);
  }

  void _review(CandidateSelection selection) {
    final candidate = selected;
    if (candidate == null) return;
    state.toggleCandidate(candidate.id, selection);
    if (selection == CandidateSelection.included ||
        selection == CandidateSelection.excluded) {
      if (selectedIndex < candidates.length - 1) {
        unawaited(_select(selectedIndex + 1));
      } else if (!_completionPromptShown) {
        _completionPromptShown = true;
        unawaited(_showReviewCompletePrompt(context));
      }
    }
  }

  Future<void> _showReviewCompletePrompt(BuildContext context) async {
    final export = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('审核完成'),
        content: Text('已处理 ${candidates.length} 个候选片段，可以进入导出。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后导出'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(LucideIcons.download, size: 17),
            label: const Text('去导出'),
          ),
        ],
      ),
    );
    if (export == true && mounted) widget.onOpenExport();
  }

  Future<void> _editRange(BuildContext context, Candidate candidate) async {
    final video = state.project.video;
    if (video == null) return;
    var start = candidate.startMs.toDouble();
    var end = candidate.endMs.toDouble();
    var previewPosition = start.round();
    var requestedPosition = previewPosition;
    final result = await showModalBottomSheet<({int start, int end})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => _SheetFrame(
          title: '调整片段范围',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _VideoPreview(
                path: video.path,
                aspectRatio: video.width / video.height,
                initialPositionMs: start.round(),
                requestedPositionMs: requestedPosition,
                stopAtMs: end.round(),
                onPositionChanged: (position) {
                  if (context.mounted) {
                    setSheetState(() => previewPosition = position);
                  }
                },
              ),
              const SizedBox(height: 10),
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
              Text(
                '先用上方视频找到位置，再拖动滑杆两端微调片段起止。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, (
                  start: start.round(),
                  end: end.round(),
                )),
                child: const Text('应用'),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) {
      state.updateCandidate(
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
    required this.candidate,
    required this.annotations,
    required this.aspectRatio,
    required this.onToggle,
    required this.onScrubTo,
    required this.onResume,
    required this.onSwipeVertical,
  });
  final VideoPlayerController? controller;
  final Candidate candidate;
  final bool annotations;
  final double aspectRatio;
  final VoidCallback onToggle;
  final Future<void> Function(int) onScrubTo;
  final Future<void> Function() onResume;
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
    if (_resumeAfterScrub) unawaited(player?.pause());
  }

  void _updateScrub(DragUpdateDetails details, double width) {
    if (!_scrubbing || width <= 0) return;
    final travel = math.max(widget.candidate.duration.inMilliseconds, 6000);
    final delta = ((details.globalPosition.dx - _dragStartX) / width * travel)
        .round();
    final next = (_dragStartPosition + delta).clamp(
      widget.candidate.startMs,
      widget.candidate.endMs,
    );
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
    final ratio = widget.aspectRatio.isFinite && widget.aspectRatio > 0
        ? widget.aspectRatio
        : 16 / 9;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
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
                if (player?.value.isInitialized == true)
                  Center(
                    child: AspectRatio(
                      aspectRatio: ratio,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VideoPlayer(player!),
                          if (widget.annotations &&
                              widget.candidate.trajectory.isNotEmpty)
                            CustomPaint(
                              painter: _CandidateOverlayPainter(
                                candidate: widget.candidate,
                                positionMs:
                                    player.value.position.inMilliseconds,
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                else
                  const Center(child: CircularProgressIndicator()),
                if (widget.annotations)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: _AnnotationBadge(candidate: widget.candidate),
                  ),
                Positioned(
                  left: 10,
                  bottom: 10,
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
                                _resumeAfterScrub ? '松手后继续播放' : '松手后定位并暂停',
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

class _AnnotationBadge extends StatelessWidget {
  const _AnnotationBadge({required this.candidate});
  final Candidate candidate;

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
              color: BhePalette.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '候选 ${candidate.displayTime}',
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
        '置信度 ${_score(candidate.confidence)}  ·  轨迹 ${_score(candidate.trajectoryScore)}  ·  穿框 ${_score(candidate.crossingScore)}  ·  篮网 ${_score(candidate.netMotionScore)}',
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
    ),
  );
}

class _CandidateOverlayPainter extends CustomPainter {
  const _CandidateOverlayPainter({
    required this.candidate,
    required this.positionMs,
  });

  final Candidate candidate;
  final int positionMs;

  @override
  void paint(Canvas canvas, Size size) {
    final points =
        candidate.trajectory
            .where(
              (point) =>
                  point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1,
            )
            .where(
              (point) => point.confidence == null || point.confidence! >= .05,
            )
            .where(
              (point) =>
                  candidate.eventMs <= 0 ||
                  (point.timeMs >= candidate.eventMs - 1800 &&
                      point.timeMs <= candidate.eventMs + 700),
            )
            .where((point) => point.timeMs <= positionMs + 20)
            .toList()
          ..sort((a, b) => a.timeMs.compareTo(b.timeMs));

    final segments = <List<EvidencePoint>>[];
    var segment = <EvidencePoint>[];
    for (final point in points) {
      if (segment.isNotEmpty) {
        final previous = segment.last;
        final dt = point.timeMs - previous.timeMs;
        final dx = point.x - previous.x;
        final dy = point.y - previous.y;
        final jump = math.sqrt(dx * dx + dy * dy);
        if (dt <= 0 || dt > 1200 || jump > .24) {
          if (segment.length >= 2) segments.add(segment);
          segment = <EvidencePoint>[];
        }
      }
      segment.add(point);
    }
    if (segment.length >= 2) segments.add(segment);

    final trajectoryPaint = Paint()
      ..color = BhePalette.orange.withValues(alpha: .8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final points in segments) {
      if (points.length < 2) continue;
      final path = Path()
        ..moveTo(points.first.x * size.width, points.first.y * size.height);
      for (var index = 0; index + 1 < points.length; index++) {
        final point = points[index];
        final next = points[index + 1];
        path.quadraticBezierTo(
          point.x * size.width,
          point.y * size.height,
          (point.x + next.x) * size.width / 2,
          (point.y + next.y) * size.height / 2,
        );
      }
      path.lineTo(points.last.x * size.width, points.last.y * size.height);
      canvas.drawPath(path, trajectoryPaint);
    }

    final detectionPaint = Paint()..color = BhePalette.green;
    for (final point in points) {
      canvas.drawCircle(
        Offset(point.x * size.width, point.y * size.height),
        2.5,
        detectionPaint,
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
      canvas.drawCircle(
        Offset(crossing.x * size.width, crossing.y * size.height),
        4.5,
        Paint()
          ..color = BhePalette.orange
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    final prediction = candidate.predictedLandingPoint;
    if (prediction != null &&
        prediction.x >= 0 &&
        prediction.x <= 1 &&
        prediction.y >= 0 &&
        prediction.y <= 1) {
      canvas.drawCircle(
        Offset(prediction.x * size.width, prediction.y * size.height),
        4,
        Paint()..color = BhePalette.gold,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CandidateOverlayPainter oldDelegate) =>
      oldDelegate.candidate.trajectory != candidate.trajectory ||
      oldDelegate.candidate.crossingPoint != candidate.crossingPoint ||
      oldDelegate.candidate.predictedLandingPoint !=
          candidate.predictedLandingPoint ||
      oldDelegate.positionMs != positionMs;
}

class _CandidateRail extends StatelessWidget {
  const _CandidateRail({
    required this.controller,
    required this.itemKeys,
    required this.candidates,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAdd,
  });
  final ScrollController controller;
  final List<GlobalKey> itemKeys;
  final List<Candidate> candidates;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).cardTheme.color ?? BhePalette.surface,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 2),
          child: Row(
            children: [
              Text(
                '候选 ${candidates.length}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('补漏'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(44, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            itemCount: candidates.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final candidate = candidates[index];
              final selected = index == selectedIndex;
              final included =
                  candidate.selection == CandidateSelection.included;
              return InkWell(
                key: itemKeys[index],
                onTap: () => onSelect(index),
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? BhePalette.orange.withValues(alpha: .13)
                        : Colors.transparent,
                    border: Border.all(
                      color: selected ? BhePalette.orange : BhePalette.border,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: included
                              ? BhePalette.green
                              : BhePalette.textTertiary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '#${index + 1}  ${candidate.displayTime}',
                              style: Theme.of(context).textTheme.titleMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_formatMs(candidate.startMs)} — ${_formatMs(candidate.endMs)}  ·  ${_formatMs(candidate.duration.inMilliseconds)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (candidate.player != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 10, right: 12),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 104),
                            child: _PlayerTagChip(player: candidate.player!),
                          ),
                        ),
                      Icon(
                        included ? LucideIcons.check : LucideIcons.x,
                        size: 17,
                        color: included
                            ? BhePalette.green
                            : BhePalette.textTertiary,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
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

class _ReviewActionBar extends StatelessWidget {
  const _ReviewActionBar({
    required this.candidate,
    required this.controller,
    required this.annotations,
    required this.autoReplay,
    required this.speed,
    required this.onToggle,
    required this.onReplay,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeekTo,
    required this.onToggleAnnotations,
    required this.onToggleAutoReplay,
    required this.onSpeed,
    required this.onInclude,
    required this.onExclude,
    required this.onDetails,
    required this.onEditRange,
    required this.onPlayer,
    required this.onExport,
    required this.onShortcuts,
  });
  final Candidate candidate;
  final VideoPlayerController? controller;
  final bool annotations;
  final bool autoReplay;
  final double speed;
  final VoidCallback onToggle;
  final VoidCallback onReplay;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final ValueChanged<int> onSeekTo;
  final VoidCallback onToggleAnnotations;
  final VoidCallback onToggleAutoReplay;
  final ValueChanged<double> onSpeed;
  final VoidCallback onInclude;
  final VoidCallback onExclude;
  final VoidCallback onDetails;
  final VoidCallback onEditRange;
  final VoidCallback onPlayer;
  final VoidCallback onExport;
  final VoidCallback onShortcuts;

  @override
  Widget build(BuildContext context) {
    final value = controller?.value;
    final duration = value?.duration.inMilliseconds.toDouble() ?? 1;
    final position = (value?.position.inMilliseconds.toDouble() ?? 0)
        .clamp(0, duration)
        .toDouble();
    return Material(
      color: Theme.of(context).cardTheme.color,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Slider(
              value: position,
              max: duration,
              onChanged: controller == null
                  ? null
                  : (value) => onSeekTo(value.round()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 2,
                runSpacing: 2,
                children: [
                  IconButton(
                    onPressed: onSeekBack,
                    icon: const Icon(LucideIcons.rotateCcw, size: 18),
                    tooltip: '后退 1.5 秒',
                  ),
                  IconButton.filled(
                    onPressed: onToggle,
                    icon: Icon(
                      value?.isPlaying == true
                          ? LucideIcons.pause
                          : LucideIcons.play,
                      size: 18,
                    ),
                    tooltip: '播放/暂停',
                  ),
                  IconButton(
                    onPressed: onSeekForward,
                    icon: const Icon(LucideIcons.rotateCw, size: 18),
                    tooltip: '前进 1.5 秒',
                  ),
                  IconButton(
                    onPressed: onReplay,
                    icon: const Icon(LucideIcons.refreshCw, size: 18),
                    tooltip: '重播',
                  ),
                  IconButton(
                    onPressed: onToggleAutoReplay,
                    icon: Icon(
                      autoReplay ? LucideIcons.repeat2 : LucideIcons.repeatOff,
                      size: 18,
                      color: autoReplay ? BhePalette.orange : null,
                    ),
                    tooltip: autoReplay ? '关闭自动重播' : '打开自动重播',
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多审核操作',
                    onSelected: _handleMore,
                    color: Theme.of(context).cardTheme.color,
                    elevation: 8,
                    menuPadding: const EdgeInsets.symmetric(vertical: 6),
                    constraints: const BoxConstraints(minWidth: 220),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(color: BhePalette.borderStrong),
                    ),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'annotations',
                        child: Text(annotations ? '关闭标注' : '打开标注'),
                      ),
                      const PopupMenuItem(
                        value: 'range',
                        child: Text('调整片段范围'),
                      ),
                      const PopupMenuItem(
                        value: 'shortcuts',
                        child: Text('查看操作提示'),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'speed_0.5',
                        child: Text('播放速度 0.5x${speed == .5 ? ' ✓' : ''}'),
                      ),
                      PopupMenuItem(
                        value: 'speed_1.0',
                        child: Text('播放速度 1.0x${speed == 1 ? ' ✓' : ''}'),
                      ),
                      PopupMenuItem(
                        value: 'speed_1.5',
                        child: Text('播放速度 1.5x${speed == 1.5 ? ' ✓' : ''}'),
                      ),
                      PopupMenuItem(
                        value: 'speed_2.0',
                        child: Text('播放速度 2.0x${speed == 2 ? ' ✓' : ''}'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'evidence',
                        child: Text('查看判断依据'),
                      ),
                      PopupMenuItem(
                        value: 'export',
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: BhePalette.orange.withValues(alpha: .13),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                LucideIcons.download,
                                size: 17,
                                color: BhePalette.orange,
                              ),
                              SizedBox(width: 9),
                              Text('导出保留片段'),
                            ],
                          ),
                        ),
                      ),
                    ],
                    icon: const Icon(LucideIcons.ellipsis, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onPlayer,
                    tooltip: candidate.player == null
                        ? '球员标签'
                        : '球员：${candidate.player}',
                    icon: Icon(
                      LucideIcons.tag,
                      color: candidate.player == null
                          ? BhePalette.textSecondary
                          : _playerTagColor(candidate.player!),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onExclude,
                      icon: const Icon(LucideIcons.x, size: 18),
                      label: const Text('不选'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onInclude,
                      icon: const Icon(LucideIcons.check, size: 18),
                      label: const Text('选中'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleMore(String value) {
    switch (value) {
      case 'annotations':
        onToggleAnnotations();
      case 'range':
        onEditRange();
      case 'shortcuts':
        onShortcuts();
      case 'speed_0.5':
        onSpeed(.5);
      case 'speed_1.0':
        onSpeed(1);
      case 'speed_1.5':
        onSpeed(1.5);
      case 'speed_2.0':
        onSpeed(2);
      case 'evidence':
        onDetails();
      case 'export':
        onExport();
    }
  }
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
          Text('还没有候选片段', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            onAddManual == null
                ? '先完成视频分析，结果会自动出现在这里。'
                : '分析没有找到候选，也可以手动补一个片段。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            children: [
              OutlinedButton(
                onPressed: onOpenProject,
                child: const Text('返回项目'),
              ),
              if (onAddManual != null)
                FilledButton.icon(
                  onPressed: onAddManual,
                  icon: const Icon(LucideIcons.plus, size: 17),
                  label: const Text('补漏候选'),
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
    title: '候选判断依据',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '#${candidate.id}  ·  ${candidate.displayTime}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 14),
        _EvidenceRow(
          label: '综合置信度',
          value: '${(candidate.confidence * 100).toStringAsFixed(0)}%',
        ),
        _EvidenceRow(label: '轨迹分数', value: _score(candidate.trajectoryScore)),
        _EvidenceRow(label: '穿框分数', value: _score(candidate.crossingScore)),
        _EvidenceRow(label: '篮网运动', value: _score(candidate.netMotionScore)),
        if (candidate.verdict != null)
          _EvidenceRow(label: '算法结论', value: _verdictLabel(candidate.verdict!)),
        if (candidate.reason != null)
          _EvidenceRow(label: '审核提示', value: _reasonLabel(candidate.reason!)),
        if (candidate.trajectory.isNotEmpty)
          _EvidenceRow(label: '轨迹点', value: '${candidate.trajectory.length} 个'),
        const Divider(height: 24),
        Text('颜色说明', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const _LegendDot(color: BhePalette.green, text: '绿色：当前候选的有效检测点/通过信号'),
        const SizedBox(height: 6),
        const _LegendDot(color: BhePalette.orange, text: '橙色：篮筐区域或推定穿框点'),
        const SizedBox(height: 12),
        Text(
          '最终是否保留由你审核决定，算法结果只是候选建议。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _showNoteEditor(context),
          icon: const Icon(LucideIcons.notebookPen, size: 17),
          label: Text(candidate.note == null ? '写备注' : '编辑备注'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _showPlayerEditor(context),
          icon: const Icon(LucideIcons.tag, size: 17),
          label: Text(
            candidate.player == null ? '选择球员标签' : '球员：${candidate.player}',
          ),
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
      state.updateCandidateNote(candidate.id, value);
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
      title: '备注',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _input,
            autofocus: true,
            maxLines: 4,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: '记录这个候选的情况',
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
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => _close(_input.text),
                  child: const Text('保存备注'),
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

class _PlayerChoiceChip extends StatelessWidget {
  const _PlayerChoiceChip({
    required this.player,
    required this.selected,
    required this.onSelected,
    this.onDeleted,
  });
  final String player;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final color = _playerTagColor(player);
    return InputChip(
      label: Text(player),
      selected: selected,
      onSelected: onSelected,
      onDeleted: onDeleted,
      deleteIcon: onDeleted == null
          ? null
          : const Icon(LucideIcons.x, size: 15),
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
  final value = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _PlayerTagSheet(
      players: state.project.players,
      initialPlayer: candidate.player,
      onRemovePlayer: state.removePlayer,
    ),
  );
  if (value == null || !context.mounted) return;
  final normalized = value.trim();
  if (normalized.isEmpty) {
    state.setCandidatePlayer(candidate.id, null);
  } else {
    state.addPlayer(normalized);
    state.setCandidatePlayer(candidate.id, normalized);
  }
}

class _PlayerTagSheet extends StatefulWidget {
  const _PlayerTagSheet({
    required this.players,
    required this.onRemovePlayer,
    this.initialPlayer,
  });
  final List<String> players;
  final String? initialPlayer;
  final ValueChanged<String> onRemovePlayer;

  @override
  State<_PlayerTagSheet> createState() => _PlayerTagSheetState();
}

class _PlayerTagSheetState extends State<_PlayerTagSheet> {
  late final TextEditingController _input;
  late List<String> _players;
  String? _selected;
  bool _creating = false;
  bool _managing = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialPlayer;
    _players = [...widget.players];
    _input = TextEditingController();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _close(String value) {
    if (mounted) Navigator.of(context).pop(value);
  }

  void _removePlayer(String player) {
    setState(() {
      _players = _players.where((item) => item != player).toList();
      if (_selected == player) _selected = null;
    });
    widget.onRemovePlayer(player);
  }

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOut,
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _SheetFrame(
      title: '球员标签',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_players.isEmpty)
            Text('还没有球员标签。', style: Theme.of(context).textTheme.bodySmall)
          else ...[
            Row(
              children: [
                Text('选择球员', style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _managing = !_managing),
                  icon: Icon(
                    _managing ? LucideIcons.check : LucideIcons.settings2,
                    size: 15,
                  ),
                  label: Text(_managing ? '完成管理' : '管理'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final player in _players)
                  _PlayerChoiceChip(
                    player: player,
                    selected: _selected == player,
                    onDeleted: _managing ? () => _removePlayer(player) : null,
                    onSelected: (value) {
                      if (!mounted) return;
                      setState(() {
                        _selected = value ? player : null;
                        _input.clear();
                      });
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          if (_creating)
            TextField(
              controller: _input,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '新建球员标签',
                hintText: '例如 #10 Kobe',
                prefixIcon: Icon(LucideIcons.tag, size: 18),
              ),
              onChanged: (value) {
                final next = value.trim().isEmpty ? null : value.trim();
                if (_selected != next) setState(() => _selected = next);
              },
              onSubmitted: (value) => _close(value.trim()),
            )
          else
            OutlinedButton.icon(
              onPressed: () => setState(() => _creating = true),
              icon: const Icon(LucideIcons.plus, size: 17),
              label: const Text('新建球员标签'),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _close(''),
                  child: const Text('清除标签'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => _close(_selected ?? _input.text.trim()),
                  child: const Text('应用标签'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
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

class _ExportView extends StatefulWidget {
  const _ExportView({required this.state});
  final MobileAppState state;

  @override
  State<_ExportView> createState() => _ExportViewState();
}

class _ExportViewState extends State<_ExportView> {
  String? selectedPlayer;

  MobileAppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    final included = state.project.candidates
        .where((item) => item.selection == CandidateSelection.included)
        .toList();
    final duration = included.fold<int>(
      0,
      (sum, item) => sum + item.duration.inMilliseconds,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
          children: [
            const _PageIntro(
              eyebrow: 'EXPORT',
              title: '导出集锦',
              subtitle: '只导出当前选中的候选片段。',
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: _Metric(
                        label: '保留片段',
                        value: '${included.length} 个',
                      ),
                    ),
                    Expanded(
                      child: _Metric(label: '总时长', value: _formatMs(duration)),
                    ),
                    Expanded(
                      child: _Metric(label: '输出', value: 'MP4'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (state.project.players.isNotEmpty) ...[
              _SectionHeader(title: '按球员导出', action: '可选'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final player in state.project.players)
                    _PlayerChoiceChip(
                      player: player,
                      selected: selectedPlayer == player,
                      onSelected: state.exporting
                          ? (_) {}
                          : (selected) => setState(
                              () => selectedPlayer = selected ? player : null,
                            ),
                    ),
                ],
              ),
              if (selectedPlayer != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: state.exporting
                        ? null
                        : () => unawaited(
                            state.exportClipsForPlayer(selectedPlayer),
                          ),
                    icon: Icon(
                      LucideIcons.download,
                      size: 18,
                      color: Colors.white,
                    ),
                    label: Text('导出 $selectedPlayer 的片段'),
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '输出方式',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '当前移动端使用原视频分别导出，保留原始音频。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: state.exporting
                            ? null
                            : () => unawaited(state.exportClips()),
                        icon: const Icon(LucideIcons.files, size: 18),
                        label: const Text('分别导出全部'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: null,
                        icon: const Icon(LucideIcons.merge, size: 18),
                        label: const Text('合并导出（即将支持）'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (state.exporting) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.progressMessage,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: state.progress.clamp(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (state.exportedPaths.isNotEmpty) ...[
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已导出 ${state.exportedPaths.length} 个片段',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  unawaited(state.shareExportedFiles()),
                              icon: const Icon(LucideIcons.share2, size: 17),
                              label: const Text('分享'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () =>
                                  unawaited(state.saveExportedFiles()),
                              icon: const Icon(LucideIcons.save, size: 17),
                              label: const Text('保存到相册'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (state.errorMessage != null) ...[
              const SizedBox(height: 12),
              _InlineNotice(message: state.errorMessage!, error: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 5),
      Text(value, style: Theme.of(context).textTheme.titleMedium),
    ],
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
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
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '返回上一步',
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
      title: '分析质量',
      child: Column(
        children: [
          _ChoiceRow(
            title: '标准',
            subtitle: '640×480 / 3fps，速度和质量平衡',
            selected: current.mode == AnalysisMode.standard,
            onTap: () => Navigator.pop(context, AnalysisMode.standard),
          ),
          _ChoiceRow(
            title: '高质量',
            subtitle: '960×720 / 5fps，更慢且更耗电',
            selected: current.mode == AnalysisMode.highQuality,
            onTap: () => Navigator.pop(context, AnalysisMode.highQuality),
          ),
        ],
      ),
    ),
  );
  if (value != null) {
    state.updateSettings(
      AnalysisSettings(
        mode: value,
        clip: current.clip,
        startMs: current.startMs,
        endMs: current.endMs,
      ),
    );
  }
}

Future<void> _showClipSheet(BuildContext context, MobileAppState state) async {
  final current = state.project.settings;
  var before = current.clip.beforeSeconds.toDouble();
  var after = current.clip.afterSeconds.toDouble();
  final value = await showModalBottomSheet<ClipSettings>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => _SheetFrame(
        title: '片段时长',
        child: Column(
          children: [
            Text(
              '${before.round()} 秒前 + ${after.round()} 秒后',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 56, child: Text('进球前')),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(trackHeight: 5),
                    child: Slider(
                      min: 0,
                      max: 15,
                      divisions: 15,
                      value: before,
                      onChanged: (value) => setSheetState(() => before = value),
                    ),
                  ),
                ),
                SizedBox(width: 44, child: Text('${before.round()} 秒')),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 56, child: Text('进球后')),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(trackHeight: 5),
                    child: Slider(
                      min: 0,
                      max: 15,
                      divisions: 15,
                      value: after,
                      onChanged: (value) => setSheetState(() => after = value),
                    ),
                  ),
                ),
                SizedBox(width: 44, child: Text('${after.round()} 秒')),
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
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    ),
  );
  if (value != null) {
    state.updateSettings(
      AnalysisSettings(
        mode: current.mode,
        clip: value,
        startMs: current.startMs,
        endMs: current.endMs,
      ),
    );
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
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => _SheetFrame(
        title: '分析范围',
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: _VideoPreview(
                path: video.path,
                aspectRatio: video.width / video.height,
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
                  child: const Text('使用全片'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(context, (
                    start: start.round(),
                    end: end.round(),
                  )),
                  child: const Text('完成'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '跳过热身或无关片段，修改会自动保存。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
  if (value != null) {
    state.updateSettings(
      AnalysisSettings(
        mode: current.mode,
        clip: current.clip,
        startMs: value.start,
        endMs: value.end,
      ),
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
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
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
      net: state.project.netRoi,
    ),
  );
  if (result != null) state.updateRois(hoop: result.hoop, net: result.net);
}

class _RoiEditorSheet extends StatefulWidget {
  const _RoiEditorSheet({required this.video, this.hoop, this.net});
  final VideoInfo video;
  final Roi? hoop;
  final Roi? net;

  @override
  State<_RoiEditorSheet> createState() => _RoiEditorSheetState();
}

class _RoiEditorSheetState extends State<_RoiEditorSheet> {
  VideoPlayerController? controller;
  late Roi hoop;
  late Roi net;
  String selected = 'hoop';
  double viewZoom = 1;
  double _gestureStartZoom = 1;
  bool _redrawMode = false;
  Offset? _drawStart;
  Offset? _drawEnd;

  @override
  void initState() {
    super.initState();
    hoop =
        widget.hoop ?? const Roi(left: .34, top: .25, right: .66, bottom: .48);
    net = widget.net ?? const Roi(left: .37, top: .42, right: .63, bottom: .72);
    controller = VideoPlayerController.file(File(widget.video.path))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = selected == 'hoop' ? hoop : net;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .92,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('设置检测区域', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      selected == 'hoop' ? '篮筐框住篮圈' : '篮网框住白色网面',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, (hoop: hoop, net: net)),
                    child: const Text('完成'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'hoop',
                    label: Text('篮筐区域'),
                    icon: Icon(LucideIcons.circle),
                  ),
                  ButtonSegment(
                    value: 'net',
                    label: Text('篮网区域'),
                    icon: Icon(LucideIcons.network),
                  ),
                ],
                selected: {selected},
                onSelectionChanged: (value) => setState(() {
                  selected = value.first;
                  _redrawMode = false;
                  _drawStart = null;
                  _drawEnd = null;
                }),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final ratio = widget.video.width / widget.video.height;
                    return ClipRect(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: ratio,
                          child: LayoutBuilder(
                            builder: (context, canvasConstraints) {
                              final canvasSize = canvasConstraints.biggest;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onScaleStart: (details) {
                                  if (_redrawMode) {
                                    final point = _clampPoint(
                                      details.localFocalPoint,
                                      canvasSize,
                                    );
                                    setState(() {
                                      _drawStart = point;
                                      _drawEnd = point;
                                    });
                                  } else {
                                    _gestureStartZoom = viewZoom;
                                  }
                                },
                                onScaleUpdate: (details) {
                                  if (_redrawMode) {
                                    setState(() {
                                      _drawEnd = _clampPoint(
                                        details.localFocalPoint,
                                        canvasSize,
                                      );
                                    });
                                  } else if ((details.scale - 1).abs() > .015) {
                                    setState(() {
                                      viewZoom =
                                          (_gestureStartZoom * details.scale)
                                              .clamp(1.0, 4.0);
                                    });
                                  } else {
                                    _updateRoi(
                                      details.focalPointDelta,
                                      1,
                                      canvasSize,
                                    );
                                  }
                                },
                                onScaleEnd: (_) {
                                  if (_redrawMode &&
                                      _drawStart != null &&
                                      _drawEnd != null) {
                                    _finishRedraw(canvasSize);
                                  }
                                },
                                child: Transform.scale(
                                  scale: viewZoom,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ColoredBox(
                                        color: Colors.black,
                                        child:
                                            controller?.value.isInitialized ==
                                                true
                                            ? VideoPlayer(controller!)
                                            : const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              ),
                                      ),
                                      CustomPaint(
                                        painter: _RoiPainter(
                                          hoop: hoop,
                                          net: net,
                                          selected: selected,
                                          redrawStart: _drawStart,
                                          redrawEnd: _drawEnd,
                                        ),
                                      ),
                                      if (!_redrawMode)
                                        for (final corner in const [
                                          'topLeft',
                                          'topRight',
                                          'bottomLeft',
                                          'bottomRight',
                                        ])
                                          _RoiHandle(
                                            key: ValueKey(corner),
                                            corner: corner,
                                            roi: current,
                                            size: canvasSize,
                                            onDrag: (delta) => _resizeRoi(
                                              corner,
                                              delta,
                                              canvasSize,
                                            ),
                                          ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                runSpacing: 2,
                children: [
                  IconButton(
                    onPressed: viewZoom <= 1
                        ? null
                        : () => setState(
                            () => viewZoom = (viewZoom - .5).clamp(1.0, 4.0),
                          ),
                    icon: const Icon(LucideIcons.minus),
                    tooltip: '缩小画面',
                  ),
                  SizedBox(
                    width: 56,
                    height: 40,
                    child: Center(
                      child: Text('${viewZoom.toStringAsFixed(1)}×'),
                    ),
                  ),
                  IconButton(
                    onPressed: viewZoom >= 4
                        ? null
                        : () => setState(
                            () => viewZoom = (viewZoom + .5).clamp(1.0, 4.0),
                          ),
                    icon: const Icon(LucideIcons.plus),
                    tooltip: '放大画面',
                  ),
                  TextButton(
                    onPressed: () => setState(() => viewZoom = 1),
                    child: const Text('复位'),
                  ),
                  TextButton.icon(
                    onPressed: _redrawMode
                        ? () => setState(() {
                            _redrawMode = false;
                            _drawStart = null;
                            _drawEnd = null;
                          })
                        : _startRedraw,
                    icon: Icon(
                      _redrawMode
                          ? LucideIcons.penLine
                          : LucideIcons.squareDashed,
                      size: 16,
                    ),
                    label: Text(_redrawMode ? '拖动重画中' : '重新画框'),
                  ),
                  TextButton(
                    onPressed: _resetSelectedRoi,
                    child: const Text('重置当前'),
                  ),
                ],
              ),
              Text(
                _redrawMode
                    ? '拖动出一个新矩形来重新设置当前区域。'
                    : '拖动框角调整大小，拖动画面移动区域；双指捏合放大画面。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                '当前区域 ${(current.right - current.left).toStringAsFixed(2)} × ${(current.bottom - current.top).toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Offset _clampPoint(Offset point, Size size) => Offset(
    point.dx.clamp(0.0, size.width).toDouble(),
    point.dy.clamp(0.0, size.height).toDouble(),
  );

  void _startRedraw() {
    setState(() {
      _redrawMode = true;
      _drawStart = null;
      _drawEnd = null;
      viewZoom = 1;
    });
  }

  void _finishRedraw(Size size) {
    final start = _drawStart;
    final end = _drawEnd;
    if (start == null || end == null) return;
    final left = (start.dx < end.dx ? start.dx : end.dx) / size.width;
    final top = (start.dy < end.dy ? start.dy : end.dy) / size.height;
    final right = (start.dx > end.dx ? start.dx : end.dx) / size.width;
    final bottom = (start.dy > end.dy ? start.dy : end.dy) / size.height;
    if (right - left < .05 || bottom - top < .05) return;
    final next = Roi(
      left: left.clamp(0.0, .95).toDouble(),
      top: top.clamp(0.0, .95).toDouble(),
      right: right.clamp(.05, 1.0).toDouble(),
      bottom: bottom.clamp(.05, 1.0).toDouble(),
    );
    setState(() {
      if (selected == 'hoop') {
        hoop = next;
      } else {
        net = next;
      }
      _redrawMode = false;
      _drawStart = null;
      _drawEnd = null;
    });
  }

  void _resetSelectedRoi() {
    setState(() {
      if (selected == 'hoop') {
        hoop = const Roi(left: .34, top: .25, right: .66, bottom: .48);
      } else {
        net = const Roi(left: .37, top: .42, right: .63, bottom: .72);
      }
      _redrawMode = false;
      _drawStart = null;
      _drawEnd = null;
    });
  }

  void _resizeRoi(String corner, Offset delta, Size size) {
    final value = selected == 'hoop' ? hoop : net;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    const minimum = .05;
    var left = value.left;
    var top = value.top;
    var right = value.right;
    var bottom = value.bottom;
    switch (corner) {
      case 'topLeft':
        left = (left + dx).clamp(0.0, right - minimum).toDouble();
        top = (top + dy).clamp(0.0, bottom - minimum).toDouble();
      case 'topRight':
        right = (right + dx).clamp(left + minimum, 1.0).toDouble();
        top = (top + dy).clamp(0.0, bottom - minimum).toDouble();
      case 'bottomLeft':
        left = (left + dx).clamp(0.0, right - minimum).toDouble();
        bottom = (bottom + dy).clamp(top + minimum, 1.0).toDouble();
      case 'bottomRight':
        right = (right + dx).clamp(left + minimum, 1.0).toDouble();
        bottom = (bottom + dy).clamp(top + minimum, 1.0).toDouble();
    }
    final next = Roi(left: left, top: top, right: right, bottom: bottom);
    setState(() {
      if (selected == 'hoop') {
        hoop = next;
      } else {
        net = next;
      }
    });
  }

  void _updateRoi(Offset delta, double scale, Size size) {
    final value = selected == 'hoop' ? hoop : net;
    final width = value.right - value.left;
    final height = value.bottom - value.top;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    var nextWidth = (width / scale).clamp(.08, .92);
    var nextHeight = (height / scale).clamp(.08, .92);
    var left = (value.left + dx + (width - nextWidth) / 2).clamp(
      0.0,
      1.0 - nextWidth,
    );
    var top = (value.top + dy + (height - nextHeight) / 2).clamp(
      0.0,
      1.0 - nextHeight,
    );
    final next = Roi(
      left: left,
      top: top,
      right: left + nextWidth,
      bottom: top + nextHeight,
    );
    setState(() {
      if (selected == 'hoop') {
        hoop = next;
      } else {
        net = next;
      }
    });
  }
}

class _RoiHandle extends StatelessWidget {
  const _RoiHandle({
    super.key,
    required this.corner,
    required this.roi,
    required this.size,
    required this.onDrag,
  });
  final String corner;
  final Roi roi;
  final Size size;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    final point = switch (corner) {
      'topLeft' => Offset(roi.left * size.width, roi.top * size.height),
      'topRight' => Offset(roi.right * size.width, roi.top * size.height),
      'bottomLeft' => Offset(roi.left * size.width, roi.bottom * size.height),
      _ => Offset(roi.right * size.width, roi.bottom * size.height),
    };
    return Positioned(
      left: point.dx - 14,
      top: point.dy - 14,
      width: 28,
      height: 28,
      child: GestureDetector(
        onPanUpdate: (details) => onDrag(details.delta),
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: BhePalette.orange,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoiPainter extends CustomPainter {
  const _RoiPainter({
    required this.hoop,
    required this.net,
    required this.selected,
    this.redrawStart,
    this.redrawEnd,
  });
  final Roi hoop;
  final Roi net;
  final String selected;
  final Offset? redrawStart;
  final Offset? redrawEnd;

  @override
  void paint(Canvas canvas, Size size) {
    void draw(Roi roi, Color color, String label, bool active) {
      final rect = Rect.fromLTRB(
        roi.left * size.width,
        roi.top * size.height,
        roi.right * size.width,
        roi.bottom * size.height,
      );
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 1.5 : 1;
      canvas.drawRect(rect, paint);
      final text = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: color, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      const horizontalPadding = 5.0;
      const verticalPadding = 3.0;
      final labelWidth = text.width + horizontalPadding * 2;
      final labelHeight = text.height + verticalPadding * 2;
      final labelX = rect.left.clamp(0.0, size.width - labelWidth).toDouble();
      final preferredY = label == '篮网'
          ? rect.bottom + 6
          : rect.top - labelHeight - 6;
      final labelY = preferredY >= 0 && preferredY + labelHeight <= size.height
          ? preferredY
          : preferredY < 0
          ? (rect.bottom + 6).clamp(0.0, size.height - labelHeight).toDouble()
          : (rect.top - labelHeight - 6)
                .clamp(0.0, size.height - labelHeight)
                .toDouble();
      final background = RRect.fromRectAndRadius(
        Rect.fromLTWH(labelX, labelY, labelWidth, labelHeight),
        const Radius.circular(3),
      );
      canvas.drawRRect(
        background,
        Paint()..color = Colors.black.withValues(alpha: .82),
      );
      text.paint(
        canvas,
        Offset(labelX + horizontalPadding, labelY + verticalPadding),
      );
    }

    draw(hoop, BhePalette.orange, '篮筐', selected == 'hoop');
    draw(net, BhePalette.gold, '篮网', selected == 'net');
    if (redrawStart != null && redrawEnd != null) {
      canvas.drawRect(
        Rect.fromPoints(redrawStart!, redrawEnd!),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_RoiPainter oldDelegate) =>
      oldDelegate.hoop != hoop ||
      oldDelegate.net != net ||
      oldDelegate.selected != selected ||
      oldDelegate.redrawStart != redrawStart ||
      oldDelegate.redrawEnd != redrawEnd;
}

String _score(double? value) =>
    value == null ? '—' : '${(value * 100).toStringAsFixed(0)}%';

String _formatMs(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}
