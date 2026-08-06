import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core/engine_client.dart';
import 'core/engine_session.dart';
import 'core/project_session.dart';
import 'features/export/export_screen.dart';
import 'features/home/home_screen.dart';
import 'features/import_video/import_video_screen.dart';
import 'features/review/review_screen.dart';

enum AppSection { home, importVideo, review, export }

class BasketballHighlightApp extends StatefulWidget {
  const BasketballHighlightApp({
    this.enableStartupProjectScan = true,
    super.key,
  });

  final bool enableStartupProjectScan;

  @override
  State<BasketballHighlightApp> createState() => _BasketballHighlightAppState();
}

class _BasketballHighlightAppState extends State<BasketballHighlightApp> {
  static const background = Color(0xFF0A1017);
  static const surface = Color(0xFF121A23);
  static const accent = Color(0xFFD97745);

  final EngineClient _engineClient = EngineClient();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  late final ProjectSession _session = ProjectSession(
    EngineSession(_engineClient),
  );

  String? _knownProjectsRoot;
  ThemeMode _themeMode = ThemeMode.system;
  AppSection _section = AppSection.home;
  String? _videoPath;
  String? _previewPath;
  Rect? _suggestedRoi;
  String? _roiSource;
  double? _roiConfidence;
  String? _roiSuggestionError;
  JsonMap? _video;
  JsonMap? _job;
  List<JsonMap> _candidates = <JsonMap>[];
  List<JsonMap> _recentProjects = <JsonMap>[];
  List<JsonMap> _exportHistory = <JsonMap>[];
  bool _recentProjectsLoading = false;
  String? _recentProjectsError;
  String? _error;
  bool _engineReady = false;
  bool _busy = false;

  String get _projectsRoot {
    final configured = Platform.environment['BHE_PROJECTS_ROOT'];
    if (configured != null && configured.trim().isNotEmpty) {
      return configured;
    }
    final current = _knownProjectsRoot;
    if (current != null && current.isNotEmpty) return current;
    final home = Platform.environment['HOME'];
    return '${home ?? Directory.current.path}/Movies/BasketballProjects';
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: isDark ? surface : const Color(0xFFF7F8FA),
    );
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: isDark ? background : const Color(0xFFF7F8FA),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.8,
          height: 1.1,
        ),
        headlineMedium: TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5,
          height: 1.15,
        ),
        titleLarge: TextStyle(fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(height: 1.45),
        bodyMedium: TextStyle(height: 1.45),
        labelLarge: TextStyle(fontWeight: FontWeight.w500),
      ),
      cardTheme: CardThemeData(
        color: isDark ? surface : Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: isDark ? const Color(0xFF263442) : const Color(0xFFE5E8ED),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? surface : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? const Color(0xFF263442) : const Color(0xFFE5E8ED),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.all(20),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_engineClient.dispose());
    super.dispose();
  }

  Future<void> _ensureEngine() async {
    if (_engineReady) return;
    final runtimeRoot = _findRuntimeRoot();
    if (runtimeRoot == null) {
      throw const SessionStateException(
        '未找到本地 Engine 运行目录。开发环境请从项目根目录启动，正式版本请先完成运行时打包。',
      );
    }
    final pythonPath = _findPython(runtimeRoot);
    final runtimeBin = Directory('$runtimeRoot/bin').existsSync()
        ? '$runtimeRoot/bin'
        : null;
    await _engineClient.start(
      workingDirectory: runtimeRoot,
      enginePythonPath: '$runtimeRoot/engine/python',
      pythonExecutable: pythonPath,
      extraPath: runtimeBin,
    );
    await _session.engine.hello();
    if (mounted) setState(() => _engineReady = true);
  }

  String? _findRuntimeRoot() {
    final configured = Platform.environment['BHE_REPO_ROOT'];
    final configuredRuntime = Platform.environment['BHE_RUNTIME_ROOT'];
    final executable = File(Platform.resolvedExecutable);
    final appContents = executable.parent.parent;
    final candidates = <String>[
      if (configuredRuntime != null && configuredRuntime.isNotEmpty)
        configuredRuntime,
      if (configured != null && configured.isNotEmpty) configured,
      '${appContents.path}/Resources/runtime',
      Directory.current.path,
      Directory.current.parent.path,
      '/Users/macmima1234/basketball-highlight-editor',
    ];
    for (final path in candidates) {
      if (Directory('$path/engine/python').existsSync()) return path;
    }
    return null;
  }

  String _findPython(String runtimeRoot) {
    final configured = Platform.environment['BHE_PYTHON'];
    final candidates = <String>[
      if (configured != null && configured.isNotEmpty) configured,
      '$runtimeRoot/python/bin/python3',
      '$runtimeRoot/.venv/bin/python',
      '$runtimeRoot/.venv/bin/python3',
    ];
    for (final path in candidates) {
      if (File(path).existsSync() || !path.contains(Platform.pathSeparator)) {
        return path;
      }
    }
    if (Platform.environment['BHE_ALLOW_SYSTEM_PYTHON'] == '1') {
      return 'python3';
    }
    throw const SessionStateException(
      '未找到 Python 运行时。请设置 BHE_PYTHON，或把 Python 放入应用运行时目录。',
    );
  }

  Future<void> _selectVideo(String path) async {
    await _runBusy(() async {
      await _ensureEngine();
      final source = File(path).absolute;
      final stem = source.uri.pathSegments.last.replaceFirst(
        RegExp(r'\.[^.]+$'),
        '',
      );
      _knownProjectsRoot ??= _projectsRoot;
      final projectRoot =
          '$_knownProjectsRoot/$stem-${DateTime.now().millisecondsSinceEpoch}';
      await _session.createProject(name: stem, rootPath: projectRoot);
      final linked = await _session.linkVideo(path);
      final duration =
          ((linked['video'] as Map?)?['duration_ms'] as num?)?.toInt() ?? 1000;
      final preview = await _session.extractPreview(
        timeMs: duration > 1000 ? 1000 : duration,
      );
      Rect? suggestedRoi;
      String? roiSource;
      double? roiConfidence;
      String? roiSuggestionError;
      try {
        final suggestion = await _session.suggestRoi(
          duration: 20,
          sampleFps: 1,
          maxSamples: 12,
          confidence: 0.05,
        );
        final roi = (suggestion['roi'] as Map?)?.cast<String, dynamic>();
        final linkedVideo = (linked['video'] as Map?)?.cast<String, dynamic>();
        if (roi != null && linkedVideo != null) {
          suggestedRoi = _normalizeRoi(roi, linkedVideo);
          final calibration = (suggestion['calibration'] as Map?)
              ?.cast<String, dynamic>();
          await _session.saveRoi(
            x1: roi['x1'] as num,
            y1: roi['y1'] as num,
            x2: roi['x2'] as num,
            y2: roi['y2'] as num,
            calibration: calibration,
          );
          roiSource = 'auto';
          roiConfidence = (calibration?['confidence'] as num?)?.toDouble();
        }
      } catch (error) {
        // Automatic ROI is a convenience. A failed suggestion must not block
        // importing the video; the user can draw a manual region instead.
        roiSuggestionError = error.toString();
      }
      setState(() {
        _videoPath = path;
        _previewPath = preview['path']?.toString();
        _suggestedRoi = suggestedRoi;
        _roiSource = roiSource;
        _roiConfidence = roiConfidence;
        _roiSuggestionError = roiSuggestionError;
        _video = (linked['video'] as Map?)?.cast<String, dynamic>();
        _job = null;
        _candidates = <JsonMap>[];
        _exportHistory = <JsonMap>[];
        _section = AppSection.importVideo;
      });
    }, successMessage: '视频已加载，已优先尝试自动识别篮筐区域');
  }

  Future<void> _chooseOpenProject() async {
    final root = await getDirectoryPath(confirmButtonText: '打开项目');
    if (root != null) await _openProject(root);
  }

  Future<void> _openProject(String root) async {
    await _runBusy(() async {
      await _ensureEngine();
      final payload = await _session.openProject(root);
      final video = (payload['video'] as Map?)?.cast<String, dynamic>();
      String? previewPath;
      if (video?['id'] is String) {
        try {
          final duration = (video?['duration_ms'] as num?)?.toInt() ?? 1000;
          final preview = await _session.extractPreview(
            timeMs: duration > 1000 ? 1000 : duration,
          );
          previewPath = preview['path']?.toString();
        } catch (_) {
          previewPath = null;
        }
      }
      setState(() {
        _knownProjectsRoot = Directory(root).parent.path;
        _video = video;
        _videoPath = video?['source_path']?.toString();
        _previewPath = previewPath;
        _suggestedRoi = null;
        _roiSource = null;
        _roiConfidence = null;
        _roiSuggestionError = null;
        _job = null;
        _section = video == null ? AppSection.home : AppSection.review;
      });
      if (video != null) {
        await _refreshCandidates();
        await _refreshExportHistory();
        await _restoreActiveJob();
      }
    });
  }

  Future<void> _loadRecentProjects() async {
    if (!mounted) return;
    setState(() {
      _recentProjectsLoading = true;
      _recentProjectsError = null;
    });
    try {
      await _ensureEngine();
      final projects = await _session.loadRecentProjects(
        knownRoot: _projectsRoot,
      );
      if (mounted) setState(() => _recentProjects = projects);
    } catch (error) {
      if (mounted) setState(() => _recentProjectsError = error.toString());
    } finally {
      if (mounted) setState(() => _recentProjectsLoading = false);
    }
  }

  Future<void> _saveRoi(Rect normalized) async {
    await _runBusy(() async {
      final video = _video;
      if (video == null) throw const SessionStateException('视频元数据尚未准备好');
      final width = (video['width'] as num?)?.toDouble() ?? 0;
      final height = (video['height'] as num?)?.toDouble() ?? 0;
      if (width <= 0 || height <= 0) {
        throw const SessionStateException('视频分辨率无效');
      }
      await _session.saveRoi(
        x1: normalized.left * width,
        y1: normalized.top * height,
        x2: normalized.right * width,
        y2: normalized.bottom * height,
        calibration: const <String, dynamic>{'source': 'manual'},
      );
      if (mounted) {
        setState(() {
          _roiSource = 'manual';
          _roiConfidence = null;
          _roiSuggestionError = null;
        });
      }
    }, successMessage: '篮筐区域已保存');
  }

  Rect _normalizeRoi(Map<String, dynamic> roi, Map<String, dynamic> video) {
    final width = (video['width'] as num?)?.toDouble() ?? 1;
    final height = (video['height'] as num?)?.toDouble() ?? 1;
    final x1 = (roi['x1'] as num?)?.toDouble() ?? 0;
    final y1 = (roi['y1'] as num?)?.toDouble() ?? 0;
    final x2 = (roi['x2'] as num?)?.toDouble() ?? width;
    final y2 = (roi['y2'] as num?)?.toDouble() ?? height;
    return Rect.fromLTRB(
      (x1 / width).clamp(0.0, 1.0).toDouble(),
      (y1 / height).clamp(0.0, 1.0).toDouble(),
      (x2 / width).clamp(0.0, 1.0).toDouble(),
      (y2 / height).clamp(0.0, 1.0).toDouble(),
    );
  }

  Future<void> _startAnalysis() async {
    await _runBusy(() async {
      final activeJobs = await _session.getActiveJobs();
      if (activeJobs.isNotEmpty) {
        final active = activeJobs.last;
        setState(() {
          _job = active;
          _section = AppSection.review;
        });
        if (active['recovery_state'] == 'worker_attached') {
          final jobId = active['id'];
          if (jobId is String) await _pollJob(jobId);
        }
        return;
      }
      final result = await _session.startAnalysis(
        sampleFps: 10,
        beforeSeconds: 6,
        afterSeconds: 3,
      );
      setState(() {
        _job = (result['job'] as Map?)?.cast<String, dynamic>();
        _section = AppSection.review;
      });
      _showNotice('分析已开始，候选会在处理过程中陆续更新');
      final jobId = _job?['id'];
      if (jobId is! String) return;
      await _pollJob(jobId);
    });
  }

  Future<void> _pollJob(String jobId) async {
    try {
      await for (final payload in _session.pollJob(jobId: jobId)) {
        if (!mounted) return;
        final nextJob = (payload['job'] as Map?)?.cast<String, dynamic>();
        final previousState = _job?['state']?.toString();
        setState(() {
          _job = nextJob;
          if (nextJob?['state'] == 'failed') {
            _error = nextJob?['error_message']?.toString() ?? '分析失败';
          }
        });
        final nextState = nextJob?['state']?.toString();
        if (nextState != previousState) {
          if (nextState == 'completed') {
            _showNotice('分析完成，候选片段已准备好');
          } else if (nextState == 'cancelled') {
            _showNotice('分析已取消');
          } else if (nextState == 'failed') {
            _showNotice(
              nextJob?['error_message']?.toString() ?? '分析失败',
              error: true,
            );
          }
        }
      }
      await _refreshCandidates();
      await _refreshExportHistory();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _restoreActiveJob() async {
    final jobs = await _session.getActiveJobs();
    if (!mounted || jobs.isEmpty) return;
    final active = jobs.last;
    setState(() => _job = active);
    if (active['recovery_state'] == 'worker_attached' &&
        active['id'] is String) {
      unawaited(_pollJob(active['id'] as String));
    }
  }

  Future<void> _retryAnalysis() async {
    final jobId = _job?['id'];
    if (jobId is! String) return;
    await _runBusy(() async {
      final result = await _session.retryAnalysis(
        jobId: jobId,
        sampleFps: 10,
        beforeSeconds: 6,
        afterSeconds: 3,
      );
      setState(() => _job = (result['job'] as Map?)?.cast<String, dynamic>());
      _showNotice('已重新开始分析');
      final newJobId = _job?['id'];
      if (newJobId is String) await _pollJob(newJobId);
    });
  }

  Future<void> _cancelAnalysis() async {
    final jobId = _job?['id'];
    if (jobId is! String) return;
    try {
      final result = await _session.cancelJob(jobId: jobId);
      if (mounted) {
        setState(() => _job = (result['job'] as Map?)?.cast<String, dynamic>());
        _showNotice('分析已取消');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _refreshCandidates() async {
    final payload = await _session.listCandidates();
    if (!mounted) return;
    setState(() {
      _candidates = (payload['candidates'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
    });
  }

  Future<void> _reviewCandidate(String id, String status) async {
    await _runBusy(() async {
      await _session.reviewCandidate(id, status: status);
      await _refreshCandidates();
    }, successMessage: status == 'goal' ? '已确认进球' : '已排除候选');
  }

  Future<void> _updateClipRange(String id, int startMs, int endMs) async {
    await _runBusy(() async {
      await _session.updateClipRange(
        candidateId: id,
        startMs: startMs,
        endMs: endMs,
      );
      await _refreshCandidates();
    }, successMessage: '片段范围已更新');
  }

  Future<void> _export(
    String mode, {
    String? outputDir,
    String? outputPath,
  }) async {
    await _runBusy(() async {
      final result = await _session.exportClips(
        mode: mode,
        outputDir: outputDir,
        outputPath: outputPath,
      );
      if (!mounted) return;
      await _refreshExportHistory();
      if (!mounted) return;
      final files = (result['files'] as List? ?? const <dynamic>[]).join('\n');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出完成\n$files')));
    });
  }

  Future<void> _refreshExportHistory() async {
    final history = await _session.listExports(limit: 5);
    if (mounted) setState(() => _exportHistory = history);
  }

  void _showNotice(String message, {bool error = false}) {
    if (!mounted || message.trim().isEmpty) return;
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: error
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.inverseSurface,
          content: Row(
            children: [
              Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                color: error
                    ? Theme.of(context).colorScheme.onError
                    : Theme.of(context).colorScheme.onInverseSurface,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (successMessage != null) _showNotice(successMessage);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
        _showNotice(error.toString(), error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(AppSection section) => setState(() => _section = section);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Basketball Highlight Editor',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _themeMode,
      home: AppShell(
        section: _section,
        themeMode: _themeMode,
        videoPath: _videoPath,
        previewPath: _previewPath,
        suggestedRoi: _suggestedRoi,
        roiSource: _roiSource,
        roiConfidence: _roiConfidence,
        roiSuggestionError: _roiSuggestionError,
        video: _video,
        job: _job,
        candidates: _candidates,
        engineReady: _engineReady,
        busy: _busy,
        error: _error,
        onDismissError: () => setState(() => _error = null),
        onSectionChanged: _open,
        onOpenProject: _chooseOpenProject,
        recentProjects: _recentProjects,
        recentProjectsLoading: _recentProjectsLoading,
        recentProjectsError: _recentProjectsError,
        onLoadRecentProjects: widget.enableStartupProjectScan
            ? _loadRecentProjects
            : null,
        onOpenRecentProject: widget.enableStartupProjectScan
            ? _openProject
            : null,
        onThemeChanged: (mode) => setState(() => _themeMode = mode),
        onVideoSelected: _selectVideo,
        onRoiSaved: _saveRoi,
        onAnalysisStarted: _startAnalysis,
        onCancelAnalysis: _cancelAnalysis,
        onRetryAnalysis: _retryAnalysis,
        onReviewCandidate: _reviewCandidate,
        onUpdateClipRange: _updateClipRange,
        onExport: _export,
        exportHistory: _exportHistory,
      ),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({
    required this.section,
    required this.themeMode,
    required this.videoPath,
    required this.previewPath,
    required this.suggestedRoi,
    required this.roiSource,
    required this.roiConfidence,
    required this.roiSuggestionError,
    required this.video,
    required this.job,
    required this.candidates,
    required this.engineReady,
    required this.busy,
    required this.error,
    required this.onDismissError,
    required this.onSectionChanged,
    required this.onOpenProject,
    required this.recentProjects,
    required this.recentProjectsLoading,
    required this.recentProjectsError,
    required this.onLoadRecentProjects,
    required this.onOpenRecentProject,
    required this.onThemeChanged,
    required this.onVideoSelected,
    required this.onRoiSaved,
    required this.onAnalysisStarted,
    required this.onCancelAnalysis,
    required this.onRetryAnalysis,
    required this.onReviewCandidate,
    required this.onUpdateClipRange,
    required this.onExport,
    required this.exportHistory,
    super.key,
  });

  final AppSection section;
  final ThemeMode themeMode;
  final String? videoPath;
  final String? previewPath;
  final Rect? suggestedRoi;
  final String? roiSource;
  final double? roiConfidence;
  final String? roiSuggestionError;
  final JsonMap? video;
  final JsonMap? job;
  final List<JsonMap> candidates;
  final bool engineReady;
  final bool busy;
  final String? error;
  final VoidCallback onDismissError;
  final ValueChanged<AppSection> onSectionChanged;
  final Future<void> Function() onOpenProject;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Future<void> Function(String) onVideoSelected;
  final Future<void> Function(Rect) onRoiSaved;
  final Future<void> Function() onAnalysisStarted;
  final Future<void> Function() onCancelAnalysis;
  final Future<void> Function() onRetryAnalysis;
  final Future<void> Function(String, String) onReviewCandidate;
  final Future<void> Function(String, int, int) onUpdateClipRange;
  final Future<void> Function(String, {String? outputDir, String? outputPath})
  onExport;
  final List<JsonMap> exportHistory;
  final List<JsonMap> recentProjects;
  final bool recentProjectsLoading;
  final String? recentProjectsError;
  final Future<void> Function()? onLoadRecentProjects;
  final Future<void> Function(String)? onOpenRecentProject;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final extended = constraints.maxWidth >= 1180;
        return Scaffold(
          body: Row(
            children: [
              _Sidebar(
                section: section,
                extended: extended,
                onSectionChanged: onSectionChanged,
              ),
              Expanded(
                child: Column(
                  children: [
                    _TopBar(
                      themeMode: themeMode,
                      engineReady: engineReady,
                      compact: constraints.maxWidth < 900,
                      onThemeChanged: onThemeChanged,
                    ),
                    if (error != null)
                      _ErrorBanner(message: error!, onDismiss: onDismissError),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: _page(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _page(BuildContext context) {
    switch (section) {
      case AppSection.home:
        return HomeScreen(
          key: const ValueKey('home'),
          goalCount: candidates
              .where((item) => item['review_status'] == 'goal')
              .length,
          pendingCount: candidates
              .where((item) => item['review_status'] == 'pending')
              .length,
          videoDurationMs: (video?['duration_ms'] as num?)?.toInt() ?? 0,
          hasProject: video != null,
          onNewProject: () => onSectionChanged(AppSection.importVideo),
          onOpenProject: onOpenProject,
          recentProjects: recentProjects,
          recentProjectsLoading: recentProjectsLoading,
          recentProjectsError: recentProjectsError,
          onLoadRecentProjects: onLoadRecentProjects,
          onOpenRecentProject: onOpenRecentProject,
          onReview: () => onSectionChanged(AppSection.review),
        );
      case AppSection.importVideo:
        return ImportVideoScreen(
          key: const ValueKey('import'),
          videoPath: videoPath,
          previewPath: previewPath,
          initialRoi: suggestedRoi,
          initialRoiSaved: roiSource == 'auto' && suggestedRoi != null,
          roiSource: roiSource,
          roiConfidence: roiConfidence,
          roiSuggestionError: roiSuggestionError,
          video: video,
          busy: busy,
          onVideoSelected: onVideoSelected,
          onRoiSaved: onRoiSaved,
          onAnalysisStarted: onAnalysisStarted,
        );
      case AppSection.review:
        return ReviewScreen(
          key: const ValueKey('review'),
          videoPath: videoPath,
          job: job,
          candidates: candidates,
          busy: busy,
          onCancelAnalysis: onCancelAnalysis,
          onRetryAnalysis: onRetryAnalysis,
          onExport: () => onSectionChanged(AppSection.export),
          onReviewCandidate: onReviewCandidate,
          onUpdateClipRange: onUpdateClipRange,
        );
      case AppSection.export:
        return ExportScreen(
          key: const ValueKey('export'),
          candidates: candidates,
          busy: busy,
          onExport: onExport,
          exportHistory: exportHistory,
          onBackToReview: () => onSectionChanged(AppSection.review),
        );
    }
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            tooltip: '关闭错误提示',
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: scheme.onErrorContainer, size: 18),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.section,
    required this.extended,
    required this.onSectionChanged,
  });
  final AppSection section;
  final bool extended;
  final ValueChanged<AppSection> onSectionChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    const destinations = <(AppSection, String, IconData, IconData)>[
      (AppSection.home, '项目', Icons.grid_view_outlined, Icons.grid_view),
      (
        AppSection.importVideo,
        '导入',
        Icons.file_upload_outlined,
        Icons.file_upload,
      ),
      (
        AppSection.review,
        '审核',
        Icons.view_timeline_outlined,
        Icons.view_timeline,
      ),
      (AppSection.export, '导出', Icons.ios_share_outlined, Icons.ios_share),
    ];
    return Material(
      color: dark ? const Color(0xFF0D151E) : const Color(0xFFF0F2F5),
      child: SafeArea(
        child: SizedBox(
          width: extended ? 232 : 76,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
            child: Column(
              crossAxisAlignment: extended
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: extended ? 10 : 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.sports_basketball,
                          color: colorScheme.onPrimary,
                          size: 21,
                        ),
                      ),
                      if (extended) ...[
                        const SizedBox(width: 10),
                        Text(
                          'COURTSIDE',
                          style: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(letterSpacing: 1.1),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 34),
                for (final destination in destinations)
                  _SidebarItem(
                    label: destination.$2,
                    icon: destination.$3,
                    selectedIcon: destination.$4,
                    selected: section == destination.$1,
                    extended: extended,
                    onTap: () => onSectionChanged(destination.$1),
                  ),
                const Spacer(),
                if (extended)
                  Text(
                    'LOCAL WORKSPACE',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      letterSpacing: 1.2,
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

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Tooltip(
        message: extended ? '' : label,
        child: Material(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 46,
              width: double.infinity,
              child: Row(
                mainAxisAlignment: extended
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 14),
                  Icon(
                    selected ? selectedIcon : icon,
                    color: foreground,
                    size: 20,
                  ),
                  if (extended) ...[
                    const SizedBox(width: 12),
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                  if (!extended) const SizedBox(width: 14),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.themeMode,
    required this.engineReady,
    required this.compact,
    required this.onThemeChanged,
  });
  final ThemeMode themeMode;
  final bool engineReady;
  final bool compact;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: .25),
          ),
        ),
      ),
      child: Row(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('篮球集锦编辑器', style: Theme.of(context).textTheme.titleMedium),
              if (!compact)
                Text(
                  'LOCAL VIDEO WORKSPACE',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.1,
                  ),
                ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: engineReady
                  ? scheme.primaryContainer.withValues(alpha: .55)
                  : scheme.surfaceContainerHighest.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  engineReady
                      ? Icons.check_circle_outline
                      : Icons.circle_outlined,
                  size: 16,
                  color: engineReady ? scheme.primary : scheme.onSurfaceVariant,
                ),
                if (!compact) ...[
                  const SizedBox(width: 6),
                  Text(
                    engineReady ? 'Engine 就绪' : '等待 Engine',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ],
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 10),
            Text(
              '本地处理 · 未上传',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
          ],
          PopupMenuButton<ThemeMode>(
            tooltip: '选择主题',
            initialValue: themeMode,
            onSelected: onThemeChanged,
            icon: Icon(
              isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            ),
            itemBuilder: (context) => const [
              PopupMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
              PopupMenuItem(value: ThemeMode.light, child: Text('浅色主题')),
              PopupMenuItem(value: ThemeMode.dark, child: Text('深色主题')),
            ],
          ),
        ],
      ),
    );
  }
}
