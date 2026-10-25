import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../core/engine_session.dart';
import '../../core/roi_geometry.dart';
import '../../core/video_segments.dart';
import '../../providers/notice_provider.dart';
import '../../providers/pending_import_provider.dart';
import '../../providers/project_state.dart';
import '../../providers/playback_coordinator.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

const _beforeSecondOptions = <int>[0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15];
const _afterSecondOptions = <int>[1, 2, 3, 4, 5, 6, 8, 10, 12, 15];

/// 全页面配置向导：视频 → 分析范围 → 检测区域 → 确认并开始分析。
///
/// 所有编辑先写入 workflowDraft，只有最后一步才写入项目生效配置并启动分析。
class ImportVideoScreen extends ConsumerStatefulWidget {
  const ImportVideoScreen({super.key});

  @override
  ConsumerState<ImportVideoScreen> createState() => _ImportVideoScreenState();
}

class _ImportVideoScreenState extends ConsumerState<ImportVideoScreen> {
  static const _stepCount = 4;
  static const _fastAnalysisEnabled = bool.fromEnvironment(
    'ENABLE_FAST_ANALYSIS',
    defaultValue: true,
  );

  int _step = 0;
  bool _draftLoaded = false;
  bool _applying = false;
  bool _showExistingDraft = false;
  Rect? _roi;
  Rect? _netRoi;
  Rect? _hoopBbox;
  Rect? _autoRoi;
  Rect? _autoNetRoi;
  Rect? _autoHoopBbox;
  bool _netUserEdited = false;
  bool _editingNet = false;
  int _analysisStartMs = 0;
  bool _rangeTouched = false;
  int _analysisEndMs = 0;
  int _beforeSeconds = 3;
  int _afterSeconds = 1;
  String _analysisMode = 'standard';
  Timer? _previewPlaybackTimer;
  bool _previewPlaying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _restoreDraft();
      _takePendingImport();
    });
  }

  void _takePendingImport() {
    if (!mounted || ref.read(pendingImportProvider) == null) return;
    final paths = ref.read(pendingImportProvider.notifier).take();
    if (paths == null || paths.isEmpty) return;
    unawaited(
      paths.length == 1
          ? _importVideoPath(paths.single)
          : _importVideoPaths(paths),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) {
      _previewPlaybackTimer?.cancel();
      _previewPlaybackTimer = null;
      _previewPlaying = false;
    }
  }

  Future<void> _restoreDraft() async {
    if (!mounted || _draftLoaded) return;
    final state = ref.read(projectProvider);
    JsonMap? draft;
    try {
      draft =
          state.workflowDraft ??
          await ref.read(projectProvider.notifier).loadWorkflowDraft();
    } catch (error) {
      if (mounted) {
        ref
            .read(noticeProvider.notifier)
            .push(
              NoticeMessage(
                id: 'import-draft-${DateTime.now().microsecondsSinceEpoch}',
                severity: NoticeSeverity.error,
                title: '配置草稿加载失败',
                description: context.bheText(error.toString()),
              ),
            );
      }
    }
    if (!mounted) return;
    _draftLoaded = true;
    final currentState = ref.read(projectProvider);
    if (currentState.video != null) {
      _syncFromState(currentState);
    }
    final draftVideoId = draft?['video_id']?.toString();
    if (draft != null &&
        draft.isNotEmpty &&
        currentState.video != null &&
        (draftVideoId == null ||
            draftVideoId == currentState.video?['id']?.toString())) {
      _applyDraftLocally(draft);
      setState(() => _showExistingDraft = true);
      return;
    }
  }

  void _syncFromState(ProjectState state) {
    final video = state.video;
    if (video == null) return;
    final autoRoi = state.suggestedRoi;
    final autoHoopBbox = state.hoopBbox;
    final autoNetRoi = recommendedNetRoi(autoRoi, autoHoopBbox);
    if (autoRoi != null) {
      _autoRoi = autoRoi;
      _autoNetRoi = autoNetRoi;
      _autoHoopBbox = autoHoopBbox;
    }
    _roi = state.suggestedRoi;
    _netRoi = state.netRoi ?? recommendedNetRoi(_roi, state.hoopBbox);
    _netUserEdited = state.netRoi != null;
    _hoopBbox = state.hoopBbox;
    _editingNet = false;
    // 导入流程(含自动识别)在后台 await 期间用户可能已调整分析范围,
    // 完成后的状态同步不得覆盖用户手选的范围。
    if (!_rangeTouched) {
      _analysisStartMs = _analysisStart(state);
      _analysisEndMs = _analysisEnd(state);
    }
    _beforeSeconds = 3;
    _afterSeconds = 1;
    _analysisMode = state.analysisMode;
    if (_step == 0 && !state.multiVideo) _step = 1;
  }

  void _applyDraftLocally(JsonMap draft) {
    final roi = _rectFromJson(draft['roi']);
    final net = _rectFromJson(draft['net_roi']);
    final hoop = _rectFromJson(draft['hoop_bbox']);
    final autoRoi = _rectFromJson(draft['auto_roi']);
    final autoNetRoi = _rectFromJson(draft['auto_net_roi']);
    final autoHoopBbox = _rectFromJson(draft['auto_hoop_bbox']);
    final range = (draft['analysis_range'] as Map?)?.cast<String, dynamic>();
    final savedStep = (draft['step'] as num?)?.toInt() ?? 0;
    setState(() {
      _step = savedStep.clamp(0, _stepCount - 1);
      _roi = roi ?? _roi;
      _netRoi = net ?? _netRoi;
      _hoopBbox = hoop ?? _hoopBbox;
      _autoRoi = autoRoi ?? _autoRoi;
      _autoNetRoi = autoNetRoi ?? _autoNetRoi;
      _autoHoopBbox = autoHoopBbox ?? _autoHoopBbox;
      _analysisStartMs =
          (range?['start_ms'] as num?)?.toInt() ?? _analysisStartMs;
      _analysisEndMs = (range?['end_ms'] as num?)?.toInt() ?? _analysisEndMs;
      _beforeSeconds = _selectedSeconds(
        draft['before_seconds'],
        fallback: 6,
        options: _beforeSecondOptions,
      );
      _afterSeconds = _selectedSeconds(
        draft['after_seconds'],
        fallback: 3,
        options: _afterSecondOptions,
      );
      final mode = draft['analysis_mode']?.toString();
      _analysisMode = mode == 'fast' ? 'fast' : 'standard';
      final netSource = draft['net_roi_source']?.toString();
      _netUserEdited = netSource == null ? net != null : netSource == 'manual';
      // 草稿范围成为新基线,用户之后的调整重新生效。
      _rangeTouched = range?['start_ms'] != null || range?['end_ms'] != null;
    });
  }

  JsonMap _draft({int? step}) => {
    'version': 4,
    'video_id': ref.read(projectProvider).video?['id'],
    'step': step ?? _step,
    'analysis_range': {'start_ms': _analysisStartMs, 'end_ms': _analysisEndMs},
    'analysis_mode': _analysisMode,
    'before_seconds': _beforeSeconds,
    'after_seconds': _afterSeconds,
    'net_roi_source': _netUserEdited ? 'manual' : 'auto',
    ...?_rectMap('roi', _roi),
    ...?_rectMap('net_roi', _netRoi),
    ...?_rectMap('hoop_bbox', _hoopBbox),
    ...?_rectMap('auto_roi', _autoRoi),
    ...?_rectMap('auto_net_roi', _autoNetRoi),
    ...?_rectMap('auto_hoop_bbox', _autoHoopBbox),
  };

  JsonMap _backendDraft({int? step}) {
    return {
      'version': 4,
      'video_id': ref.read(projectProvider).video?['id'],
      'step': step ?? _step,
      'analysis_range': {
        'start_ms': _analysisStartMs,
        'end_ms': _analysisEndMs,
      },
      'analysis_mode': _analysisMode,
      'before_seconds': _beforeSeconds,
      'after_seconds': _afterSeconds,
      'net_roi_source': _netUserEdited ? 'manual' : 'auto',
      ...?_rectMap('roi', _roi),
      ...?_rectMap('net_roi', _netRoi),
      ...?_rectMap('hoop_bbox', _hoopBbox),
      ...?_rectMap('auto_roi', _autoRoi),
      ...?_rectMap('auto_net_roi', _autoNetRoi),
      ...?_rectMap('auto_hoop_bbox', _autoHoopBbox),
    };
  }

  Future<void> _persistDraft({int? step}) async {
    if (ref.read(projectProvider).video == null) return;
    try {
      await ref
          .read(projectProvider.notifier)
          .saveWorkflowDraft(_draft(step: step));
    } catch (error) {
      if (!mounted) return;
      ref
          .read(noticeProvider.notifier)
          .push(
            NoticeMessage(
              id: 'import-draft-save-${DateTime.now().microsecondsSinceEpoch}',
              severity: NoticeSeverity.error,
              title: '配置草稿保存失败',
                description: context.bheText(error.toString()),
            ),
          );
    }
  }

  Future<void> _selectVideo() async {
    final existingState = ref.read(projectProvider);
    final existingVideo = existingState.video;
    if (existingVideo != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.bheText('更换当前视频？')),
          content: Text(context.bheText('更换视频会创建一个新的分析项目，当前项目和审核记录会保留。')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.bheText('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.bheText('继续选择')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final group = XTypeGroup(
      label: context.bheText('视频'),
      extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv'],
      mimeTypes: [
        'video/*',
        'video/mp4',
        'video/quicktime',
        'video/x-m4v',
        'video/x-msvideo',
        'video/x-matroska',
      ],
      uniformTypeIdentifiers: [
        'public.movie',
        'public.mpeg-4',
        'com.apple.quicktime-movie',
      ],
    );
    if (existingVideo == null) {
      final files = await openFiles(acceptedTypeGroups: [group]);
      if (files.isEmpty || !mounted) return;
      if (files.length > 1) {
        await _importVideoPaths([for (final file in files) file.path]);
      } else {
        await _importVideoPath(files.single.path);
      }
      return;
    }
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null || !mounted) return;
    await _importVideoPath(file.path);
  }

  /// 同一场比赛的多段视频建成一个项目，导入后停在视频列表。
  Future<void> _importVideoPaths(List<String> paths) async {
    setState(() {
      _step = 0;
      _showExistingDraft = false;
    });
    _rangeTouched = false;
    await ref.read(projectProvider.notifier).createProjectFromVideos(paths);
    if (!mounted) return;
    _draftLoaded = true;
    setState(() => _step = 0);
  }

  Future<void> _addVideos() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: context.bheText('视频'),
          extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv'],
          mimeTypes: ['video/*'],
          uniformTypeIdentifiers: ['public.movie'],
        ),
      ],
    );
    if (files.isEmpty || !mounted) return;
    await ref
        .read(projectProvider.notifier)
        .addVideos([for (final file in files) file.path]);
    if (mounted) setState(() => _step = 0);
  }

  String? _editingVideoId;

  void _editSegment(String videoId) {
    _stopPreviewPlayback();
    _editingVideoId = videoId;
    if (ref.read(projectProvider).video?['id']?.toString() == videoId) {
      _syncFromState(ref.read(projectProvider));
      setState(() => _step = 1);
      return;
    }
    ref.read(projectProvider.notifier).activateVideo(videoId);
  }

  void _moveSegment(String videoId, int offset) {
    final ids = [
      for (final video in ref.read(projectProvider).videos)
        video['id'].toString(),
    ];
    final index = ids.indexOf(videoId);
    final target = index + offset;
    if (index < 0 || target < 0 || target >= ids.length) return;
    ids
      ..removeAt(index)
      ..insert(target, videoId);
    unawaited(ref.read(projectProvider.notifier).reorderVideos(ids));
  }

  /// 多段项目在最后一步只保存这一段的范围和篮筐，统一在视频列表排队分析。
  Future<void> _saveSegment() async {
    if (_roi == null || _applying) return;
    setState(() => _applying = true);
    try {
      final notifier = ref.read(projectProvider.notifier);
      final applied = await notifier.applyWorkflowDraft(
        _backendDraft(step: _step),
      );
      if (!mounted || !applied) return;
      final videoId = ref.read(projectProvider).video?['id']?.toString();
      if (videoId != null) await notifier.propagateHoopToFollowingParts(videoId);
      if (mounted) setState(() => _step = 0);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  void _startQueue() {
    unawaited(
      ref.read(projectProvider.notifier).startAnalysisQueue(
        beforeSeconds: _beforeSeconds.toDouble(),
        afterSeconds: _afterSeconds.toDouble(),
      ),
    );
  }

  /// Runs the import after a path is chosen, from the picker or a drop.
  Future<void> _importVideoPath(String path) async {
    final existingState = ref.read(projectProvider);
    setState(() {
      _step = 1;
      _showExistingDraft = false;
    });
    try {
      final metadata = await ref
          .read(projectSessionProvider)
          .inspectVideo(videoPath: path);
      final video =
          (metadata['video'] as Map?)?.cast<String, dynamic>() ?? metadata;
      final advice = _videoProcessingAdvice(video);
      if (advice.heavy || _isElevatedVideo(video)) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(context.bheText('这个视频可能需要较长时间')),
            content: Text(
              '${context.bheText(advice.importDetail)}\n\n${context.bheText('如果方便，建议先用剪辑工具压缩后再导入。也可以继续，原视频不会被修改。')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(context.bheText('先取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(context.bheText('继续导入')),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) {
          if (mounted) {
            setState(() {
              _step = 0;
            });
          }
          return;
        }
      }
    } catch (_) {
      // 元数据预检失败时仍交给正式导入流程处理。
    }
    final previousVideoId = existingState.video?['id']?.toString();
    _rangeTouched = false;
    await ref.read(projectProvider.notifier).selectVideo(path);
    if (!mounted) return;
    final importedState = ref.read(projectProvider);
    final importedVideoId = importedState.video?['id']?.toString();
    if (importedVideoId == null || importedVideoId == previousVideoId) {
      setState(() {
        _step = 0;
        _showExistingDraft = false;
      });
      return;
    }
    _draftLoaded = true;
    _syncFromState(importedState);
    setState(() {
      _step = 1;
      _showExistingDraft = false;
    });
    await _persistDraft(step: 1);
  }

  Future<void> _relinkMissingVideo() async {
    final group = XTypeGroup(
      label: context.bheText('视频'),
      extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv'],
      mimeTypes: ['video/*'],
      uniformTypeIdentifiers: ['public.movie'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null || !mounted) return;
    final relinked = await ref
        .read(projectProvider.notifier)
        .relinkCurrentVideo(file.path);
    if (!mounted || !relinked) return;
    _draftLoaded = true;
    _syncFromState(ref.read(projectProvider));
    setState(() => _step = 1);
    await _persistDraft(step: 1);
  }

  @override
  void dispose() {
    _previewPlaybackTimer?.cancel();
    super.dispose();
  }

  void _stopPreviewPlayback() {
    _previewPlaybackTimer?.cancel();
    _previewPlaybackTimer = null;
    if (mounted) {
      setState(() => _previewPlaying = false);
    } else {
      _previewPlaying = false;
    }
  }

  Future<void> _refreshPreviewAt(int timeMs) async {
    final refreshed = await ref
        .read(projectProvider.notifier)
        .refreshPreviewAt(timeMs);
    if (!refreshed && mounted) _stopPreviewPlayback();
  }

  void _togglePreviewPlayback() {
    final state = ref.read(projectProvider);
    final duration = (state.video?['duration_ms'] as num?)?.toInt() ?? 0;
    if (_previewPlaying) {
      _stopPreviewPlayback();
      return;
    }
    if (duration <= 0 ||
        state.previewTimeMs >= duration ||
        state.previewRefreshing) {
      return;
    }
    setState(() => _previewPlaying = true);
    _previewPlaybackTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      final current = ref.read(projectProvider);
      if (current.previewRefreshing || current.busy) return;
      final next = current.previewTimeMs + 500;
      if (next >= duration) {
        _stopPreviewPlayback();
        return;
      }
      unawaited(_refreshPreviewAt(next));
    });
  }

  Future<void> _next() async {
    if (!_canLeaveStep(_step)) return;
    final next = math.min(_step + 1, _stepCount - 1);
    if (_step == 2 && next != 2) _stopPreviewPlayback();
    setState(() => _step = next);
    await _persistDraft(step: next);
    // 进入检测区域步骤时,标记画面跟随分析范围起点,而不是停在片头。
    if (next == 2 && _analysisStartMs > 0) {
      final state = ref.read(projectProvider);
      if (state.previewTimeMs < _analysisStartMs) {
        ref.read(projectProvider.notifier).setPreviewTimeOnly(_analysisStartMs);
      }
    }
  }

  Future<void> _back() async {
    if (_step == 0) return;
    final next = _step - 1;
    if (_step == 2 && next != 2) _stopPreviewPlayback();
    setState(() => _step = next);
    await _persistDraft(step: next);
  }

  bool _canLeaveStep(int step) {
    final state = ref.read(projectProvider);
    if (step == 0) return state.video != null;
    if (step == 2) return _roi != null;
    return true;
  }

  Future<void> _applyAndAnalyze() async {
    final state = ref.read(projectProvider);
    if (state.video == null || _roi == null || _applying) return;
    if (state.candidates.isNotEmpty && mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.bheText('应用新配置？')),
          content: Text(
            context.bheText(
              '当前已有 ${state.candidates.length} 个候选片段。应用后会按新配置重新生成候选，原始视频不会被删除。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.bheText('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.bheText('应用并重新分析')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _applying = true);
    try {
      final applied = await ref
          .read(projectProvider.notifier)
          .applyWorkflowDraft(_backendDraft(step: _step));
      if (!mounted || !applied) return;
      final started = await ref
          .read(projectProvider.notifier)
          .startAnalysis(
            beforeSeconds: _beforeSeconds.toDouble(),
            afterSeconds: _afterSeconds.toDouble(),
          );
      if (mounted && started) context.go('/review');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    ref.listen<List<String>?>(pendingImportProvider, (_, next) {
      if (next == null) return;
      // Let the project-change handling below settle before importing.
      WidgetsBinding.instance.addPostFrameCallback((_) => _takePendingImport());
    });
    ref.listen<ProjectState>(projectProvider, (previous, next) {
      final previousVideoId = previous?.video?['id']?.toString();
      final nextVideoId = next.video?['id']?.toString();
      final projectChanged =
          previousVideoId != nextVideoId ||
          previous?.videoPath != next.videoPath;
      if (!projectChanged) return;
      _stopPreviewPlayback();
      if (next.video == null) {
        setState(() {
          _draftLoaded = false;
          _showExistingDraft = false;
          _step = 0;
          _roi = null;
          _netRoi = null;
          _hoopBbox = null;
          _autoRoi = null;
          _autoNetRoi = null;
          _autoHoopBbox = null;
          _netUserEdited = false;
          _editingNet = false;
          _analysisStartMs = 0;
          _analysisEndMs = 0;
        });
        return;
      }
      _draftLoaded = true;
      _showExistingDraft = false;
      _autoRoi = null;
      _autoNetRoi = null;
      _autoHoopBbox = null;
      _netUserEdited = false;
      _editingNet = false;
      _rangeTouched = false;
      _syncFromState(next);
      final editing = _editingVideoId == nextVideoId;
      _editingVideoId = null;
      setState(() => _step = next.multiVideo && !editing ? 0 : 1);
    });
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final hasVideo = state.video != null;
    final busy =
        state.busy || state.analysisRunning || state.exportRunning || _applying;
    final steps = <_ImportStep>[
      (
        title: l10n?.selectVideo ?? '选择视频',
        completed: hasVideo,
      ),
      (
        title: l10n?.analysisRange ?? '分析范围',
        completed: hasVideo,
      ),
      (
        title: l10n?.detectRegionStep ?? '检测区域',
        completed: _roi != null,
      ),
      (
        title: l10n?.importConfirmStep ?? '确认并分析',
        completed: false,
      ),
    ];

    final stepSummaries = <String?>[
      hasVideo
          ? (state.video!['source_path']?.toString() ?? '')
                .split(RegExp(r'[/\\]'))
                .last
          : null,
      hasVideo && _analysisEndMs > _analysisStartMs
          ? '${_formatDuration(_analysisStartMs)} – ${_formatDuration(_analysisEndMs)}'
          : null,
      _roi == null ? null : context.bheText('已设置'),
      _step == _stepCount - 1
          ? context.bheText(_analysisMode == 'fast' ? '快速分析' : '标准分析')
          : null,
    ];
    final replacesCandidates = state.candidates.isNotEmpty && !state.multiVideo;
    final pendingSegments = state.videos
        .where(
          (video) =>
              !needsHoopConfirmation(video) &&
              (video['analysis_job'] as Map?)?['state'] != 'completed',
        )
        .length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.xl,
            Spacing.lg,
            Spacing.xl,
            0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1240),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n?.configureProject ?? '配置分析项目',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasVideo
                                  ? (l10n?.confirmProjectSteps ??
                                        '按步骤确认视频、分析范围和篮筐检测区域，最后再开始分析。')
                                  : (l10n?.chooseVideoLastStep ??
                                        '先选择一段固定机位视频，系统会在最后一步统一应用配置。'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasVideo &&
                          (!state.multiVideo ||
                              state.videoPath == null ||
                              state.videoPath!.isEmpty))
                        TextButton.icon(
                          onPressed: busy
                              ? null
                              : state.videoPath == null ||
                                    state.videoPath!.isEmpty
                              ? _relinkMissingVideo
                              : _selectVideo,
                          icon: Icon(
                            state.videoPath == null || state.videoPath!.isEmpty
                                ? Icons.link_rounded
                                : Icons.swap_horiz_rounded,
                            size: 17,
                          ),
                          label: Text(
                            state.videoPath == null || state.videoPath!.isEmpty
                                ? (l10n?.relinkVideo ?? '重新定位视频')
                                : (l10n?.replaceVideo ?? '更换视频'),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.md),
                  _ImportStepper(
                    steps: steps,
                    summaries: stepSummaries,
                    current: _step,
                    onStepTap: busy ? null : _goToEarlierStep,
                  ),
                  if (_showExistingDraft) ...[
                    const SizedBox(height: Spacing.sm),
                    _DraftBanner(
                      onContinue: () =>
                          setState(() => _showExistingDraft = false),
                      onDiscard: () async {
                        await ref
                            .read(projectProvider.notifier)
                            .clearWorkflowDraft();
                        if (!mounted) return;
                        _syncFromState(ref.read(projectProvider));
                        setState(() {
                          _step = 1;
                          _showExistingDraft = false;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xl,
              vertical: Spacing.md,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _buildStep(context, state, busy),
                ),
              ),
            ),
          ),
        ),
        Container(
          key: const Key('import-footer'),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(top: BorderSide(color: c.border)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.xl,
            vertical: Spacing.sm,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1240),
              child: Row(
                children: [
                  if (_step > 0)
                    CsButton(
                      label: Flexible(
                        child: Text(
                          l10n?.returnAction ?? '上一步',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      icon: LucideIcons.arrowLeft,
                      variant: CsButtonVariant.secondary,
                      onPressed: busy ? null : _back,
                    ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: state.busyMessage != null
                        ? Row(
                            children: [
                              SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                  color: c.orange,
                                ),
                              ),
                              const SizedBox(width: Spacing.sm),
                              Flexible(
                                child: Text(
                                  context.bheText(state.busyMessage!),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: c.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : _step == _stepCount - 1 && replacesCandidates
                        ? Text(
                            l10n?.importReplacesCandidates ??
                                '已有候选会被本次结果替换',
                            textAlign: TextAlign.right,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: c.textSecondary,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(width: Spacing.md),
                  if (state.multiVideo && _step == 0)
                    Flexible(
                      flex: 2,
                      child: CsButton(
                        key: const Key('import-analyze-all'),
                        label: Flexible(
                          child: Text(
                            '${context.bheText('分析全部')}（$pendingSegments）',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        icon: LucideIcons.play,
                        onPressed:
                            busy ||
                                state.analysisQueue.isNotEmpty ||
                                pendingSegments == 0
                            ? null
                            : _startQueue,
                      ),
                    )
                  else if (state.multiVideo && _step == _stepCount - 1)
                    Flexible(
                      flex: 2,
                      child: CsButton(
                        key: const Key('import-save-segment'),
                        label: Flexible(
                          child: Text(
                            context.bheText('保存这一段的设置'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        icon: LucideIcons.check,
                        isLoading: _applying,
                        onPressed: state.busy || _roi == null
                            ? null
                            : _saveSegment,
                      ),
                    )
                  else if (_step < _stepCount - 1)
                    Flexible(
                      flex: 2,
                      child: CsButton(
                      label: Flexible(
                        child: Text(
                          _nextStepLabel(l10n) ?? (l10n?.nextStep ?? '下一步'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      icon: LucideIcons.arrowRight,
                      onPressed: busy || !_canLeaveStep(_step) ? null : _next,
                    ),
                    )
                  else
                    Flexible(
                      flex: 2,
                      child: CsButton(
                      label: Flexible(
                        child: Text(
                          l10n?.confirmAndStartAnalysis ?? '确认配置并开始分析',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      icon: LucideIcons.play,
                      isLoading: _applying,
                      onPressed: busy || _roi == null
                          ? null
                          : _applyAndAnalyze,
                    ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String? _nextStepLabel(BheLocalizations? l10n) => switch (_step) {
    0 => l10n?.importNextTo(l10n.analysisRange),
    1 => l10n?.importNextTo(l10n.detectRegionStep),
    2 => l10n?.importNextTo(l10n.importConfirmStep),
    _ => null,
  };

  void _goToEarlierStep(int index) {
    if (index >= _step) return;
    if (_step == 2 && index != 2) _stopPreviewPlayback();
    setState(() => _step = index);
    unawaited(_persistDraft(step: index));
  }

  Widget _buildStep(BuildContext context, ProjectState state, bool busy) {
    switch (_step) {
      case 0:
        if (state.multiVideo) {
          return _VideoSegmentList(
            state: state,
            busy: state.busy || _applying,
            beforeSeconds: _beforeSeconds,
            afterSeconds: _afterSeconds,
            onBeforeChanged: (seconds) => setState(() => _beforeSeconds = seconds),
            onAfterChanged: (seconds) => setState(() => _afterSeconds = seconds),
            onAddVideos: state.busy ? null : _addVideos,
            onEdit: _editSegment,
            onMove: _moveSegment,
            onRemoveFromQueue: (videoId) => unawaited(
              ref.read(projectProvider.notifier).removeFromAnalysisQueue(videoId),
            ),
            onPauseQueue: () =>
                unawaited(ref.read(projectProvider.notifier).pauseAnalysisQueue()),
            onResumeQueue: () =>
                unawaited(ref.read(projectProvider.notifier).resumeAnalysisQueue()),
          );
        }
        return _VideoStep(
          video: state.video,
          onSelect: busy ? null : _selectVideo,
          onAddVideos: busy ? null : _addVideos,
        );
      case 1:
        final duration = (state.video?['duration_ms'] as num?)?.toInt() ?? 0;
        final videoWidth = (state.video?['width'] as num?)?.toDouble() ?? 16;
        final videoHeight = (state.video?['height'] as num?)?.toDouble() ?? 9;
        return _AnalysisStep(
          videoPath: state.video?['source_path']?.toString(),
          durationMs: duration,
          aspectRatio: videoWidth > 0 && videoHeight > 0
              ? videoWidth / videoHeight
              : 16 / 9,
          startMs: _analysisStartMs,
          endMs: _analysisEndMs,
          enabled:
              (!busy || state.roiDetecting) &&
              !state.analysisRunning &&
              !state.exportRunning,
          onChanged: (start, end) {
            setState(() {
              _analysisStartMs = start;
              _analysisEndMs = end;
              _rangeTouched = true;
            });
            unawaited(_persistDraft());
          },
        );
      case 2:
        final sourceWidth = (state.video?['width'] as num?)?.toDouble() ?? 16;
        final sourceHeight = (state.video?['height'] as num?)?.toDouble() ?? 9;
        final hoopBbox = _hoopBbox;
        return _DetectionStep(
          state: state,
          hoopBbox: hoopBbox,
          roi: _roi,
          netRoi: _netRoi,
          editingNet: _editingNet,
          enabled: state.video != null && !busy,
          aspectRatio: sourceWidth / sourceHeight,
          onEditNetChanged: (value) => setState(() => _editingNet = value),
          onPreviewTimeChanged: (timeMs) {
            // 检测区域步骤由播放器即时 seek 呈现,这里只同步时间到
            // 状态与草稿,不再触发引擎抽帧(大视频上每次抽帧 1-2 秒)。
            ref.read(projectProvider.notifier).setPreviewTimeOnly(timeMs);
          },
          onRefreshPreview: () =>
              unawaited(_refreshPreviewAt(state.previewTimeMs)),
          onPreviewPlaybackToggled: _togglePreviewPlayback,
          previewPlaying: _previewPlaying,
          onChanged: (value) {
            setState(() {
              if (_editingNet) {
                _netRoi = value;
                _netUserEdited = true;
              } else {
                _roi = value;
                if (!_netUserEdited) {
                  _netRoi = recommendedNetRoi(value, hoopBbox);
                }
              }
            });
            unawaited(_persistDraft());
          },
          onResetCurrent: () {
            setState(() {
              if (_editingNet) {
                _netRoi =
                    _autoNetRoi ??
                    recommendedNetRoi(
                      _autoRoi ?? _roi,
                      _autoHoopBbox ?? state.hoopBbox,
                    ) ??
                    recommendedNetRoi(_roi, state.hoopBbox);
                _netUserEdited = false;
              } else if (_autoRoi != null) {
                _roi = _autoRoi;
                _hoopBbox = _autoHoopBbox;
                if (!_netUserEdited) {
                  _netRoi =
                      _autoNetRoi ??
                      recommendedNetRoi(_autoRoi, _autoHoopBbox);
                }
              }
            });
            unawaited(_persistDraft());
          },
        );
      case 3:
        return _SummaryStep(
          state: state,
          startMs: _analysisStartMs,
          endMs: _analysisEndMs,
          roi: _roi,
          netRoi: _netRoi,
          analysisMode: _analysisMode,
          beforeSeconds: _beforeSeconds,
          afterSeconds: _afterSeconds,
          fastModeEnabled: _fastAnalysisEnabled,
          onAnalysisModeChanged: (mode) {
            setState(() => _analysisMode = mode);
            unawaited(_persistDraft());
          },
          onBeforeSecondsChanged: (seconds) {
            setState(() => _beforeSeconds = seconds);
            unawaited(_persistDraft());
          },
          onAfterSecondsChanged: (seconds) {
            setState(() => _afterSeconds = seconds);
            unawaited(_persistDraft());
          },
          onEditStep: busy ? null : _goToEarlierStep,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

typedef _ImportStep = ({String title, bool completed});

class _ImportStepper extends StatelessWidget {
  const _ImportStepper({
    required this.steps,
    required this.summaries,
    required this.current,
    required this.onStepTap,
  });

  final List<_ImportStep> steps;
  final List<String?> summaries;
  final int current;
  final ValueChanged<int>? onStepTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        for (var index = 0; index < steps.length; index++) ...[
          if (index > 0) const SizedBox(width: Spacing.xs),
          Expanded(
            child: Builder(
              builder: (context) {
                final step = steps[index];
                final active = index == current;
                final done = index < current && step.completed;
                final tappable = onStepTap != null && index < current;
                return Semantics(
                  button: tappable,
                  selected: active,
                  child: Material(
                    key: ValueKey('import-step-$index'),
                    color: active ? c.surface2 : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(CsRadius.md),
                      side: BorderSide(
                        color: active ? c.borderStrong : Colors.transparent,
                      ),
                    ),
                    child: InkWell(
                      onTap: tappable ? () => onStepTap!(index) : null,
                      borderRadius: BorderRadius.circular(CsRadius.md),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.sm,
                          vertical: Spacing.xs,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: done
                                    ? c.goal.withValues(alpha: 0.16)
                                    : active
                                    ? c.orangeFill
                                    : Colors.transparent,
                                border: done || active
                                    ? null
                                    : Border.all(color: c.borderStrong),
                              ),
                              child: done
                                  ? Icon(
                                      Icons.check_rounded,
                                      size: 14,
                                      color: c.goal,
                                    )
                                  : Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        color: active
                                            ? c.onOrange
                                            : c.textTertiary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                            const SizedBox(width: Spacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    step.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: active || done
                                          ? c.textPrimary
                                          : c.textSecondary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (summaries[index] != null)
                                    Text(
                                      summaries[index]!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: c.textTertiary,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _DraftBanner extends StatelessWidget {
  const _DraftBanner({required this.onContinue, required this.onDiscard});
  final VoidCallback onContinue;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.orange.withValues(alpha: .10),
        border: Border.all(color: c.orange.withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          Icon(Icons.restore_rounded, size: 17, color: c.orange),
          const SizedBox(width: Spacing.sm),
          Expanded(child: Text(context.bheText('检测到上次未完成的配置。'))),
          TextButton(
            onPressed: onDiscard,
            child: Text(context.bheText('放弃草稿')),
          ),
          FilledButton(
            onPressed: onContinue,
            child: Text(context.bheText('继续配置')),
          ),
        ],
      ),
    );
  }
}

class _VideoStep extends StatelessWidget {
  const _VideoStep({
    required this.video,
    required this.onSelect,
    required this.onAddVideos,
  });
  final JsonMap? video;
  final VoidCallback? onSelect;
  final VoidCallback? onAddVideos;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    if (video == null) {
      return CsCard(
        child: Column(
          children: [
            const SizedBox(height: Spacing.lg),
            Icon(LucideIcons.fileVideo, size: 42, color: c.orange),
            const SizedBox(height: Spacing.md),
            Text(context.bheText('选择原始视频'), style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.xs),
            Text(
              context.bheText('支持 MP4、MOV、M4V、AVI、MKV。同一场比赛的多段视频可以一起选，会建成一个项目。原始视频不会被修改或上传。'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: Spacing.lg),
            CsButton(
              label: Text(context.bheText('选择视频')),
              icon: LucideIcons.folderOpen,
              onPressed: onSelect,
            ),
            const SizedBox(height: Spacing.lg),
          ],
        ),
      );
    }
    return _InfoPanel(
      title: context.bheText('视频已准备好'),
      icon: LucideIcons.checkCircle2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _videoSummary(video!, noAudio: context.bheText('无音频')),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: Spacing.md),
          _VideoProcessingHint(video: video!),
          const SizedBox(height: Spacing.md),
          CsButton(
            label: Text(context.bheText('添加同一场的其他视频')),
            icon: LucideIcons.plus,
            variant: CsButtonVariant.secondary,
            onPressed: onAddVideos,
          ),
        ],
      ),
    );
  }
}

class _VideoProcessingHint extends StatelessWidget {
  const _VideoProcessingHint({required this.video});

  final JsonMap video;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final advice = _videoProcessingAdvice(video);
    final color = advice.heavy ? c.warning : c.textSecondary;
    final background = advice.heavy
        ? c.warning.withValues(alpha: .09)
        : c.surface2;
    final border = advice.heavy ? c.warning.withValues(alpha: .35) : c.border;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            advice.heavy ? Icons.schedule_rounded : Icons.info_outline_rounded,
            size: 17,
            color: color,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: context.bheText(advice.title),
                    style: TextStyle(
                      color: advice.heavy ? c.textPrimary : color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: '\n${context.bheText(advice.importDetail)}',
                    style: TextStyle(color: color, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoProcessingAdvice {
  const _VideoProcessingAdvice({
    required this.heavy,
    required this.title,
    required this.importDetail,
  });

  final bool heavy;
  final String title;
  final String importDetail;
}

_VideoProcessingAdvice _videoProcessingAdvice(JsonMap video) {
  const gib = 1024 * 1024 * 1024;
  final sizeBytes = (video['source_size_bytes'] as num?)?.toInt() ?? 0;
  final durationMs = (video['duration_ms'] as num?)?.toInt() ?? 0;
  final width = (video['width'] as num?)?.toInt() ?? 0;
  final height = (video['height'] as num?)?.toInt() ?? 0;
  final durationSeconds = durationMs / 1000;
  final bitrateMbps = durationSeconds > 0
      ? sizeBytes * 8 / durationSeconds / 1000000
      : 0.0;
  final highResolution = width >= 3840 || height >= 2160;
  final heavy =
      sizeBytes >= 8 * gib ||
      highResolution ||
      bitrateMbps >= 80 ||
      durationMs >= const Duration(minutes: 45).inMilliseconds;
  final elevated =
      sizeBytes >= 2 * gib ||
      width >= 2560 ||
      height >= 1440 ||
      bitrateMbps >= 45 ||
      durationMs >= const Duration(minutes: 20).inMilliseconds;
  final sizeLabel = _formatBytes(sizeBytes);
  final videoLabel =
      '$sizeLabel · ${width > 0 && height > 0 ? '$width×$height' : '分辨率未知'}';

  if (heavy) {
    return _VideoProcessingAdvice(
      heavy: true,
      title: '视频体量较大，后续处理可能需要较长时间',
      importDetail: '$videoLabel。若只是想减少等待，建议先压缩为 1080p MP4 再导入；分析期间不要关闭应用。',
    );
  }
  if (elevated) {
    return _VideoProcessingAdvice(
      heavy: false,
      title: '视频体量偏大，处理时间会比普通视频更长',
      importDetail: '$videoLabel。建议保持电源和磁盘空间充足，想加快速度可先压缩后导入。',
    );
  }
  return const _VideoProcessingAdvice(
    heavy: false,
    title: '视频已就绪',
    importDetail: '分析会在本地进行，耗时主要取决于视频时长、分辨率和文件码率。',
  );
}

bool _isElevatedVideo(JsonMap video) {
  const gib = 1024 * 1024 * 1024;
  final sizeBytes = (video['source_size_bytes'] as num?)?.toInt() ?? 0;
  final durationMs = (video['duration_ms'] as num?)?.toInt() ?? 0;
  final width = (video['width'] as num?)?.toInt() ?? 0;
  final height = (video['height'] as num?)?.toInt() ?? 0;
  return sizeBytes >= 2 * gib ||
      width >= 2560 ||
      height >= 1440 ||
      durationMs >= const Duration(minutes: 20).inMilliseconds;
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '文件大小未知';
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

class _AnalysisStep extends StatelessWidget {
  const _AnalysisStep({
    required this.videoPath,
    required this.durationMs,
    required this.aspectRatio,
    required this.startMs,
    required this.endMs,
    required this.enabled,
    required this.onChanged,
  });
  final String? videoPath;
  final int durationMs;
  final double aspectRatio;
  final int startMs;
  final int endMs;
  final bool enabled;
  final void Function(int startMs, int endMs) onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final analyzed = (endMs - startMs).clamp(0, durationMs).toInt();
    final percent = durationMs <= 0 ? 0 : (analyzed * 100 / durationMs).round();
    final editor = CsCard(
      child: _AnalysisRangeEditor(
        videoPath: videoPath,
        durationMs: durationMs,
        aspectRatio: aspectRatio,
        startMs: startMs,
        endMs: endMs,
        enabled: enabled,
        onChanged: onChanged,
        onCommit: (_, _) async {},
      ),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.bheText('分析范围'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                context.bheText('默认分析全片。拖动范围手柄排除热身、暂停或比赛结束部分，修改会自动保存在当前草稿。'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        CsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _RangeStat(
                      label: l10n?.importRangeAnalyzed ?? '分析时长',
                      value: _formatDuration(analyzed),
                    ),
                  ),
                  Expanded(
                    child: _RangeStat(
                      label: l10n?.importRangeExcluded ?? '已排除',
                      value: _formatDuration(durationMs - analyzed),
                      muted: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: durationMs <= 0 ? 0 : analyzed / durationMs,
                  minHeight: 6,
                  backgroundColor: c.surface3,
                  color: c.orange,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                l10n?.importRangeCoverage(
                      _formatDuration(durationMs),
                      percent,
                    ) ??
                    '全片 ${_formatDuration(durationMs)} · 分析其中 $percent%',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1000) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: editor),
              const SizedBox(width: Spacing.lg),
              SizedBox(width: 300, child: info),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [editor, const SizedBox(height: Spacing.md), info],
        );
      },
    );
  }
}

class _RangeStat extends StatelessWidget {
  const _RangeStat({
    required this.label,
    required this.value,
    this.muted = false,
  });

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            color: muted ? c.textSecondary : c.textPrimary,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _DetectionStep extends ConsumerStatefulWidget {
  const _DetectionStep({
    required this.state,
    required this.hoopBbox,
    required this.roi,
    required this.netRoi,
    required this.editingNet,
    required this.enabled,
    required this.aspectRatio,
    required this.onEditNetChanged,
    required this.onPreviewTimeChanged,
    required this.onPreviewPlaybackToggled,
    required this.onRefreshPreview,
    required this.previewPlaying,
    required this.onChanged,
    required this.onResetCurrent,
  });
  final ProjectState state;
  final Rect? hoopBbox;
  final Rect? roi;
  final Rect? netRoi;
  final bool editingNet;
  final bool enabled;
  final double aspectRatio;
  final ValueChanged<bool> onEditNetChanged;
  final ValueChanged<int> onPreviewTimeChanged;
  final VoidCallback onPreviewPlaybackToggled;
  final VoidCallback onRefreshPreview;
  final bool previewPlaying;
  final ValueChanged<Rect> onChanged;
  final VoidCallback onResetCurrent;

  @override
  ConsumerState<_DetectionStep> createState() => _DetectionStepState();
}

class _DetectionStepState extends ConsumerState<_DetectionStep> {
  late final _playback = ref.read(playbackCoordinatorProvider);
  bool _routeActive = true;

  Future<void> _pauseForDialog() async {
    _playingRequested = false;
    await _player?.pause();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeActive = TickerMode.valuesOf(context).enabled;
    if (!_routeActive) {
      unawaited(
        _pauseForDialog().catchError((Object error) {
          debugPrint('Hidden detection preview pause failed: $error');
        }),
      );
    }
  }

  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  bool _playerReady = false;
  bool _playing = false;
  bool _playingRequested = false;
  int _lastSyncedMs = -1;

  String? get _videoPath => widget.state.video?['source_path']?.toString();

  @override
  void initState() {
    super.initState();
    _playback.register(this, _pauseForDialog);
    unawaited(_openVideo());
  }

  @override
  void dispose() {
    _playback.unregister(this);
    // 组件卸载后纹理不再渲染,此时销毁是安全的(见 review 页同类处理)。
    unawaited(_positionSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    final player = _player;
    _player = null;
    _controller = null;
    unawaited(() async {
      if (player == null) return;
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DetectionStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.video?['source_path']?.toString() != _videoPath) {
      unawaited(_openVideo());
      return;
    }
    // 外部(进入步骤/自动识别)更新了标记画面时间时,播放器跟随 seek。
    final previewMs = widget.state.previewTimeMs;
    if (_playerReady && previewMs != _lastSyncedMs) {
      _lastSyncedMs = previewMs;
      unawaited(_player!.seek(Duration(milliseconds: previewMs)));
    }
    if (widget.previewPlaying != oldWidget.previewPlaying) {
      _syncPlaying(widget.previewPlaying);
    }
  }

  Future<void> _openVideo() async {
    final path = _videoPath;
    await _positionSubscription?.cancel();
    await _playingSubscription?.cancel();
    if (!mounted) return;
    setState(() => _playerReady = false);
    if (path == null || path.isEmpty || !File(path).existsSync()) return;
    try {
      if (_player == null) {
        _player = Player();
        _controller = VideoController(
          _player!,
          configuration: VideoControllerConfiguration(
            enableHardwareAcceleration: !Platform.isWindows,
          ),
        );
      }
      _positionSubscription = _player!.stream.position.listen((position) {
        if (!mounted || !_playing) return;
        _lastSyncedMs = position.inMilliseconds;
        widget.onPreviewTimeChanged(position.inMilliseconds);
      });
      _playingSubscription = _player!.stream.playing.listen((playing) {
        if (!mounted) return;
        // 防自动播放闸:media_kit 偶尔在 open/seek 后意外触发播放,
        // 造成"界面没在播放却有声音"。未经用户请求的播放立即暂停。
        if (playing && !_playingRequested) {
          unawaited(_player!.pause());
          return;
        }
        setState(() => _playing = playing);
      });
      await _player!.open(Media(Uri.file(path).toString()), play: false);
      final target = widget.state.previewTimeMs;
      if (target > 0) await _player!.seek(Duration(milliseconds: target));
      _lastSyncedMs = target;
      if (mounted) setState(() => _playerReady = true);
    } catch (_) {
      // 播放器创建/打开失败时回退到引擎抽帧预览。
      _player = null;
      _controller = null;
      if (mounted) setState(() => _playerReady = false);
    }
  }

  void _syncPlaying(bool playing) {
    if (playing && (!_routeActive || _playback.dialogActive)) return;
    final player = _player;
    if (player == null) return;
    if (playing) {
      unawaited(player.play());
    } else {
      unawaited(player.pause());
    }
  }

  void _seekTo(int timeMs) {
    final player = _player;
    if (player == null) return;
    _lastSyncedMs = timeMs;
    unawaited(player.seek(Duration(milliseconds: timeMs)));
    widget.onPreviewTimeChanged(timeMs);
  }

  void _togglePlaying() {
    if (!_routeActive || _playback.dialogActive) return;
    final player = _player;
    if (player == null || !_playerReady) return;
    if (_playing) {
      _playingRequested = false;
      unawaited(player.pause());
    } else {
      final duration =
          (widget.state.video?['duration_ms'] as num?)?.toInt() ?? 0;
      if (duration > 0 && widget.state.previewTimeMs >= duration) {
        _lastSyncedMs = 0;
        unawaited(player.seek(Duration.zero));
      }
      _playingRequested = true;
      unawaited(player.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final state = widget.state;
    return _InfoPanel(
      title: context.bheText('检测区域'),
      icon: LucideIcons.target,
      subtitle: context.bheText(
        '系统会先自动识别篮筐。橙色区域用于球轨迹，白色区域只覆盖篮网摆动范围；拖动或缩放后会自动保存到草稿。',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.roiSource == 'auto') ...[
            Text(
              context.bheText(
                '系统已自动选择 ${_formatPreviewTime(state.previewTimeMs)} 作为标记画面',
              ),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              context.bheText('篮筐可见度较高，如被遮挡可调整画面时间。'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: Spacing.sm),
          ],
          _RoiCanvas(
            enabled: widget.enabled && !state.previewRefreshing,
            videoController: _playerReady ? _controller : null,
            previewPath: state.previewPath,
            aspectRatio: widget.aspectRatio,
            roi: widget.editingNet ? widget.netRoi : widget.roi,
            secondaryRoi: widget.editingNet ? widget.roi : widget.netRoi,
            activeColor: widget.editingNet ? Colors.white : c.orange,
            secondaryColor: widget.editingNet ? c.orange : Colors.white,
            activeLabel: context.bheText(widget.editingNet ? '篮网检测区' : '投篮分析区'),
            secondaryLabel: context.bheText(
              widget.editingNet ? '投篮分析区' : '篮网检测区',
            ),
            onRefreshPreview: widget.onRefreshPreview,
            onChanged: widget.onChanged,
            onEditComplete: () {},
          ),
          const SizedBox(height: Spacing.sm),
          _PreviewTimeControls(
            timeMs: state.previewTimeMs,
            durationMs: (state.video?['duration_ms'] as num?)?.toInt() ?? 0,
            enabled:
                widget.enabled &&
                !state.roiDetecting &&
                !state.previewRefreshing,
            playing: _playing,
            onStep: _playerReady
                ? _seekTo
                : (timeMs) => widget.onPreviewTimeChanged(timeMs),
            onTogglePlayback: _playerReady
                ? _togglePlaying
                : widget.onPreviewPlaybackToggled,
          ),
          if (state.previewRefreshing) ...[
            const SizedBox(height: Spacing.xs),
            Row(
              children: [
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: c.orange,
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Text(
                  context.bheText('正在切换标记画面…'),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              _CalibrationTargetButton(
                index: '1',
                label: context.bheText('投篮分析区'),
                color: c.orange,
                selected: !widget.editingNet,
                onPressed: widget.enabled
                    ? () => widget.onEditNetChanged(false)
                    : null,
              ),
              const SizedBox(width: Spacing.sm),
              _CalibrationTargetButton(
                index: '2',
                label: context.bheText('篮网检测区'),
                color: Colors.white,
                selected: widget.editingNet,
                onPressed: widget.enabled
                    ? () => widget.onEditNetChanged(true)
                    : null,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: widget.enabled ? widget.onResetCurrent : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 16),
                label: Text(
                  context.bheText(widget.editingNet ? '恢复篮网区' : '恢复投篮区'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            widget.editingNet
                ? context.bheText(
                    '当前编辑白色篮网区域：覆盖篮圈下方到网底，尽量不要包含篮板、球员或地面。',
                  )
                : context.bheText(
                    '当前编辑橙色投篮分析区域：覆盖来球轨迹、篮圈和篮网下方的落球范围。',
                  ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: c.textSecondary,
              height: 1.4,
            ),
          ),
          if (state.roiDetecting) ...[
            const SizedBox(height: Spacing.sm),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: Spacing.xs),
            Text(
              context.bheText('正在自动识别篮筐区域…'),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _ClipWindowSelector extends StatelessWidget {
  const _ClipWindowSelector({
    required this.beforeSeconds,
    required this.afterSeconds,
    required this.onBeforeChanged,
    required this.onAfterChanged,
  });

  final int beforeSeconds;
  final int afterSeconds;
  final ValueChanged<int> onBeforeChanged;
  final ValueChanged<int> onAfterChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final totalSeconds = beforeSeconds + afterSeconds;
    return CsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Spacing.sm,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(
                context.bheText('候选片段长度'),
                style: theme.textTheme.titleSmall,
              ),
              Text(
                l10n?.importClipLengthHint ?? '审核时仍可单独调整每个片段',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: _SecondSelector(
                  key: const Key('clip-before'),
                  label: context.bheText('进球前'),
                  value: beforeSeconds,
                  options: _beforeSecondOptions,
                  onChanged: onBeforeChanged,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: _SecondSelector(
                  key: const Key('clip-after'),
                  label: context.bheText('进球后'),
                  value: afterSeconds,
                  options: _afterSecondOptions,
                  onChanged: onAfterChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(CsRadius.sm),
            child: SizedBox(
              height: 26,
              child: Row(
                children: [
                  if (beforeSeconds > 0)
                    Expanded(
                      flex: beforeSeconds,
                      child: ColoredBox(
                        color: c.orange.withValues(alpha: 0.22),
                        child: Center(
                          child: Text(
                            '${context.bheText('进球前')} $beforeSeconds ${context.bheText('秒')}',
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: c.orange,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Container(width: 2, color: c.warning),
                  Expanded(
                    flex: afterSeconds,
                    child: ColoredBox(
                      color: c.orange.withValues(alpha: 0.12),
                      child: Center(
                        child: Text(
                          '${context.bheText('进球后')} $afterSeconds ${context.bheText('秒')}',
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: c.orange,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              l10n?.importClipTotal(totalSeconds) ?? '每段 $totalSeconds 秒',
              style: theme.textTheme.labelMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Steps through the allowed second options so the value never leaves them.
class _SecondSelector extends StatelessWidget {
  const _SecondSelector({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final index = options.indexOf(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: Spacing.xs),
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(CsRadius.md),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('decrease'),
                tooltip: '−',
                onPressed: index > 0 ? () => onChanged(options[index - 1]) : null,
                icon: const Icon(Icons.remove, size: 18),
              ),
              Expanded(
                child: Text(
                  '$value ${context.bheText('秒')}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('increase'),
                tooltip: '+',
                onPressed: index >= 0 && index < options.length - 1
                    ? () => onChanged(options[index + 1])
                    : null,
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

int _selectedSeconds(
  Object? raw, {
  required int fallback,
  required List<int> options,
}) {
  final value = (raw as num?)?.round();
  return value != null && options.contains(value) ? value : fallback;
}

class _SummaryStep extends StatelessWidget {
  const _SummaryStep({
    required this.state,
    required this.startMs,
    required this.endMs,
    required this.roi,
    required this.netRoi,
    required this.analysisMode,
    required this.beforeSeconds,
    required this.afterSeconds,
    required this.fastModeEnabled,
    required this.onAnalysisModeChanged,
    required this.onBeforeSecondsChanged,
    required this.onAfterSecondsChanged,
    required this.onEditStep,
  });
  final ProjectState state;
  final int startMs;
  final int endMs;
  final Rect? roi;
  final Rect? netRoi;
  final String analysisMode;
  final int beforeSeconds;
  final int afterSeconds;
  final bool fastModeEnabled;
  final ValueChanged<String> onAnalysisModeChanged;
  final ValueChanged<int> onBeforeSecondsChanged;
  final ValueChanged<int> onAfterSecondsChanged;
  final ValueChanged<int>? onEditStep;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final durationMs = (state.video?['duration_ms'] as num?)?.toInt() ?? 0;
    final analyzed = (endMs - startMs).clamp(0, durationMs).toInt();
    final estimate = estimateAnalysisDuration(
      startMs: startMs,
      endMs: endMs,
      width: (state.video?['width'] as num?)?.toInt() ?? 0,
      height: (state.video?['height'] as num?)?.toInt() ?? 0,
      mode: analysisMode,
    );
    Widget regionLine(String label, String value, Color border, bool ok) =>
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  border: Border.all(color: border, width: 1.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: ok ? c.goal : c.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );

    final summary = CsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n?.importSummaryTitle ?? '配置摘要',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          _SummaryRow(
            label: context.bheText('视频'),
            onEdit: onEditStep == null ? null : () => onEditStep!(0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.video?['source_path']
                          ?.toString()
                          .split(RegExp(r'[/\\]'))
                          .last ??
                      '-',
                  style: theme.textTheme.titleSmall,
                ),
                if (state.video != null)
                  Text(
                    _videoSummary(
                      state.video!,
                      noAudio: context.bheText('无音频'),
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          _SummaryRow(
            label: context.bheText('分析范围'),
            onEdit: onEditStep == null ? null : () => onEditStep!(1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_formatDuration(startMs)} – ${_formatDuration(endMs)}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  '${l10n?.importRangeAnalyzed ?? '分析时长'} ${_formatDuration(analyzed)} · '
                  '${l10n?.importRangeExcluded ?? '已排除'} ${_formatDuration(durationMs - analyzed)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          _SummaryRow(
            label: context.bheText('检测区域'),
            onEdit: onEditStep == null ? null : () => onEditStep!(2),
            last: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                regionLine(
                  context.bheText('投篮分析区'),
                  roi == null ? context.bheText('未设置') : context.bheText('已设置'),
                  c.orange,
                  roi != null,
                ),
                regionLine(
                  context.bheText('篮网检测区'),
                  netRoi == null
                      ? context.bheText('自动推荐')
                      : context.bheText('已设置'),
                  c.textPrimary,
                  true,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final settings = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fastModeEnabled) ...[
          Text(
            l10n?.importAnalysisMode ?? '分析模式',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Expanded(
                child: _AnalysisModeOption(
                  key: const Key('analysis-mode-standard'),
                  title: context.bheText('标准分析'),
                  badge: l10n?.importRecommended ?? '推荐',
                  description:
                      l10n?.importStandardDescription ?? '完整检测，漏检更少。',
                  selected: analysisMode != 'fast',
                  onTap: () => onAnalysisModeChanged('standard'),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: _AnalysisModeOption(
                  key: const Key('analysis-mode-fast'),
                  title: context.bheText('快速分析'),
                  description:
                      l10n?.importFastDescription ??
                      '使用低规格代理，更快，但可能漏检少量片段。',
                  selected: analysisMode == 'fast',
                  onTap: () => onAnalysisModeChanged('fast'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
        ],
        _ClipWindowSelector(
          beforeSeconds: beforeSeconds,
          afterSeconds: afterSeconds,
          onBeforeChanged: onBeforeSecondsChanged,
          onAfterChanged: onAfterSecondsChanged,
        ),
        const SizedBox(height: Spacing.md),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(CsRadius.md),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Icon(Icons.schedule_outlined, size: 16, color: c.textSecondary),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  l10n?.importEstimate(context.bheText(estimate.label)) ??
                      '预计耗时 ${estimate.label} · 实际受视频编码、磁盘和设备负载影响',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1000) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 10, child: summary),
              const SizedBox(width: Spacing.lg),
              Expanded(flex: 11, child: settings),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [summary, const SizedBox(height: Spacing.md), settings],
        );
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.child,
    required this.onEdit,
    this.last = false,
  });

  final String label;
  final Widget child;
  final VoidCallback? onEdit;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
          ),
          Expanded(child: child),
          TextButton(
            onPressed: onEdit,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text(l10n?.importEdit ?? '修改'),
          ),
        ],
      ),
    );
  }
}

class _AnalysisModeOption extends StatelessWidget {
  const _AnalysisModeOption({
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    this.badge,
    super.key,
  });

  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? c.orange.withValues(alpha: 0.08) : c.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.md),
          side: BorderSide(
            color: selected ? c.orange : c.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(CsRadius.md),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: selected ? c.orange : c.textTertiary,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: Spacing.xs),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: c.orange.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(CsRadius.xs),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          child: Text(
                            badge!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: c.orange,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textSecondary,
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

class AnalysisDurationEstimate {
  const AnalysisDurationEstimate({
    required this.minimum,
    required this.maximum,
    required this.label,
  });

  final Duration minimum;
  final Duration maximum;
  final String label;
}

/// Gives a deliberately broad preflight estimate rather than pretending to
/// predict the exact runtime before the engine has run on this device.
AnalysisDurationEstimate estimateAnalysisDuration({
  required int startMs,
  required int endMs,
  required int width,
  required int height,
  required String mode,
}) {
  final durationSeconds = ((endMs - startMs).clamp(0, 1 << 31) / 1000)
      .toDouble();
  if (durationSeconds <= 0) {
    return const AnalysisDurationEstimate(
      minimum: Duration.zero,
      maximum: Duration.zero,
      label: '暂无法估算',
    );
  }
  final resolutionFactor = width >= 3840 || height >= 2160
      ? 1.8
      : width >= 2560 || height >= 1440
      ? 1.35
      : width > 0 && height > 0 && width <= 1280
      ? 0.85
      : 1.0;
  final fast = mode == 'fast';
  final minimumSeconds =
      durationSeconds * (fast ? 0.06 : 0.12) * resolutionFactor;
  final maximumSeconds =
      durationSeconds * (fast ? 0.18 : 0.28) * resolutionFactor;
  final minimum = Duration(seconds: minimumSeconds.ceil());
  final maximum = Duration(seconds: maximumSeconds.ceil());
  final minimumMinutes = _formatEstimateMinutes(minimum);
  final maximumMinutes = _formatEstimateMinutes(maximum);
  return AnalysisDurationEstimate(
    minimum: minimum,
    maximum: maximum,
    label: minimumMinutes == maximumMinutes
        ? '约 $minimumMinutes 分钟'
        : '约 $minimumMinutes–$maximumMinutes 分钟',
  );
}

String _formatEstimateMinutes(Duration duration) {
  final minutes = (duration.inSeconds / 60).ceil();
  return '${minutes <= 1 ? 1 : minutes}';
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
  });
  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return CsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: c.textSecondary),
              const SizedBox(width: Spacing.sm),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.textSecondary,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: Spacing.md),
          child,
        ],
      ),
    );
  }
}

Map<String, double>? _rectJson(Rect? rect) => rect == null
    ? null
    : <String, double>{
        'x1': rect.left,
        'y1': rect.top,
        'x2': rect.right,
        'y2': rect.bottom,
      };

Map<String, dynamic>? _rectMap(String key, Rect? rect) =>
    rect == null ? null : <String, dynamic>{key: _rectJson(rect)};

Rect? _rectFromJson(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, dynamic>();
  final x1 = (map['x1'] as num?)?.toDouble();
  final y1 = (map['y1'] as num?)?.toDouble();
  final x2 = (map['x2'] as num?)?.toDouble();
  final y2 = (map['y2'] as num?)?.toDouble();
  if ([x1, y1, x2, y2].any((value) => value == null)) return null;
  return Rect.fromLTRB(x1!, y1!, x2!, y2!);
}

String _videoSummary(JsonMap video, {required String noAudio}) {
  final w = video['width'] ?? '-';
  final h = video['height'] ?? '-';
  final fps = (video['fps'] as num?)?.toStringAsFixed(2) ?? '-';
  final duration = (video['duration_ms'] as num?)?.toInt() ?? 0;
  final codec = video['video_codec'] ?? '-';
  final audio = video['audio_codec'] ?? noAudio;
  return '$w×$h · $fps fps · ${_formatDuration(duration)} · $codec / $audio';
}

int _analysisStart(ProjectState state) =>
    (state.video?['analysis_start_ms'] as num?)?.toInt() ?? 0;

int _analysisEnd(ProjectState state) =>
    (state.video?['analysis_end_ms'] as num?)?.toInt() ??
    ((state.video?['duration_ms'] as num?)?.toInt() ?? 0);

String _formatPreviewTime(int milliseconds) {
  final safe = milliseconds.clamp(0, 24 * 60 * 60 * 1000).toInt();
  final seconds = safe ~/ 1000;
  final tenths = (safe % 1000) ~/ 100;
  final minutes = seconds ~/ 60;
  final remaining = seconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remaining.toString().padLeft(2, '0')}.$tenths';
}

String _formatDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remaining.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remaining.toString().padLeft(2, '0')}';
}

class _AnalysisRangeEditor extends ConsumerStatefulWidget {
  const _AnalysisRangeEditor({
    required this.videoPath,
    required this.durationMs,
    required this.aspectRatio,
    required this.startMs,
    required this.endMs,
    required this.enabled,
    required this.onChanged,
    required this.onCommit,
  });

  final String? videoPath;
  final int durationMs;
  final double aspectRatio;
  final int startMs;
  final int endMs;
  final bool enabled;
  final void Function(int startMs, int endMs) onChanged;
  final Future<void> Function(int startMs, int endMs) onCommit;

  @override
  ConsumerState<_AnalysisRangeEditor> createState() =>
      _AnalysisRangeEditorState();
}

class _AnalysisRangeEditorState extends ConsumerState<_AnalysisRangeEditor> {
  late final _playback = ref.read(playbackCoordinatorProvider);
  bool _routeActive = true;

  Future<void> _pauseForDialog() async {
    _playbackRequested = false;
    await _player?.pause();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeActive = TickerMode.valuesOf(context).enabled;
    if (!_routeActive) {
      unawaited(
        _pauseForDialog().catchError((Object error) {
          debugPrint('Hidden range preview pause failed: $error');
        }),
      );
    }
  }

  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  late int _startMs = widget.startMs;
  late int _endMs = widget.endMs;
  int _positionMs = 0;
  bool _playing = false;
  bool _playbackRequested = false;
  bool _ready = false;
  String? _error;
  bool _saving = false;
  int _mediaGeneration = 0;

  @override
  void initState() {
    super.initState();
    _playback.register(this, _pauseForDialog);
    _openVideo();
  }

  @override
  void didUpdateWidget(covariant _AnalysisRangeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _openVideo();
    } else {
      if (oldWidget.startMs != widget.startMs) _startMs = widget.startMs;
      if (oldWidget.endMs != widget.endMs) _endMs = widget.endMs;
    }
  }

  Future<void> _openVideo() async {
    final generation = ++_mediaGeneration;
    final path = widget.videoPath;
    await _positionSubscription?.cancel();
    await _playingSubscription?.cancel();
    // 复用已存在的 Player/VideoController:在 Video 纹理仍在渲染时调用
    // player.dispose() 会触发原生 ~VideoOutput 析构,在 Windows 上与
    // 光栅线程死锁导致整个应用无响应。仅组件卸载时才销毁。
    if (_player == null && path != null && path.isNotEmpty) {
      _player = Player();
      _controller = VideoController(
        _player!,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !Platform.isWindows,
        ),
      );
    }
    if (mounted) {
      setState(() {
        _ready = false;
        _playing = false;
        _playbackRequested = false;
        _error = null;
      });
    }
    if (path == null || path.isEmpty || !File(path).existsSync()) return;
    final player = _player!;
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted || generation != _mediaGeneration) return;
      final value = position.inMilliseconds;
      if ((value - _positionMs).abs() >= 100) {
        setState(() => _positionMs = value.clamp(0, widget.durationMs));
      }
    });
    _playingSubscription = player.stream.playing.listen((playing) {
      if (playing && !_playbackRequested) {
        unawaited(player.pause());
        return;
      }
      if (mounted && generation == _mediaGeneration) {
        setState(() => _playing = playing);
      }
    });
    try {
      await player.open(Media(Uri.file(path).toString()), play: false);
      _playbackRequested = false;
      await player.pause();
      if (mounted &&
          generation == _mediaGeneration &&
          identical(player, _player)) {
        setState(() {
          _ready = true;
          _error = null;
          _playing = player.state.playing;
        });
      }
    } catch (error) {
      if (mounted &&
          generation == _mediaGeneration &&
          identical(player, _player)) {
        setState(() {
          _ready = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _playback.unregister(this);
    _mediaGeneration++;
    unawaited(_positionSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    final player = _player;
    _player = null;
    _controller = null;
    unawaited(() async {
      if (player == null) return;
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }());
    super.dispose();
  }

  Future<void> _seek(int value) async {
    final target = value.clamp(0, widget.durationMs).toInt();
    if (mounted) setState(() => _positionMs = target);
    await _player?.seek(Duration(milliseconds: target));
  }

  Future<void> _togglePlayback() async {
    if (!_routeActive || _playback.dialogActive) return;
    final player = _player;
    if (player == null) return;
    if (player.state.playing) {
      _playbackRequested = false;
      await player.pause();
    } else {
      _playbackRequested = true;
      await player.play();
    }
  }

  Future<void> _commitRange(int startMs, int endMs) async {
    if (_saving) return;
    _saving = true;
    try {
      await widget.onCommit(startMs, endMs);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.durationMs <= 1000) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final start = _startMs.clamp(0, widget.durationMs - 1000).toInt();
    final end = _endMs.clamp(start + 1000, widget.durationMs).toInt();
    final fullRange = start == 0 && end == widget.durationMs;
    final controller = _controller;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fullRange
                ? context.bheText(
                    '默认扫描完整视频。播放视频后设定起点和终点，可排除热身或结束部分。',
                  )
                : context.bheText(
                    '仅扫描 ${_formatDuration(start)} - ${_formatDuration(end)}。',
                  ),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: c.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          ConstrainedBox(
            // Keep the timeline and footer on screen for tall sources.
            constraints: const BoxConstraints(maxHeight: 440),
            child: Center(
              child: AspectRatio(
                key: const Key('analysis-range-video-frame'),
            aspectRatio: widget.aspectRatio,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black),
              child: _error != null
                  ? Center(
                      child: Text(
                        context.bheText('视频加载失败，请重新进入此步骤。'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.error, fontSize: 12),
                      ),
                    )
                  : controller == null || !_ready
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Video(
                              controller: controller,
                              // 框已是视频比例。Windows 软件渲染的纹理比例可能
                              // 不对、里面带黑边,cover 正好把黑边裁掉。
                              fit: BoxFit.cover,
                              controls: NoVideoControls,
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _ready
                                ? () => unawaited(_togglePlayback())
                                : null,
                            child: AnimatedOpacity(
                              opacity: _playing ? 0 : 1,
                              duration: const Duration(milliseconds: 160),
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.62),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.all(14),
                                    child: Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: Spacing.xs,
                          right: Spacing.xs,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.64),
                              borderRadius: BorderRadius.circular(CsRadius.xs),
                            ),
                            child: Text(
                              _formatDuration(_positionMs),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              IconButton(
                tooltip: context.bheText('播放/暂停'),
                onPressed: _ready ? () => unawaited(_togglePlayback()) : null,
                icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  context.bheText('拖动下方两个手柄，视频会跳到正在调整的位置。'),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
                ),
              ),
            ],
          ),
          _AnalysisTimeline(
            durationMs: widget.durationMs,
            positionMs: _positionMs,
            startMs: start,
            endMs: end,
            enabled: widget.enabled,
            onSeek: (value) => unawaited(_seek(value)),
            onRangeChanged: (nextStart, nextEnd, seekTarget) {
              setState(() {
                _startMs = nextStart;
                _endMs = nextEnd;
              });
              widget.onChanged(nextStart, nextEnd);
              unawaited(_seek(seekTarget));
            },
            onRangeCommit: (nextStart, nextEnd) =>
                unawaited(_commitRange(nextStart, nextEnd)),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.lg,
            runSpacing: Spacing.sm,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _RangeHandleControls(
                keyPrefix: 'analysis-start',
                label: context.bheText('起点 ${_formatDuration(start)}'),
                setLabel:
                    Localizations.of<BheLocalizations>(
                      context,
                      BheLocalizations,
                    )?.importSetStart ??
                    '设为起点',
                enabled: widget.enabled,
                onNudge: (delta) =>
                    _applyRange(start + delta, end, start + delta),
                onSetHere: _ready
                    ? () => _applyRange(_positionMs, end, _positionMs)
                    : null,
              ),
              _RangeHandleControls(
                keyPrefix: 'analysis-end',
                label: context.bheText('终点 ${_formatDuration(end)}'),
                setLabel:
                    Localizations.of<BheLocalizations>(
                      context,
                      BheLocalizations,
                    )?.importSetEnd ??
                    '设为终点',
                enabled: widget.enabled,
                onNudge: (delta) => _applyRange(start, end + delta, end + delta),
                onSetHere: _ready
                    ? () => _applyRange(start, _positionMs, _positionMs)
                    : null,
              ),
              TextButton.icon(
                onPressed: widget.enabled && !fullRange
                    ? () => _applyRange(0, widget.durationMs, 0)
                    : null,
                icon: const Icon(Icons.unfold_more_rounded, size: 16),
                label: Text(context.bheText('使用全片')),
              ),
            ],
          ),
        ],
    );
  }

  void _applyRange(int startMs, int endMs, int seekTarget) {
    if (!widget.enabled) return;
    final start = startMs.clamp(0, widget.durationMs - 1000).toInt();
    final end = endMs.clamp(start + 1000, widget.durationMs).toInt();
    final adjustedStart = start.clamp(0, end - 1000).toInt();
    setState(() {
      _startMs = adjustedStart;
      _endMs = end;
    });
    widget.onChanged(adjustedStart, end);
    unawaited(_commitRange(adjustedStart, end));
    unawaited(_seek(seekTarget.clamp(0, widget.durationMs).toInt()));
  }
}

class _RangeHandleControls extends StatelessWidget {
  const _RangeHandleControls({
    required this.keyPrefix,
    required this.label,
    required this.setLabel,
    required this.enabled,
    required this.onNudge,
    required this.onSetHere,
  });

  final String keyPrefix;
  final String label;
  final String setLabel;
  final bool enabled;
  final ValueChanged<int> onNudge;
  final VoidCallback? onSetHere;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final compact = OutlinedButton.styleFrom(
      foregroundColor: c.textSecondary,
      side: BorderSide(color: c.border),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: c.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              key: ValueKey('$keyPrefix-minus'),
              style: compact,
              onPressed: enabled ? () => onNudge(-5000) : null,
              child: Text(context.bheText('−5 秒')),
            ),
            const SizedBox(width: Spacing.xs),
            OutlinedButton(
              key: ValueKey('$keyPrefix-plus'),
              style: compact,
              onPressed: enabled ? () => onNudge(5000) : null,
              child: Text(context.bheText('+5 秒')),
            ),
            const SizedBox(width: Spacing.xs),
            OutlinedButton.icon(
              key: ValueKey('$keyPrefix-set'),
              style: compact.copyWith(
                foregroundColor: WidgetStatePropertyAll(c.textPrimary),
              ),
              onPressed: enabled ? onSetHere : null,
              icon: const Icon(Icons.my_location_rounded, size: 15),
              label: Text(setLabel),
            ),
          ],
        ),
      ],
    );
  }
}

class _AnalysisTimeline extends StatefulWidget {
  const _AnalysisTimeline({
    required this.durationMs,
    required this.positionMs,
    required this.startMs,
    required this.endMs,
    required this.enabled,
    required this.onSeek,
    required this.onRangeChanged,
    required this.onRangeCommit,
  });

  final int durationMs;
  final int positionMs;
  final int startMs;
  final int endMs;
  final bool enabled;
  final ValueChanged<int> onSeek;
  final void Function(int startMs, int endMs, int seekTarget) onRangeChanged;
  final void Function(int startMs, int endMs) onRangeCommit;

  @override
  State<_AnalysisTimeline> createState() => _AnalysisTimelineState();
}

class _AnalysisTimelineState extends State<_AnalysisTimeline> {
  int _dragTarget = -1;
  int _lastStartMs = 0;
  int _lastEndMs = 0;

  int _valueFor(double x, double width) {
    if (width <= 0 || widget.durationMs <= 0) return 0;
    return (x.clamp(0.0, width) / width * widget.durationMs).round();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: 92,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 0.0;
          double xFor(int value) =>
              (value / widget.durationMs * width).clamp(0.0, width).toDouble();
          final positionX = xFor(widget.positionMs);
          final common = _AnalysisTimelineStyle(
            rangeColor: c.orange,
            trackColor: c.surface3,
            outsideColor: c.background.withValues(alpha: .58),
            handleColor: c.textPrimary,
            playheadColor: c.orange,
          );
          return Column(
            children: [
              Row(
                children: [
                  Text(
                    context.bheText('播放进度'),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const Spacer(),
                  Text(
                    _formatDuration(widget.positionMs),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    context.bheText('分析范围'),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const Spacer(),
                  Text(
                    '${_formatDuration(widget.startMs)} - ${_formatDuration(widget.endMs)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: MouseRegion(
                  cursor: widget.enabled
                      ? (_dragTarget >= 0
                            ? SystemMouseCursors.resizeLeftRight
                            : SystemMouseCursors.click)
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: widget.enabled
                        ? (details) => widget.onSeek(
                            _valueFor(details.localPosition.dx, width),
                          )
                        : null,
                    onPanStart: widget.enabled
                        ? (details) {
                            final startX = xFor(widget.startMs);
                            final endX = xFor(widget.endMs);
                            final x = details.localPosition.dx;
                            final startDistance = (x - startX).abs();
                            final endDistance = (x - endX).abs();
                            const handleHitSize = 30.0;
                            if (startDistance <= handleHitSize ||
                                endDistance <= handleHitSize) {
                              _dragTarget = startDistance <= endDistance
                                  ? 0
                                  : 1;
                            } else {
                              _dragTarget = -1;
                            }
                            _lastStartMs = widget.startMs;
                            _lastEndMs = widget.endMs;
                          }
                        : null,
                    onPanUpdate: widget.enabled
                        ? (details) {
                            final value = _valueFor(
                              details.localPosition.dx,
                              width,
                            );
                            if (_dragTarget == 0) {
                              final nextStart = value
                                  .clamp(0, widget.endMs - 1000)
                                  .toInt();
                              _lastStartMs = nextStart;
                              widget.onRangeChanged(
                                nextStart,
                                widget.endMs,
                                nextStart,
                              );
                            } else if (_dragTarget == 1) {
                              final nextEnd = value
                                  .clamp(
                                    widget.startMs + 1000,
                                    widget.durationMs,
                                  )
                                  .toInt();
                              _lastEndMs = nextEnd;
                              widget.onRangeChanged(
                                widget.startMs,
                                nextEnd,
                                nextEnd,
                              );
                            } else {
                              widget.onSeek(value);
                            }
                          }
                        : null,
                    onPanEnd: widget.enabled
                        ? (_) {
                            final target = _dragTarget;
                            _dragTarget = -1;
                            if (target == 0 || target == 1) {
                              widget.onRangeCommit(_lastStartMs, _lastEndMs);
                            }
                          }
                        : null,
                    onPanCancel: widget.enabled
                        ? () => setState(() => _dragTarget = -1)
                        : null,
                    child: CustomPaint(
                      size: Size(width, 42),
                      painter: _UnifiedTimelinePainter(
                        positionX: positionX,
                        startX: xFor(widget.startMs),
                        endX: xFor(widget.endMs),
                        style: common,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AnalysisTimelineStyle {
  const _AnalysisTimelineStyle({
    required this.rangeColor,
    required this.trackColor,
    required this.outsideColor,
    required this.handleColor,
    required this.playheadColor,
  });

  final Color rangeColor;
  final Color trackColor;
  final Color outsideColor;
  final Color handleColor;
  final Color playheadColor;
}

class _UnifiedTimelinePainter extends CustomPainter {
  const _UnifiedTimelinePainter({
    required this.positionX,
    required this.startX,
    required this.endX,
    required this.style,
  });

  final double positionX;
  final double startX;
  final double endX;
  final _AnalysisTimelineStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2 + 1;
    final trackLeft = 9.0;
    final trackRight = size.width - 9.0;
    final trackWidth = (trackRight - trackLeft).clamp(0.0, size.width);
    final start = trackLeft + (startX / size.width * trackWidth);
    final end = trackLeft + (endX / size.width * trackWidth);
    final position = trackLeft + (positionX / size.width * trackWidth);
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(trackLeft, y - 4, trackWidth, 8),
      const Radius.circular(3),
    );
    canvas.drawRRect(track, Paint()..color = style.trackColor);
    canvas.drawRect(
      Rect.fromLTRB(trackLeft, y - 4, start, y + 4),
      Paint()..color = style.outsideColor,
    );
    canvas.drawRect(
      Rect.fromLTRB(end, y - 4, trackRight, y + 4),
      Paint()..color = style.outsideColor,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(start, y - 4, end, y + 4),
        const Radius.circular(3),
      ),
      Paint()..color = style.rangeColor,
    );
    final playhead = Paint()
      ..color = style.playheadColor
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(position, y - 18),
      Offset(position, y + 18),
      playhead,
    );
    canvas.drawCircle(Offset(position, y - 18), 4, playhead);
    for (final x in [start, end]) {
      final handle = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y), width: 14, height: 28),
        const Radius.circular(5),
      );
      canvas.drawRRect(handle, Paint()..color = style.handleColor);
      canvas.drawLine(
        Offset(x, y - 7),
        Offset(x, y + 7),
        Paint()
          ..color = style.rangeColor
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UnifiedTimelinePainter oldDelegate) =>
      oldDelegate.positionX != positionX ||
      oldDelegate.startX != startX ||
      oldDelegate.endX != endX ||
      oldDelegate.style.rangeColor != style.rangeColor;
}

class _PreviewTimeControls extends StatelessWidget {
  const _PreviewTimeControls({
    required this.timeMs,
    required this.durationMs,
    required this.enabled,
    required this.playing,
    required this.onStep,
    required this.onTogglePlayback,
  });

  final int timeMs;
  final int durationMs;
  final bool enabled;
  final bool playing;
  final ValueChanged<int> onStep;
  final VoidCallback onTogglePlayback;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final step = (timeMs + 5000).clamp(0, durationMs).toInt();
    final back = (timeMs - 5000).clamp(0, durationMs).toInt();
    return Row(
      children: [
        Text(
          context.bheText('标记画面'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          _formatPreviewTime(timeMs),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: c.orange,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        OutlinedButton(
          onPressed: enabled && timeMs > 0 ? () => onStep(back) : null,
          child: Text(context.bheText('−5 秒')),
        ),
        const SizedBox(width: Spacing.xs),
        OutlinedButton.icon(
          onPressed: enabled && (playing || timeMs < durationMs)
              ? onTogglePlayback
              : null,
          icon: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 16,
          ),
          label: Text(context.bheText(playing ? '暂停' : '播放')),
        ),
        const SizedBox(width: Spacing.xs),
        OutlinedButton(
          onPressed: enabled && timeMs < durationMs ? () => onStep(step) : null,
          child: Text(context.bheText('+5 秒')),
        ),
      ],
    );
  }
}

class _CalibrationTargetButton extends StatelessWidget {
  const _CalibrationTargetButton({
    required this.index,
    required this.label,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String index;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final selectedColor = color == Colors.white ? c.orange : color;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? c.textPrimary : c.textSecondary,
        backgroundColor: selected
            ? selectedColor.withValues(alpha: 0.14)
            : Colors.transparent,
        side: BorderSide(
          color: selected ? selectedColor : c.borderStrong,
          width: selected ? 1.5 : 1,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? selectedColor : color,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              index,
              style: TextStyle(
                fontSize: 11,
                color: color == Colors.white ? Colors.black : Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

/// ROI 拖拽画布。pan 逻辑迁移自 3700bbc(原样),仅视觉精致化:
/// 边框 `border` → 激活 `orange`,选区 `orange` 18% + 2px + 四角手柄。
class _RoiCanvas extends StatefulWidget {
  const _RoiCanvas({
    required this.enabled,
    required this.previewPath,
    required this.aspectRatio,
    required this.roi,
    required this.secondaryRoi,
    required this.activeColor,
    required this.secondaryColor,
    required this.activeLabel,
    required this.secondaryLabel,
    required this.onRefreshPreview,
    required this.onChanged,
    required this.onEditComplete,
    this.videoController,
  });

  final bool enabled;
  final String? previewPath;
  final VideoController? videoController;
  final double aspectRatio;
  final Rect? roi;
  final Rect? secondaryRoi;
  final Color activeColor;
  final Color secondaryColor;
  final String activeLabel;
  final String secondaryLabel;
  final VoidCallback? onRefreshPreview;
  final ValueChanged<Rect> onChanged;
  final VoidCallback onEditComplete;

  @override
  State<_RoiCanvas> createState() => _RoiCanvasState();
}

class _RoiCanvasState extends State<_RoiCanvas> {
  Offset? _start;
  Rect? _initialRect;
  _RoiDragMode? _dragMode;
  double _zoom = 1;
  Alignment _focus = Alignment.center;
  final FocusNode _focusNode = FocusNode(debugLabel: 'roi-canvas');
  bool _changedSinceDrag = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _RoiCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeLabel != widget.activeLabel) {
      _zoom = 1;
      _focus = _alignmentFor(widget.roi);
    }
  }

  Alignment _alignmentFor(Rect? roi) {
    final center = roi?.center ?? const Offset(0.5, 0.5);
    return Alignment(center.dx * 2 - 1, center.dy * 2 - 1);
  }

  void _changeZoom(double delta) {
    setState(() {
      _zoom = (_zoom + delta).clamp(1.0, 4.0);
      _focus = _alignmentFor(widget.roi);
    });
  }

  void _resetZoom() {
    setState(() {
      _zoom = 1;
      _focus = Alignment.center;
    });
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!widget.enabled ||
        !_focusNode.hasFocus ||
        event is! PointerScrollEvent) {
      return;
    }
    final direction = event.scrollDelta.dy.sign;
    if (direction == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (mounted) _changeZoom(-direction * 0.25);
    });
  }

  Offset _toCanvasPoint(Offset point, Size size) {
    if (_zoom == 1) return point;
    final anchor = Offset(
      ((_focus.x + 1) / 2) * size.width,
      ((_focus.y + 1) / 2) * size.height,
    );
    return Offset(
      anchor.dx + (point.dx - anchor.dx) / _zoom,
      anchor.dy + (point.dy - anchor.dy) / _zoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: widget.enabled ? c.surface2 : c.surface3,
              borderRadius: BorderRadius.circular(CsRadius.lg),
              border: Border.all(
                color: widget.enabled ? c.orange : c.border,
                width: widget.enabled ? 1.5 : 1,
              ),
            ),
            child: Stack(
              children: [
                Focus(
                  focusNode: _focusNode,
                  child: Listener(
                    onPointerSignal: _handlePointerSignal,
                    child: ClipRect(
                      child: Transform.scale(
                        alignment: _focus,
                        scale: _zoom,
                        transformHitTests: false,
                        child: GestureDetector(
                          onTapDown: widget.enabled
                              ? (_) => _focusNode.requestFocus()
                              : null,
                          onPanStart: widget.enabled
                              ? (details) => _beginDrag(
                                  _toCanvasPoint(
                                    details.localPosition,
                                    constraints.biggest,
                                  ),
                                  constraints.biggest,
                                )
                              : null,
                          onPanUpdate:
                              widget.enabled &&
                                  _start != null &&
                                  _dragMode != null
                              ? (details) => _updateDrag(
                                  _toCanvasPoint(
                                    details.localPosition,
                                    constraints.biggest,
                                  ),
                                  constraints.biggest,
                                )
                              : null,
                          onPanEnd: widget.enabled
                              ? (_) {
                                  final changed = _changedSinceDrag;
                                  setState(() {
                                    _start = null;
                                    _initialRect = null;
                                    _dragMode = null;
                                    _changedSinceDrag = false;
                                  });
                                  if (changed) widget.onEditComplete();
                                }
                              : null,
                          child: Stack(
                            children: [
                              if (widget.videoController != null)
                                Positioned.fill(
                                  child: Video(
                                    controller: widget.videoController!,
                                    // 框已是视频比例。Windows 软件渲染的纹理比例
                                    // 可能不对、里面带黑边,cover 正好把黑边裁掉,
                                    // 画面才和检测框对齐。
                                    fit: BoxFit.cover,
                                    controls: NoVideoControls,
                                  ),
                                )
                              else if (widget.previewPath != null &&
                                  File(widget.previewPath!).existsSync())
                                Positioned.fill(
                                  child: Image.file(
                                    File(widget.previewPath!),
                                    fit: BoxFit.fill,
                                    errorBuilder: (context, error, _) => Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(
                                          Spacing.md,
                                        ),
                                        child: Text(
                                          context.bheText('预览加载失败，请重新生成。'),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: c.error,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              else if (!widget.enabled)
                                Center(
                                  child: CsEmptyState(
                                    icon: LucideIcons.lock,
                                    title: context.bheText('请先选择视频'),
                                    description: context.bheText(
                                      '选择原始视频后即可框选篮筐区域。',
                                    ),
                                  ),
                                )
                              else if (widget.previewPath != null)
                                Center(
                                  child: CsEmptyState(
                                    icon: LucideIcons.circleAlert,
                                    title: context.bheText('预览帧不可用'),
                                    description: context.bheText(
                                      '视频元数据已读取，可以重新生成预览后继续框选。',
                                    ),
                                    action: widget.onRefreshPreview == null
                                        ? null
                                        : CsButton(
                                            label: Text(
                                              context.bheText('重新生成预览'),
                                            ),
                                            icon: LucideIcons.refreshCw,
                                            variant: CsButtonVariant.secondary,
                                            size: CsButtonSize.sm,
                                            onPressed: widget.onRefreshPreview,
                                          ),
                                  ),
                                )
                              else
                                Center(
                                  child: CsEmptyState(
                                    icon: LucideIcons.film,
                                    title: context.bheText('正在准备视频预览'),
                                    description: context.bheText(
                                      '预览准备好后即可拖拽框选篮筐区域。',
                                    ),
                                    action: widget.onRefreshPreview == null
                                        ? null
                                        : CsButton(
                                            label: Text(
                                              context.bheText('生成预览'),
                                            ),
                                            icon: LucideIcons.refreshCw,
                                            variant: CsButtonVariant.secondary,
                                            size: CsButtonSize.sm,
                                            onPressed: widget.onRefreshPreview,
                                          ),
                                  ),
                                ),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _RoiPainter(
                                    roi: widget.secondaryRoi,
                                    color: widget.secondaryColor,
                                    label: widget.secondaryLabel,
                                    viewportScale: _zoom,
                                  ),
                                ),
                              ),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _RoiPainter(
                                    roi: widget.roi,
                                    color: widget.activeColor,
                                    label: widget.activeLabel,
                                    viewportScale: _zoom,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: Spacing.xs,
                  left: Spacing.xs,
                  child: Material(
                    color: c.background.withValues(alpha: 0.76),
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: context.bheText('缩小'),
                          onPressed: _zoom > 1 ? () => _changeZoom(-0.5) : null,
                          icon: const Icon(Icons.remove_rounded, size: 16),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        Text(
                          '${(_zoom * 100).round()}%',
                          style: TextStyle(color: c.textPrimary, fontSize: 11),
                        ),
                        IconButton(
                          tooltip: context.bheText('放大'),
                          onPressed: _zoom < 4 ? () => _changeZoom(0.5) : null,
                          icon: const Icon(Icons.add_rounded, size: 16),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        IconButton(
                          tooltip: context.bheText('适应画面'),
                          onPressed: _zoom > 1 ? _resetZoom : null,
                          icon: const Icon(Icons.fit_screen_outlined, size: 15),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 像素坐标 → 归一化 [0,1]。迁移自 3700bbc(逻辑层不动)。
  Rect _normalizedRect(Offset start, Offset end, Size size) {
    final left =
        (start.dx < end.dx ? start.dx : end.dx).clamp(0.0, size.width) /
        size.width;
    final top =
        (start.dy < end.dy ? start.dy : end.dy).clamp(0.0, size.height) /
        size.height;
    final right =
        (start.dx > end.dx ? start.dx : end.dx).clamp(0.0, size.width) /
        size.width;
    final bottom =
        (start.dy > end.dy ? start.dy : end.dy).clamp(0.0, size.height) /
        size.height;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _beginDrag(Offset point, Size size) {
    final current = widget.roi;
    _RoiDragMode mode = _RoiDragMode.create;
    if (current != null) {
      final rect = Rect.fromLTRB(
        current.left * size.width,
        current.top * size.height,
        current.right * size.width,
        current.bottom * size.height,
      );
      const handleRadius = 14.0;
      if ((point - rect.topLeft).distance <= handleRadius) {
        mode = _RoiDragMode.topLeft;
      } else if ((point - rect.topRight).distance <= handleRadius) {
        mode = _RoiDragMode.topRight;
      } else if ((point - rect.bottomLeft).distance <= handleRadius) {
        mode = _RoiDragMode.bottomLeft;
      } else if ((point - rect.bottomRight).distance <= handleRadius) {
        mode = _RoiDragMode.bottomRight;
      } else if (rect.contains(point)) {
        mode = _RoiDragMode.move;
      }
    }
    setState(() {
      _start = point;
      _initialRect = current;
      _dragMode = mode;
      _changedSinceDrag = false;
    });
  }

  void _updateDrag(Offset point, Size size) {
    final start = _start;
    final mode = _dragMode;
    if (start == null || mode == null) return;
    final base = _initialRect;
    _changedSinceDrag = true;
    if (mode == _RoiDragMode.create || base == null) {
      widget.onChanged(_normalizedRect(start, point, size));
      return;
    }
    final normalized = Offset(
      (point.dx / size.width).clamp(0.0, 1.0),
      (point.dy / size.height).clamp(0.0, 1.0),
    );
    const minimum = 0.03;
    if (mode == _RoiDragMode.move) {
      final dx = (point.dx - start.dx) / size.width;
      final dy = (point.dy - start.dy) / size.height;
      final left = (base.left + dx).clamp(0.0, 1.0 - base.width);
      final top = (base.top + dy).clamp(0.0, 1.0 - base.height);
      widget.onChanged(Rect.fromLTWH(left, top, base.width, base.height));
      return;
    }
    var left = base.left;
    var top = base.top;
    var right = base.right;
    var bottom = base.bottom;
    switch (mode) {
      case _RoiDragMode.topLeft:
        left = normalized.dx.clamp(0.0, right - minimum);
        top = normalized.dy.clamp(0.0, bottom - minimum);
        break;
      case _RoiDragMode.topRight:
        right = normalized.dx.clamp(left + minimum, 1.0);
        top = normalized.dy.clamp(0.0, bottom - minimum);
        break;
      case _RoiDragMode.bottomLeft:
        left = normalized.dx.clamp(0.0, right - minimum);
        bottom = normalized.dy.clamp(top + minimum, 1.0);
        break;
      case _RoiDragMode.bottomRight:
        right = normalized.dx.clamp(left + minimum, 1.0);
        bottom = normalized.dy.clamp(top + minimum, 1.0);
        break;
      case _RoiDragMode.create:
      case _RoiDragMode.move:
        break;
    }
    widget.onChanged(Rect.fromLTRB(left, top, right, bottom));
  }
}

enum _RoiDragMode { create, move, topLeft, topRight, bottomLeft, bottomRight }

/// ROI 选区绘制:18% 填充 + 2px 描边 + 四角手柄。
class _RoiPainter extends CustomPainter {
  const _RoiPainter({
    required this.roi,
    required this.color,
    required this.label,
    required this.viewportScale,
  });

  final Rect? roi;
  final Color color;
  final String label;
  final double viewportScale;

  @override
  void paint(Canvas canvas, Size size) {
    final value = roi;
    if (value == null) return;
    final rect = Rect.fromLTRB(
      value.left * size.width,
      value.top * size.height,
      value.right * size.width,
      value.bottom * size.height,
    );
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.18));
    final inverseScale = 1 / viewportScale;
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = inverseScale,
    );
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color == Colors.white ? Colors.black : Colors.white,
          fontSize: 11 * inverseScale,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final padding = 4 * inverseScale;
    final labelWidth = textPainter.width + padding * 2;
    final labelHeight = textPainter.height + padding;
    final preferredTop = rect.top - labelHeight - padding;
    final labelRect = Rect.fromLTWH(
      rect.left.clamp(0.0, size.width - labelWidth),
      preferredTop >= 0
          ? preferredTop
          : (rect.bottom + padding).clamp(0.0, size.height - labelHeight),
      labelWidth,
      labelHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(3)),
      Paint()..color = color,
    );
    textPainter.paint(canvas, labelRect.topLeft + Offset(padding, padding / 2));
    // 四角手柄
    final handle = 6 * inverseScale;
    final paint = Paint()..color = color;
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: corner, width: handle, height: handle),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoiPainter oldDelegate) =>
      oldDelegate.roi != roi ||
      oldDelegate.color != color ||
      oldDelegate.label != label ||
      oldDelegate.viewportScale != viewportScale;
}

/// 一个项目里多段视频的列表：逐段确认篮筐、调整顺序、看排队分析进度。
class _VideoSegmentList extends StatelessWidget {
  const _VideoSegmentList({
    required this.state,
    required this.busy,
    required this.beforeSeconds,
    required this.afterSeconds,
    required this.onBeforeChanged,
    required this.onAfterChanged,
    required this.onAddVideos,
    required this.onEdit,
    required this.onMove,
    required this.onRemoveFromQueue,
    required this.onPauseQueue,
    required this.onResumeQueue,
  });

  final ProjectState state;
  final bool busy;
  final int beforeSeconds;
  final int afterSeconds;
  final ValueChanged<int> onBeforeChanged;
  final ValueChanged<int> onAfterChanged;
  final VoidCallback? onAddVideos;
  final ValueChanged<String> onEdit;
  final void Function(String videoId, int offset) onMove;
  final ValueChanged<String> onRemoveFromQueue;
  final VoidCallback onPauseQueue;
  final VoidCallback onResumeQueue;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final videos = state.videos;
    final totalMs = videos.fold<int>(
      0,
      (sum, video) => sum + ((video['duration_ms'] as num?)?.toInt() ?? 0),
    );
    final queueActive = state.analysisQueue.isNotEmpty;
    final reorderLocked = busy || state.analysisRunning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoPanel(
          title:
              '${context.bheText('这场比赛的视频')} · ${videos.length} · ${_formatDuration(totalMs)}',
          icon: LucideIcons.listVideo,
          subtitle: context.bheText(
            '每段都设置好篮筐后，点「分析全部」会按顺序逐段分析，分析完的段可以先去审核。',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, video) in videos.indexed) ...[
                if (index > 0) Divider(height: 1, color: c.border),
                _VideoSegmentRow(
                  key: ValueKey('video-segment-${video['id']}'),
                  segment: index + 1,
                  video: video,
                  state: state,
                  active: video['id'] == state.video?['id'],
                  onEdit: busy ? null : () => onEdit(video['id'].toString()),
                  onMoveUp: reorderLocked || index == 0
                      ? null
                      : () => onMove(video['id'].toString(), -1),
                  onMoveDown: reorderLocked || index == videos.length - 1
                      ? null
                      : () => onMove(video['id'].toString(), 1),
                  onRemoveFromQueue: () =>
                      onRemoveFromQueue(video['id'].toString()),
                ),
              ],
              const SizedBox(height: Spacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: CsButton(
                  label: Text(context.bheText('添加视频')),
                  icon: LucideIcons.plus,
                  variant: CsButtonVariant.secondary,
                  onPressed: onAddVideos,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        _InfoPanel(
          title: context.bheText('分析设置'),
          icon: LucideIcons.slidersHorizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ClipWindowSelector(
                beforeSeconds: beforeSeconds,
                afterSeconds: afterSeconds,
                onBeforeChanged: onBeforeChanged,
                onAfterChanged: onAfterChanged,
              ),
              if (queueActive) ...[
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Icon(
                      state.queuePaused
                          ? LucideIcons.pauseCircle
                          : LucideIcons.loader,
                      size: 16,
                      color: state.queuePaused ? c.warning : c.orange,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        state.queuePaused
                            ? '${context.bheText('队列已暂停')} · ${context.bheText('还有')} ${state.analysisQueue.length} ${context.bheText('段待分析')}'
                            : '${context.bheText('正在排队分析')} · ${context.bheText('还有')} ${state.analysisQueue.length} ${context.bheText('段待分析')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                    if (state.exportQueued)
                      Padding(
                        padding: const EdgeInsets.only(right: Spacing.sm),
                        child: Text(
                          context.bheText('导出排在这段之后'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                    CsButton(
                      label: Text(
                        context.bheText(state.queuePaused ? '继续排队' : '暂停队列'),
                      ),
                      icon: state.queuePaused
                          ? LucideIcons.play
                          : LucideIcons.pause,
                      variant: CsButtonVariant.secondary,
                      onPressed: busy
                          ? null
                          : state.queuePaused
                          ? onResumeQueue
                          : onPauseQueue,
                    ),
                  ],
                ),
                if (!state.queuePaused)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.xs),
                    child: Text(
                      context.bheText('暂停后，正在分析的这段会继续完成，之后不再开始新的一段。'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _VideoSegmentRow extends StatelessWidget {
  const _VideoSegmentRow({
    required this.segment,
    required this.video,
    required this.state,
    required this.active,
    required this.onEdit,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemoveFromQueue,
    super.key,
  });

  final int segment;
  final JsonMap video;
  final ProjectState state;
  final bool active;
  final VoidCallback? onEdit;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onRemoveFromQueue;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final id = video['id']?.toString();
    final name = (video['source_path']?.toString() ?? '')
        .split(RegExp(r'[/\\]'))
        .last;
    final roi = (video['roi'] as Map?)?.cast<String, dynamic>();
    final roiSource = (roi?['calibration'] as Map?)?['source']?.toString();
    final needsConfirmation = needsHoopConfirmation(video);
    final (roiLabel, roiColor) = roi == null
        ? ('需要设置篮筐', c.warning)
        : switch (roiSource) {
            'suggested' => ('请确认自动识别的篮筐', c.warning),
            'reused' => ('沿用上一段的篮筐', c.success),
            'auto' => ('自动识别篮筐', c.success),
            _ => ('篮筐已设置', c.success),
          };
    final job = (video['analysis_job'] as Map?)?.cast<String, dynamic>();
    final liveJob = state.job?['video_id'] == id ? state.job : job;
    final jobState = liveJob?['state']?.toString();
    final queueIndex = state.analysisQueue.indexOf(id ?? '');
    final running =
        state.analysisRunning && state.job?['video_id'] == id;
    final progress = ((liveJob?['progress'] as num?)?.toDouble() ?? 0)
        .clamp(0.0, 1.0);
    final candidateCount = (video['candidate_count'] as num?)?.toInt() ?? 0;
    final String analysisLabel;
    final Color analysisColor;
    if (running) {
      analysisLabel = '${context.bheText('分析中')} ${(progress * 100).round()}%';
      analysisColor = c.orange;
    } else if (queueIndex >= 0) {
      analysisLabel = context.bheText('排队中');
      analysisColor = c.textSecondary;
    } else if (jobState == 'completed') {
      analysisLabel =
          '${context.bheText('已完成')} · $candidateCount ${context.bheText('个候选')}';
      analysisColor = c.success;
    } else if (jobState == 'failed') {
      analysisLabel = context.bheText('分析失败');
      analysisColor = c.error;
    } else if (jobState == 'cancelled') {
      analysisLabel = context.bheText('已取消');
      analysisColor = c.textSecondary;
    } else {
      analysisLabel = context.bheText('未分析');
      analysisColor = c.textTertiary;
    }
    final missing = video['source_exists'] == false;
    return Container(
      color: active ? c.surface2 : Colors.transparent,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surface3,
              borderRadius: BorderRadius.circular(CsRadius.sm),
            ),
            child: Text(
              '$segment',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: Spacing.md,
                  runSpacing: 2,
                  children: [
                    Text(
                      _formatDuration(
                        (video['duration_ms'] as num?)?.toInt() ?? 0,
                      ),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textTertiary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (missing)
                      Text(
                        context.bheText('原视频已移动'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.error,
                        ),
                      ),
                    Text(
                      context.bheText(roiLabel),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: roiColor,
                      ),
                    ),
                    Text(
                      analysisLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: analysisColor,
                      ),
                    ),
                  ],
                ),
                if (jobState == 'failed' &&
                    !running &&
                    liveJob?['error_message'] != null)
                  Text(
                    context.bheText(liveJob!['error_message'].toString()),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                if (running) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: progress.toDouble(),
                    minHeight: 3,
                    color: c.orange,
                    backgroundColor: c.surface3,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          if (queueIndex >= 0 && !running)
            IconButton(
              tooltip: context.bheText('移出队列'),
              onPressed: onRemoveFromQueue,
              icon: const Icon(LucideIcons.x, size: 16),
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            tooltip: context.bheText('上移'),
            onPressed: onMoveUp,
            icon: const Icon(LucideIcons.arrowUp, size: 16),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: context.bheText('下移'),
            onPressed: onMoveDown,
            icon: const Icon(LucideIcons.arrowDown, size: 16),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: Spacing.xs),
          CsButton(
            key: ValueKey('video-segment-edit-$id'),
            label: Text(
              context.bheText(
                roi == null ? '设置篮筐' : needsConfirmation ? '确认篮筐' : '调整',
              ),
            ),
            icon: needsConfirmation ? LucideIcons.target : LucideIcons.pencil,
            variant: needsConfirmation
                ? CsButtonVariant.primary
                : CsButtonVariant.secondary,
            size: CsButtonSize.sm,
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}
