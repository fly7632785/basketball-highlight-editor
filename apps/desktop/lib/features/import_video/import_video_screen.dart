import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_step_indicator.dart';
import '../../core/engine_session.dart';
import '../../providers/notice_provider.dart';
import '../../providers/project_state.dart';
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
  bool _netUserEdited = false;
  bool _editingNet = false;
  int _analysisStartMs = 0;
  int _analysisEndMs = 0;
  int _beforeSeconds = 6;
  int _afterSeconds = 3;
  String _analysisMode = 'standard';
  Timer? _previewPlaybackTimer;
  bool _previewPlaying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreDraft());
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
                description: error.toString(),
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
    if (draft != null && draft.isNotEmpty && currentState.video != null) {
      _applyDraftLocally(draft);
      setState(() => _showExistingDraft = true);
      return;
    }
  }

  void _syncFromState(ProjectState state) {
    final video = state.video;
    if (video == null) return;
    _roi = state.suggestedRoi;
    _netRoi = state.netRoi ?? _recommendedNetRoi(_roi, state.hoopBbox);
    _netUserEdited = state.netRoi != null;
    _hoopBbox = state.hoopBbox;
    _editingNet = false;
    _analysisStartMs = _analysisStart(state);
    _analysisEndMs = _analysisEnd(state);
    _beforeSeconds = 6;
    _afterSeconds = 3;
    _analysisMode = state.analysisMode;
    if (_step == 0) _step = 1;
  }

  void _applyDraftLocally(JsonMap draft) {
    final roi = _rectFromJson(draft['roi']);
    final net = _rectFromJson(draft['net_roi']);
    final hoop = _rectFromJson(draft['hoop_bbox']);
    final range = (draft['analysis_range'] as Map?)?.cast<String, dynamic>();
    final savedStep = (draft['step'] as num?)?.toInt() ?? 0;
    setState(() {
      _step = savedStep.clamp(0, _stepCount - 1);
      _roi = roi ?? _roi;
      _netRoi = net ?? _netRoi;
      _hoopBbox = hoop ?? _hoopBbox;
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
      _netUserEdited = net != null;
    });
  }

  JsonMap _draft({int? step}) => {
    'version': 4,
    'step': step ?? _step,
    'analysis_range': {'start_ms': _analysisStartMs, 'end_ms': _analysisEndMs},
    'analysis_mode': _analysisMode,
    'before_seconds': _beforeSeconds,
    'after_seconds': _afterSeconds,
    ...?_rectMap('roi', _roi),
    ...?_rectMap('net_roi', _netRoi),
    ...?_rectMap('hoop_bbox', _hoopBbox),
  };

  JsonMap _backendDraft({int? step}) {
    return {
      'version': 4,
      'step': step ?? _step,
      'analysis_range': {
        'start_ms': _analysisStartMs,
        'end_ms': _analysisEndMs,
      },
      'analysis_mode': _analysisMode,
      'before_seconds': _beforeSeconds,
      'after_seconds': _afterSeconds,
      ...?_rectMap('roi', _roi),
      ...?_rectMap('net_roi', _netRoi),
      ...?_rectMap('hoop_bbox', _hoopBbox),
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
              description: error.toString(),
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
          title: const Text('更换当前视频？'),
          content: const Text('更换视频会创建一个新的分析项目，当前项目和审核记录会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('继续选择'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    const group = XTypeGroup(
      label: '视频',
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
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null || !mounted) return;
    setState(() {
      _step = 1;
      _showExistingDraft = false;
    });
    try {
      final metadata = await ref
          .read(projectSessionProvider)
          .inspectVideo(videoPath: file.path);
      final video =
          (metadata['video'] as Map?)?.cast<String, dynamic>() ?? metadata;
      final advice = _videoProcessingAdvice(video);
      if (advice.heavy || _isElevatedVideo(video)) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('这个视频可能需要较长时间'),
            content: Text(
              '${advice.importDetail}\n\n如果方便，建议先用剪辑工具压缩后再导入。也可以继续，原视频不会被修改。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('先取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('继续导入'),
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
    await ref.read(projectProvider.notifier).selectVideo(file.path);
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
    const group = XTypeGroup(
      label: '视频',
      extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv'],
      mimeTypes: ['video/*'],
      uniformTypeIdentifiers: ['public.movie'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
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
          title: const Text('应用新配置？'),
          content: Text(
            '当前已有 ${state.candidates.length} 个候选片段。应用后会按新配置重新生成候选，原始视频不会被删除。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('应用并重新分析'),
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
          _netUserEdited = false;
          _editingNet = false;
          _analysisStartMs = 0;
          _analysisEndMs = 0;
        });
        return;
      }
      _draftLoaded = true;
      _showExistingDraft = false;
      _netUserEdited = false;
      _editingNet = false;
      _syncFromState(next);
      setState(() => _step = 1);
    });
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final hasVideo = state.video != null;
    final busy =
        state.busy || state.analysisRunning || state.exportRunning || _applying;
    final steps = <CsStep>[
      (
        index: '01',
        title: '选择视频',
        icon: LucideIcons.upload,
        completed: hasVideo,
      ),
      (
        index: '02',
        title: '分析范围',
        icon: LucideIcons.scanLine,
        completed: hasVideo,
      ),
      (
        index: '03',
        title: '检测区域',
        icon: LucideIcons.target,
        completed: _roi != null,
      ),
      (
        index: '04',
        title: '确认并分析',
        icon: LucideIcons.listChecks,
        completed: false,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.xl,
        Spacing.lg,
        Spacing.xl,
        Spacing.xxl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('配置分析项目', style: theme.textTheme.displayMedium),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          hasVideo
                              ? '按步骤确认视频、分析范围和篮筐检测区域，最后再开始分析。'
                              : '先选择一段固定机位视频，系统会在最后一步统一应用配置。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasVideo)
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : state.videoPath == null || state.videoPath!.isEmpty
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
                            ? '重新定位视频'
                            : '更换视频',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              CsCard(
                child: CsStepIndicator(
                  steps: steps,
                  onStepTap: busy
                      ? null
                      : (index) {
                          if (index < _step) {
                            if (_step == 2 && index != 2) {
                              _stopPreviewPlayback();
                            }
                            setState(() => _step = index);
                            unawaited(_persistDraft(step: index));
                          }
                        },
                ),
              ),
              if (_showExistingDraft) ...[
                const SizedBox(height: Spacing.sm),
                _DraftBanner(
                  onContinue: () => setState(() => _showExistingDraft = false),
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
              const SizedBox(height: Spacing.md),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _buildStep(context, state, busy),
              ),
              if (state.busyMessage != null) ...[
                const SizedBox(height: Spacing.sm),
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
                    const SizedBox(width: Spacing.sm),
                    Text(
                      state.busyMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: Spacing.md),
              Row(
                children: [
                  if (_step > 0)
                    TextButton.icon(
                      onPressed: busy ? null : _back,
                      icon: const Icon(Icons.arrow_back_rounded, size: 17),
                      label: const Text('上一步'),
                    ),
                  const Spacer(),
                  if (_step < _stepCount - 1)
                    CsButton(
                      label: const Text('下一步'),
                      icon: LucideIcons.arrowRight,
                      onPressed: busy || !_canLeaveStep(_step) ? null : _next,
                    )
                  else
                    CsButton(
                      label: const Text('确认配置并开始分析'),
                      icon: LucideIcons.play,
                      isLoading: _applying,
                      onPressed: busy || _roi == null ? null : _applyAndAnalyze,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context, ProjectState state, bool busy) {
    switch (_step) {
      case 0:
        return _VideoStep(
          video: state.video,
          onSelect: busy ? null : _selectVideo,
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
          onPreviewTimeChanged: (timeMs) =>
              unawaited(_refreshPreviewAt(timeMs)),
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
                  _netRoi = _recommendedNetRoi(value, hoopBbox);
                }
              }
            });
            unawaited(_persistDraft());
          },
          onResetNet: () {
            setState(() {
              _netRoi = _recommendedNetRoi(_roi, state.hoopBbox);
              _netUserEdited = false;
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
        );
      default:
        return const SizedBox.shrink();
    }
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
          const Expanded(child: Text('检测到上次未完成的配置。')),
          TextButton(onPressed: onDiscard, child: const Text('放弃草稿')),
          FilledButton(onPressed: onContinue, child: const Text('继续配置')),
        ],
      ),
    );
  }
}

class _VideoStep extends StatelessWidget {
  const _VideoStep({required this.video, required this.onSelect});
  final JsonMap? video;
  final VoidCallback? onSelect;

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
            Text('选择原始视频', style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.xs),
            Text(
              '支持 MP4、MOV、M4V、AVI、MKV。原始视频不会被修改或上传。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: Spacing.lg),
            CsButton(
              label: const Text('选择视频'),
              icon: LucideIcons.folderOpen,
              onPressed: onSelect,
            ),
            const SizedBox(height: Spacing.lg),
          ],
        ),
      );
    }
    return _InfoPanel(
      title: '视频已准备好',
      icon: LucideIcons.checkCircle2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _videoSummary(video!),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: Spacing.md),
          _VideoProcessingHint(video: video!),
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
                    text: advice.title,
                    style: TextStyle(
                      color: advice.heavy ? c.textPrimary : color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: '\n${advice.importDetail}',
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
    return _InfoPanel(
      title: '分析范围',
      icon: LucideIcons.scanLine,
      subtitle: '默认分析全片。拖动范围手柄排除热身、暂停或比赛结束部分，修改会自动保存在当前草稿。',
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
  }
}

class _DetectionStep extends StatelessWidget {
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
    required this.onResetNet,
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
  final VoidCallback onResetNet;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return _InfoPanel(
      title: '检测区域',
      icon: LucideIcons.target,
      subtitle: '系统会先自动识别篮筐。橙色区域用于球轨迹，白色区域只覆盖篮网摆动范围；拖动或缩放后会自动保存到草稿。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.roiSource == 'auto') ...[
            Text(
              '系统已自动选择 ${_formatPreviewTime(state.previewTimeMs)} 作为标记画面',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              '篮筐可见度较高，如被遮挡可调整画面时间。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: Spacing.sm),
          ],
          _RoiCanvas(
            enabled: enabled && !state.previewRefreshing,
            previewPath: state.previewPath,
            aspectRatio: aspectRatio,
            roi: editingNet ? netRoi : roi,
            secondaryRoi: editingNet ? roi : netRoi,
            activeColor: editingNet ? Colors.white : c.orange,
            secondaryColor: editingNet ? c.orange : Colors.white,
            activeLabel: editingNet ? '篮网检测区' : '投篮分析区',
            secondaryLabel: editingNet ? '投篮分析区' : '篮网检测区',
            onRefreshPreview: onRefreshPreview,
            onChanged: onChanged,
            onEditComplete: () {},
          ),
          const SizedBox(height: Spacing.sm),
          _PreviewTimeControls(
            timeMs: state.previewTimeMs,
            durationMs: (state.video?['duration_ms'] as num?)?.toInt() ?? 0,
            enabled: enabled && !state.roiDetecting && !state.previewRefreshing,
            playing: previewPlaying,
            onStep: onPreviewTimeChanged,
            onTogglePlayback: onPreviewPlaybackToggled,
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
                  '正在切换标记画面…',
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
                label: '投篮分析区',
                color: c.orange,
                selected: !editingNet,
                onPressed: enabled ? () => onEditNetChanged(false) : null,
              ),
              const SizedBox(width: Spacing.sm),
              _CalibrationTargetButton(
                index: '2',
                label: '篮网检测区',
                color: Colors.white,
                selected: editingNet,
                onPressed: enabled ? () => onEditNetChanged(true) : null,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: enabled ? onResetNet : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 16),
                label: const Text('重置篮网区'),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            editingNet
                ? '当前编辑白色篮网区域：覆盖篮圈下方到网底，尽量不要包含篮板、球员或地面。'
                : '当前编辑橙色投篮分析区域：覆盖来球轨迹、篮圈和篮网下方的落球范围。',
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
              '正在自动识别篮筐区域…',
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
    final totalSeconds = beforeSeconds + afterSeconds;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('候选片段长度', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Spacing.xs),
          Text(
            '以下是自动生成候选的默认范围，审核时仍可单独调整片段。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Expanded(
                child: _SecondSelector(
                  label: '进球前',
                  value: beforeSeconds,
                  options: _beforeSecondOptions,
                  onChanged: onBeforeChanged,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: _SecondSelector(
                  label: '进球后',
                  value: afterSeconds,
                  options: _afterSecondOptions,
                  onChanged: onAfterChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            '默认片段总长：$totalSeconds 秒',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: c.orange),
          ),
        ],
      ),
    );
  }
}

class _SecondSelector extends StatelessWidget {
  const _SecondSelector({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          isExpanded: true,
          items: [
            for (final seconds in options)
              DropdownMenuItem<int>(value: seconds, child: Text('$seconds 秒')),
          ],
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final rows = <(String, String)>[
      ('视频', state.video?['source_path']?.toString().split('/').last ?? '-'),
      ('分析范围', '${_formatDuration(startMs)} - ${_formatDuration(endMs)}'),
      ('投篮分析区', roi == null ? '未设置' : '已设置'),
      ('篮网检测区', netRoi == null ? '自动推荐' : '已设置'),
    ];
    final estimate = estimateAnalysisDuration(
      startMs: startMs,
      endMs: endMs,
      width: (state.video?['width'] as num?)?.toInt() ?? 0,
      height: (state.video?['height'] as num?)?.toInt() ?? 0,
      mode: analysisMode,
    );
    return _InfoPanel(
      title: '确认配置',
      icon: LucideIcons.listChecks,
      subtitle: '确认后保存检测区域并开始分析；已有候选将被当前配置替换。',
      child: Column(
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: Row(
                children: [
                  Text(row.$1, style: TextStyle(color: c.textSecondary)),
                  const Spacer(),
                  Flexible(child: Text(row.$2, textAlign: TextAlign.right)),
                ],
              ),
            ),
          if (fastModeEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment<String>(value: 'standard', label: Text('标准分析')),
                  ButtonSegment<String>(value: 'fast', label: Text('快速分析')),
                ],
                selected: {analysisMode},
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) {
                    onAnalysisModeChanged(selection.first);
                  }
                },
              ),
            ),
          if (fastModeEnabled && analysisMode == 'fast')
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('快速分析使用低规格代理，可能漏检少量片段。'),
            ),
          const SizedBox(height: Spacing.sm),
          _ClipWindowSelector(
            beforeSeconds: beforeSeconds,
            afterSeconds: afterSeconds,
            onBeforeChanged: onBeforeSecondsChanged,
            onAfterChanged: onAfterSecondsChanged,
          ),
          const SizedBox(height: Spacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            decoration: BoxDecoration(
              color: c.surface2,
              border: Border.all(color: c.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.schedule_outlined, size: 17, color: c.textSecondary),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: '开始前预计耗时：'),
                        TextSpan(
                          text: estimate.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const TextSpan(text: '\n实际耗时会受视频编码、磁盘和设备负载影响。'),
                      ],
                    ),
                    style: TextStyle(color: c.textSecondary, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
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
              Icon(icon, size: 19, color: c.orange),
              const SizedBox(width: Spacing.sm),
              Text(title, style: theme.textTheme.titleLarge),
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
          const SizedBox(height: Spacing.lg),
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

String _videoSummary(JsonMap video) {
  final w = video['width'] ?? '-';
  final h = video['height'] ?? '-';
  final fps = (video['fps'] as num?)?.toStringAsFixed(2) ?? '-';
  final duration = (video['duration_ms'] as num?)?.toInt() ?? 0;
  final codec = video['video_codec'] ?? '-';
  final audio = video['audio_codec'] ?? '无音频';
  return '$w×$h · $fps fps · ${_formatDuration(duration)} · $codec / $audio';
}

int _analysisStart(ProjectState state) =>
    (state.video?['analysis_start_ms'] as num?)?.toInt() ?? 0;

int _analysisEnd(ProjectState state) =>
    (state.video?['analysis_end_ms'] as num?)?.toInt() ??
    ((state.video?['duration_ms'] as num?)?.toInt() ?? 0);

Rect? _recommendedNetRoi(Rect? analysisRoi, Rect? hoopBbox) {
  if (analysisRoi == null) return null;
  if (hoopBbox == null) {
    return Rect.fromLTRB(
      (analysisRoi.left + analysisRoi.width * 0.30).clamp(0.0, 1.0),
      (analysisRoi.top + analysisRoi.height * 0.38).clamp(0.0, 1.0),
      (analysisRoi.right - analysisRoi.width * 0.30).clamp(0.0, 1.0),
      (analysisRoi.top + analysisRoi.height * 0.74).clamp(0.0, 1.0),
    );
  }
  final width = (hoopBbox.width * 1.35).clamp(
    analysisRoi.width * 0.08,
    analysisRoi.width * 0.34,
  );
  final left = (hoopBbox.center.dx - width / 2).clamp(
    analysisRoi.left,
    analysisRoi.right - width,
  );
  final top = (hoopBbox.top + hoopBbox.height * 0.42).clamp(
    analysisRoi.top,
    analysisRoi.bottom,
  );
  final height = (hoopBbox.height * 0.95).clamp(
    analysisRoi.height * 0.12,
    analysisRoi.height * 0.30,
  );
  return Rect.fromLTWH(
    left,
    top,
    width,
    height.clamp(0.03, analysisRoi.bottom - top),
  );
}

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

class _AnalysisRangeEditor extends StatefulWidget {
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
  State<_AnalysisRangeEditor> createState() => _AnalysisRangeEditorState();
}

class _AnalysisRangeEditorState extends State<_AnalysisRangeEditor> {
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
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(CsRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('分析范围', style: Theme.of(context).textTheme.labelLarge),
          Text(
            fullRange
                ? '默认扫描完整视频。播放视频后设定起点和终点，可排除热身或结束部分。'
                : '仅扫描 ${_formatDuration(start)} - ${_formatDuration(end)}。',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: c.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          AspectRatio(
            aspectRatio: widget.aspectRatio,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black),
              child: _error != null
                  ? Center(
                      child: Text(
                        '视频加载失败，请重新进入此步骤。',
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
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              IconButton(
                tooltip: '播放/暂停',
                onPressed: _ready ? () => unawaited(_togglePlayback()) : null,
                icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                '拖动下方两个手柄，视频会跳到正在调整的位置。',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
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
          Row(
            children: [
              Text(
                '起点 ${_formatDuration(start)}',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
              ),
              const Spacer(),
              Text(
                '终点 ${_formatDuration(end)}',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
              ),
              const SizedBox(width: Spacing.sm),
              TextButton.icon(
                onPressed: widget.enabled
                    ? () {
                        setState(() {
                          _startMs = 0;
                          _endMs = widget.durationMs;
                        });
                        widget.onChanged(0, widget.durationMs);
                        unawaited(_commitRange(0, widget.durationMs));
                      }
                    : null,
                icon: const Icon(Icons.unfold_more_rounded, size: 16),
                label: const Text('使用全片'),
              ),
            ],
          ),
        ],
      ),
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
                  Text('播放进度', style: Theme.of(context).textTheme.labelSmall),
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
                  Text('分析范围', style: Theme.of(context).textTheme.labelSmall),
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
        Text('标记画面', style: Theme.of(context).textTheme.labelLarge),
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
          child: const Text('−5 秒'),
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
          label: Text(playing ? '暂停' : '播放'),
        ),
        const SizedBox(width: Spacing.xs),
        OutlinedButton(
          onPressed: enabled && timeMs < durationMs ? () => onStep(step) : null,
          child: const Text('+5 秒'),
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
                fontSize: 10,
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
  });

  final bool enabled;
  final String? previewPath;
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
                              if (widget.previewPath != null &&
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
                                          '预览加载失败，请重新生成。',
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
                                const Center(
                                  child: CsEmptyState(
                                    icon: LucideIcons.lock,
                                    title: '请先选择视频',
                                    description: '选择原始视频后即可框选篮筐区域。',
                                  ),
                                )
                              else if (widget.previewPath != null)
                                Center(
                                  child: CsEmptyState(
                                    icon: LucideIcons.circleAlert,
                                    title: '预览帧不可用',
                                    description: '视频元数据已读取，可以重新生成预览后继续框选。',
                                    action: widget.onRefreshPreview == null
                                        ? null
                                        : CsButton(
                                            label: const Text('重新生成预览'),
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
                                    title: '正在准备视频预览',
                                    description: '预览准备好后即可拖拽框选篮筐区域。',
                                    action: widget.onRefreshPreview == null
                                        ? null
                                        : CsButton(
                                            label: const Text('生成预览'),
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
                          tooltip: '缩小',
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
                          tooltip: '放大',
                          onPressed: _zoom < 4 ? () => _changeZoom(0.5) : null,
                          icon: const Icon(Icons.add_rounded, size: 16),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        IconButton(
                          tooltip: '适应画面',
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
          fontSize: 10 * inverseScale,
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
