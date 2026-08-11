import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../components/cs_button.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_progress_track.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// 审核工作台：视频优先，候选默认保留，用户只需要打叉剔除误检。
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  String? _selectedCandidateId;
  final Set<String> _reviewStartedCandidateIds = <String>{};
  String _candidateFilter = 'all';
  final GlobalKey<_VideoPaneState> _videoKey = GlobalKey<_VideoPaneState>();
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'review-shortcut-focus',
  );
  final Map<String, Future<String?>> _coverCache = <String, Future<String?>>{};
  final List<Future<void> Function()> _previewQueue =
      <Future<void> Function()>[];
  int _activePreviewLoads = 0;
  int _replayToken = 0;
  bool _previewQueueDisposed = false;
  int _previewGeneration = 0;
  String? _previewScopeKey;

  List<Map<String, dynamic>> _orderedCandidates(
    List<Map<String, dynamic>> candidates,
  ) {
    final ordered = [...candidates];
    ordered.sort(
      (left, right) => _candidateTime(left).compareTo(_candidateTime(right)),
    );
    return ordered;
  }

  Map<String, dynamic>? _selectedCandidate(
    List<Map<String, dynamic>> candidates,
  ) {
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      if (candidate['id']?.toString() == _selectedCandidateId) {
        return candidate;
      }
    }
    return candidates.first;
  }

  void _selectCandidate(Map<String, dynamic> candidate) {
    _focusReviewShortcuts();
    final id = candidate['id']?.toString();
    if (id != null && id.isNotEmpty) {
      final current = _selectedCandidate(
        _orderedCandidates(ref.read(projectProvider).candidates),
      );
      if (current?['id']?.toString() == id) {
        _requestReplay();
      } else {
        setState(() => _selectedCandidateId = id);
      }
    }
  }

  void _ensureReviewStarted(String id) {
    if (!_reviewStartedCandidateIds.add(id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(projectProvider.notifier).startReview(id));
      }
    });
  }

  void _requestReplay() {
    setState(() => _replayToken++);
  }

  void _togglePlayback() {
    unawaited(_videoKey.currentState?.togglePlayPause());
  }

  void _toggleCandidateLoop() {
    _videoKey.currentState?.toggleCandidateLoop();
  }

  void _focusReviewShortcuts() {
    _shortcutFocusNode.requestFocus();
  }

  void _seekBySeconds(int seconds) {
    unawaited(_videoKey.currentState?.seekBy(Duration(seconds: seconds)));
  }

  KeyEventResult _handleShortcut(
    KeyEvent event, {
    required List<Map<String, dynamic>> candidates,
    required Map<String, dynamic>? selected,
    required bool reviewLocked,
    required ProjectNotifier notifier,
  }) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveCandidate(candidates, -1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveCandidate(candidates, 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBySeconds(-3);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBySeconds(3);
    } else if (key == LogicalKeyboardKey.space) {
      _togglePlayback();
    } else if (key == LogicalKeyboardKey.keyR) {
      _requestReplay();
    } else if (key == LogicalKeyboardKey.keyL) {
      _toggleCandidateLoop();
    } else if (key == LogicalKeyboardKey.keyZ &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      if (!reviewLocked) unawaited(notifier.undoReview());
    } else if (key == LogicalKeyboardKey.keyX ||
        key == LogicalKeyboardKey.backspace) {
      final id = selected?['id']?.toString();
      if (!reviewLocked && id != null) {
        unawaited(_setCandidateStatus(id, 'excluded'));
      }
    } else if (key == LogicalKeyboardKey.keyC ||
        key == LogicalKeyboardKey.enter) {
      final id = selected?['id']?.toString();
      if (!reviewLocked && id != null) {
        unawaited(_setCandidateStatus(id, 'included'));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _editClipRange(Map<String, dynamic> candidate) async {
    final result = await showDialog<({int startMs, int endMs})>(
      context: context,
      builder: (dialogContext) => _ClipRangeDialog(
        videoPath: ref.read(projectProvider).videoPath,
        startMs: _clipStart(candidate),
        endMs: _clipEnd(candidate),
        durationMs: _number(
          ref.read(projectProvider).video?['duration_ms'],
        ).round(),
      ),
    );
    if (!mounted || result == null) return;
    await ref
        .read(projectProvider.notifier)
        .updateClipRange(
          candidate['id']?.toString() ?? '',
          result.startMs,
          result.endMs,
        );
  }

  Future<void> _editCandidateNote(Map<String, dynamic> candidate) async {
    final controller = TextEditingController(
      text: candidate['note']?.toString() ?? '',
    );
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('候选备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '例如：补篮、擦框、镜头遮挡',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || note == null) return;
    await ref
        .read(projectProvider.notifier)
        .updateCandidateNote(candidate['id']?.toString() ?? '', note.trim());
  }

  Future<void> _setCandidateStatus(String id, String status) async {
    _focusReviewShortcuts();
    final before = _filterCandidates(
      _orderedCandidates(ref.read(projectProvider).candidates),
      _candidateFilter,
    );
    final previousIndex = before.indexWhere(
      (candidate) => candidate['id']?.toString() == id,
    );
    final future = ref
        .read(projectProvider.notifier)
        .reviewCandidate(id, status, showNotice: false);
    final after = _filterCandidates(
      _orderedCandidates(ref.read(projectProvider).candidates),
      _candidateFilter,
    );
    if (mounted &&
        _selectedCandidateId == id &&
        !after.any((candidate) => candidate['id']?.toString() == id)) {
      final nextIndex = after.isEmpty
          ? -1
          : previousIndex.clamp(0, after.length - 1).toInt();
      setState(() {
        _selectedCandidateId = nextIndex < 0
            ? null
            : after[nextIndex]['id']?.toString();
      });
    }
    await future;
  }

  Future<void> _confirmReanalyze() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新分析当前视频？'),
        content: const Text('重新分析会替换当前候选列表，但不会删除原始视频。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重新分析'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref
          .read(projectProvider.notifier)
          .startAnalysis(replaceRecoverable: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    _syncPreviewScope(state);
    final allCandidates = _orderedCandidates(state.candidates);
    final candidates = _filterCandidates(allCandidates, _candidateFilter);
    final selected = _selectedCandidate(candidates);
    final selectedId = selected?['id']?.toString();
    final job = state.job;
    final jobState = job?['state']?.toString() ?? '';
    final recoveryState = job?['recovery_state']?.toString();
    final analyzing =
        (jobState == 'queued' || jobState == 'running') &&
        (recoveryState == null || recoveryState == 'worker_attached');
    final progress = ((job?['progress'] as num?)?.toDouble() ?? 0)
        .clamp(0.0, 1.0)
        .toDouble();
    final playbackPath = _resolvePlaybackPath(state, analyzing: analyzing);
    final reviewLocked = analyzing || state.busy || state.hydrating;
    if (!reviewLocked && selectedId != null && selectedId.isNotEmpty) {
      _ensureReviewStarted(selectedId);
    }
    final includedCount = allCandidates
        .where((candidate) => !_isExcluded(candidate))
        .length;

    return Focus(
      key: const Key('review-shortcut-focus'),
      focusNode: _shortcutFocusNode,
      autofocus: true,
      onKeyEvent: (_, event) => _handleShortcut(
        event,
        candidates: candidates,
        selected: selected,
        reviewLocked: reviewLocked,
        notifier: notifier,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: Spacing.xs, bottom: Spacing.sm),
        child: Column(
          children: [
            if (analyzing ||
                jobState == 'failed' ||
                jobState == 'cancelled' ||
                job?['recoverable'] == true)
              _AnalysisBar(
                state: jobState,
                stage: job?['stage']?.toString() ?? '',
                progress: progress,
                startedAt: job?['started_at']?.toString(),
                errorMessage: job?['error_message']?.toString(),
                recoverable: job?['recoverable'] == true && !analyzing,
                onCancel: analyzing ? () => notifier.cancelAnalysis() : null,
                onRetry:
                    (jobState == 'failed' || job?['recoverable'] == true) &&
                        !state.busy
                    ? () => notifier.retryAnalysis()
                    : null,
                onReanalyze: !analyzing && !state.busy
                    ? _confirmReanalyze
                    : null,
              )
            else if (jobState == 'completed')
              _CompletedLine(candidateCount: allCandidates.length),
            const SizedBox(height: Spacing.sm),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final video = _VideoPane(
                    key: _videoKey,
                    videoPath: playbackPath,
                    candidate: selected,
                    replayToken: _replayToken,
                    frameSize: _videoFrameSize(state.video),
                    hasPrevious: _candidateIndex(candidates, selected) > 0,
                    hasNext:
                        _candidateIndex(candidates, selected) <
                        candidates.length - 1,
                    onPrevious: () => _moveCandidate(candidates, -1),
                    onNext: () => _moveCandidate(candidates, 1),
                    onInteraction: _focusReviewShortcuts,
                    onEditRange: selected == null || reviewLocked
                        ? null
                        : () => _editClipRange(selected),
                    onEditNote: selected == null || reviewLocked
                        ? null
                        : () => _editCandidateNote(selected),
                    onUndo: () {
                      if (!reviewLocked) unawaited(notifier.undoReview());
                    },
                  );
                  final queueWidth = (constraints.maxWidth * 0.28)
                      .clamp(296.0, 360.0)
                      .toDouble();
                  final queue = _CandidatePanel(
                    candidates: candidates,
                    selectedId: selected?['id']?.toString(),
                    includedCount: includedCount,
                    totalCount: allCandidates.length,
                    filter: _candidateFilter,
                    busy: reviewLocked,
                    hydrating: state.hydrating,
                    hydrateError: state.hydrateError,
                    analyzing: analyzing,
                    hasVideo: state.videoPath != null,
                    onSelect: _selectCandidate,
                    onSetStatus: (id, status) =>
                        _setCandidateStatus(id, status),
                    onLoadCover: state.video == null
                        ? null
                        : (id, timeMs) =>
                              _loadCandidateCover(notifier, id, timeMs),
                    onFilterChanged: (value) =>
                        setState(() => _candidateFilter = value),
                    onReanalyze: !analyzing && !state.busy && !state.hydrating
                        ? _confirmReanalyze
                        : null,
                    onRetryHydration:
                        state.hydrateError != null && !state.hydrating
                        ? () => notifier.retryProjectHydration()
                        : null,
                    onEditRange: selected == null || reviewLocked
                        ? null
                        : () => _editClipRange(selected),
                    onEditNote: selected == null || reviewLocked
                        ? null
                        : () => _editCandidateNote(selected),
                    onUndo: () {
                      if (!reviewLocked) unawaited(notifier.undoReview());
                    },
                    onGoImport: () => context.go('/import'),
                    onExport: includedCount == 0 || reviewLocked
                        ? null
                        : () => context.go('/export'),
                  );
                  if (constraints.maxWidth >= Breakpoints.md) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: video),
                        const SizedBox(width: Spacing.sm),
                        SizedBox(width: queueWidth, child: queue),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: Spacing.lg),
                    child: Column(
                      children: [
                        SizedBox(
                          height: (constraints.maxWidth * 0.5625)
                              .clamp(240.0, 520.0)
                              .toDouble(),
                          child: video,
                        ),
                        const SizedBox(height: Spacing.md),
                        SizedBox(
                          height: (constraints.maxWidth * 0.92)
                              .clamp(360.0, 520.0)
                              .toDouble(),
                          child: queue,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _candidateIndex(
    List<Map<String, dynamic>> candidates,
    Map<String, dynamic>? selected,
  ) {
    if (selected == null) return 0;
    final index = candidates.indexWhere(
      (candidate) => candidate['id'] == selected['id'],
    );
    return index < 0 ? 0 : index;
  }

  void _moveCandidate(List<Map<String, dynamic>> candidates, int delta) {
    if (candidates.isEmpty) return;
    final selected = _selectedCandidate(candidates);
    final current = _candidateIndex(candidates, selected);
    final next = (current + delta).clamp(0, candidates.length - 1).toInt();
    _selectCandidate(candidates[next]);
  }

  Future<String?> _loadCandidateCover(
    ProjectNotifier notifier,
    String candidateId,
    int timeMs,
  ) {
    final key = '$candidateId:$timeMs';
    return _coverCache.putIfAbsent(
      key,
      () => _enqueuePreview(
        () => notifier.loadCandidatePreview(candidateId, timeMs),
      ),
    );
  }

  void _syncPreviewScope(ProjectState state) {
    final key = '${state.video?['id'] ?? ''}|${state.videoPath ?? ''}';
    if (_previewScopeKey == key) return;
    _previewScopeKey = key;
    _previewGeneration++;
    _coverCache.clear();
    _reviewStartedCandidateIds.clear();
  }

  Future<String?> _enqueuePreview(Future<String?> Function() loader) {
    if (_previewQueueDisposed) return Future<String?>.value(null);
    final completer = Completer<String?>();
    final generation = _previewGeneration;
    _previewQueue.add(() async {
      if (_previewQueueDisposed || generation != _previewGeneration) {
        completer.complete(null);
        return;
      }
      try {
        final path = await loader();
        completer.complete(
          _previewQueueDisposed || generation != _previewGeneration
              ? null
              : path,
        );
      } catch (error, stackTrace) {
        if (_previewQueueDisposed || generation != _previewGeneration) {
          completer.complete(null);
        } else {
          completer.completeError(error, stackTrace);
        }
      }
    });
    _drainPreviewQueue();
    return completer.future;
  }

  void _drainPreviewQueue() {
    if (_previewQueueDisposed) {
      _previewQueue.clear();
      return;
    }
    while (_activePreviewLoads < 2 && _previewQueue.isNotEmpty) {
      final request = _previewQueue.removeAt(0);
      _activePreviewLoads++;
      unawaited(
        request().whenComplete(() {
          _activePreviewLoads--;
          _drainPreviewQueue();
        }),
      );
    }
  }

  @override
  void dispose() {
    _previewQueueDisposed = true;
    _previewGeneration++;
    _previewQueue.clear();
    _coverCache.clear();
    _shortcutFocusNode.dispose();
    super.dispose();
  }
}

class _AnalysisBar extends StatelessWidget {
  const _AnalysisBar({
    required this.state,
    required this.stage,
    required this.progress,
    required this.startedAt,
    required this.errorMessage,
    required this.recoverable,
    required this.onCancel,
    required this.onRetry,
    required this.onReanalyze,
  });

  final String state;
  final String stage;
  final double progress;
  final String? startedAt;
  final String? errorMessage;
  final bool recoverable;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onReanalyze;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final failed = state == 'failed';
    final interrupted = recoverable || state == 'cancelled';
    final active = !failed && !interrupted;
    final value = progress.clamp(0.0, 1.0).toDouble();
    final color = failed
        ? c.error
        : interrupted
        ? c.warning
        : c.indigo;
    final title = failed
        ? '分析失败'
        : interrupted
        ? '上次分析没有完成'
        : '正在分析视频';
    final detail = failed
        ? (errorMessage ?? '请检查视频后重试')
        : interrupted
        ? '已有候选可以继续使用，也可以重新分析'
        : '${_stageLabel(stage)} · ${(value * 100).round()}%';
    final elapsed = _formatElapsed(startedAt);
    final remaining = _formatEstimatedRemaining(startedAt, value);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.auto_awesome,
            size: 17,
            color: color,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (active) ...[
                  const SizedBox(height: Spacing.xs),
                  const Text('分析进行中', style: TextStyle(fontSize: 10)),
                  if (elapsed.isNotEmpty)
                    Text(
                      remaining.isEmpty
                          ? '已用 $elapsed'
                          : '已用 $elapsed · 预计剩余约 $remaining',
                      style: TextStyle(fontSize: 10, color: c.textSecondary),
                    ),
                  const SizedBox(height: Spacing.xs),
                  CsProgressTrack(value: value),
                ],
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          if (onCancel != null)
            _SmallAction(
              label: '取消',
              icon: Icons.stop_circle_outlined,
              onPressed: onCancel!,
            ),
          if (onRetry != null)
            _SmallAction(
              label: '重试分析',
              icon: Icons.refresh,
              onPressed: onRetry!,
            ),
          if (onReanalyze != null)
            _SmallAction(
              label: '重新分析',
              icon: Icons.replay,
              onPressed: onReanalyze!,
            ),
        ],
      ),
    );
  }
}

class _CompletedLine extends StatelessWidget {
  const _CompletedLine({required this.candidateCount});

  final int candidateCount;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 16, color: c.goal),
          const SizedBox(width: Spacing.xs),
          Text(
            '分析完成 · $candidateCount 个候选',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 15),
    label: Text(label),
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
  );
}

class _VideoPane extends StatefulWidget {
  const _VideoPane({
    super.key,
    required this.videoPath,
    required this.candidate,
    required this.replayToken,
    required this.frameSize,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onInteraction,
    required this.onEditRange,
    required this.onEditNote,
    required this.onUndo,
  });

  final String? videoPath;
  final Map<String, dynamic>? candidate;
  final int replayToken;
  final Size frameSize;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onInteraction;
  final VoidCallback? onEditRange;
  final VoidCallback? onEditNote;
  final VoidCallback onUndo;

  @override
  State<_VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<_VideoPane> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  String? _error;
  bool _ready = false;
  bool _loading = false;
  bool _showAnnotations = true;
  bool _loopCandidate = false;
  int? _clipEndMs;
  bool _clipEndHandled = false;
  int _mediaGeneration = 0;
  bool _disposed = false;
  Future<void> _mediaQueue = Future<void>.value();
  int _playbackToken = 0;

  @override
  void initState() {
    super.initState();
    final candidate = widget.candidate;
    if (candidate != null && candidate.isNotEmpty) {
      _clipEndMs = _clipEnd(candidate);
    }
    _ensurePlayer();
    unawaited(_queueOpen(widget.videoPath));
  }

  void _ensurePlayer() {
    if (_player != null ||
        widget.videoPath == null ||
        widget.videoPath!.isEmpty) {
      return;
    }
    try {
      MediaKit.ensureInitialized();
      _player = Player();
      _controller = VideoController(_player!);
    } catch (error) {
      _error = error.toString();
      return;
    }
    _positionSubscription = _player!.stream.position.listen((position) {
      if (_disposed || !mounted) return;
      final end = _clipEndMs;
      final clipEnded = end != null && position.inMilliseconds >= end;
      final player = _player;
      if (!clipEnded || _clipEndHandled || player == null) return;
      _clipEndHandled = true;
      final generation = _mediaGeneration;
      final playbackToken = _playbackToken;
      unawaited(
        _queuePlayerAction(
          generation: generation,
          playbackToken: playbackToken,
          action: (current) async {
            if (_loopCandidate && widget.candidate != null) {
              await current.seek(
                Duration(milliseconds: _clipStart(widget.candidate!)),
              );
              _clipEndHandled = false;
              await current.play();
            } else {
              await current.pause();
            }
          },
        ),
      );
    });
  }

  @override
  void didUpdateWidget(covariant _VideoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _ensurePlayer();
      _ready = false;
      _loading = false;
      _error = null;
      final candidate = widget.candidate;
      _clipEndMs = candidate == null || candidate.isEmpty
          ? null
          : _clipEnd(candidate);
      _clipEndHandled = false;
      unawaited(_queueOpen(widget.videoPath));
    } else if (oldWidget.replayToken != widget.replayToken) {
      unawaited(_queueCandidatePlayback());
    } else if (_candidateSignature(oldWidget.candidate) !=
        _candidateSignature(widget.candidate)) {
      final candidate = widget.candidate;
      if (candidate != null && candidate.isNotEmpty) {
        setState(() {
          _clipEndMs = _clipEnd(candidate);
          _clipEndHandled = false;
        });
      }
      unawaited(_queueCandidatePlayback());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _mediaGeneration++;
    _playbackToken++;
    final subscription = _positionSubscription;
    _positionSubscription = null;
    final player = _player;
    _player = null;
    unawaited(subscription?.cancel());
    if (player != null) {
      final pending = _mediaQueue;
      unawaited(pending.whenComplete(player.dispose));
    }
    super.dispose();
  }

  Future<void> _queueOpen(String? path) {
    final generation = ++_mediaGeneration;
    _playbackToken++;
    return _enqueueMediaAction(() async {
      if (!_isCurrent(generation)) return;
      await _open(path, generation);
    });
  }

  void _reloadVideo() {
    setState(() {
      _error = null;
      _ready = false;
    });
    _ensurePlayer();
    unawaited(_queueOpen(widget.videoPath));
  }

  bool _isCurrent(int generation, {int? playbackToken}) =>
      mounted &&
      !_disposed &&
      generation == _mediaGeneration &&
      (playbackToken == null || playbackToken == _playbackToken);

  Future<void> _queueCandidatePlayback() {
    final candidate = widget.candidate;
    final generation = _mediaGeneration;
    final playbackToken = ++_playbackToken;
    return _enqueueMediaAction(() async {
      if (!_isCurrent(generation, playbackToken: playbackToken)) return;
      await _playCandidate(candidate, generation, playbackToken: playbackToken);
    });
  }

  Future<void> _queuePlayerAction({
    required int generation,
    required int playbackToken,
    required Future<void> Function(Player player) action,
  }) {
    return _enqueueMediaAction(() async {
      if (!_isCurrent(generation, playbackToken: playbackToken)) return;
      final player = _player;
      if (player == null || !_ready) return;
      await action(player);
    });
  }

  Future<void> _enqueueMediaAction(Future<void> Function() action) {
    _mediaQueue = _mediaQueue.catchError((Object _) {}).then((_) async {
      try {
        await action();
      } catch (error) {
        if (!_disposed && mounted) {
          setState(() => _error = error.toString());
        }
      }
    });
    return _mediaQueue;
  }

  Future<void> _open(String? path, int generation) async {
    final player = _player;
    if (player == null) return;
    if (_isCurrent(generation)) setState(() => _loading = true);
    try {
      await player.stop();
      if (!_isCurrent(generation)) return;
      if (path == null || path.isEmpty) {
        setState(() {
          _ready = false;
          _loading = false;
        });
        return;
      }
      await player.open(Media(Uri.file(path).toString()), play: false);
      if (!_isCurrent(generation)) return;
      setState(() {
        _ready = true;
        _loading = false;
        _error = null;
      });
      await _playCandidate(
        widget.candidate,
        generation,
        playbackToken: _playbackToken,
      );
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() {
          _loading = false;
          _ready = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _playCandidate(
    Map<String, dynamic>? candidate,
    int generation, {
    int? playbackToken,
  }) async {
    final player = _player;
    if (player == null ||
        !_isCurrent(generation, playbackToken: playbackToken) ||
        !_ready ||
        candidate == null ||
        candidate.isEmpty) {
      return;
    }
    final start = _clipStart(candidate);
    final end = _clipEnd(candidate);
    setState(() {
      _clipEndMs = end;
      _clipEndHandled = false;
    });
    try {
      await player.seek(Duration(milliseconds: start));
      if (!_isCurrent(generation, playbackToken: playbackToken)) return;
      await player.play();
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> togglePlayPause() async {
    final generation = _mediaGeneration;
    final playbackToken = _playbackToken;
    await _queuePlayerAction(
      generation: generation,
      playbackToken: playbackToken,
      action: (player) async {
        if (player.state.playing) {
          await player.pause();
        } else if (_clipEndMs != null &&
            player.state.position.inMilliseconds >= _clipEndMs!) {
          await _playCandidate(
            widget.candidate,
            generation,
            playbackToken: playbackToken,
          );
        } else {
          await player.play();
        }
      },
    );
  }

  Future<void> _seek(Duration position) async {
    await _queuePlayerAction(
      generation: _mediaGeneration,
      playbackToken: _playbackToken,
      action: (player) => player.seek(position),
    );
  }

  Future<void> seekBy(Duration offset) async {
    final start = widget.candidate == null ? 0 : _clipStart(widget.candidate!);
    final end = widget.candidate == null ? null : _clipEnd(widget.candidate!);
    final requested = _player?.state.position.inMilliseconds ?? start;
    final targetRequested = requested + offset.inMilliseconds;
    final target =
        (end == null
                ? targetRequested.clamp(start, 1 << 62)
                : targetRequested.clamp(start, end))
            .toInt();
    await _seek(Duration(milliseconds: target));
  }

  void toggleCandidateLoop() {
    setState(() => _loopCandidate = !_loopCandidate);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final player = _player;
    final controller = _controller;
    final hasVideo = widget.videoPath != null && widget.videoPath!.isNotEmpty;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(CsRadius.md),
      ),
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _ready && _error == null
                  ? () {
                      widget.onInteraction();
                      unawaited(togglePlayPause());
                    }
                  : null,
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(color: Colors.black),
                clipBehavior: Clip.hardEdge,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (!hasVideo || controller == null || _error != null)
                      CsEmptyState(
                        icon: _error == null
                            ? Icons.movie_outlined
                            : Icons.error_outline,
                        title: !hasVideo ? '还没有视频' : _error ?? '视频加载失败',
                        description: _error == null && hasVideo
                            ? '分析完成后会在这里播放候选片段'
                            : null,
                        action: _error != null && hasVideo
                            ? CsButton(
                                label: const Text('重新加载视频'),
                                icon: Icons.refresh,
                                onPressed: _reloadVideo,
                              )
                            : null,
                      )
                    else
                      Center(
                        child: AspectRatio(
                          aspectRatio: _videoAspectRatio(widget.frameSize),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Video(
                                controller: controller,
                                controls: NoVideoControls,
                              ),
                              if (_showAnnotations && widget.candidate != null)
                                StreamBuilder<Duration>(
                                  stream: player?.stream.position,
                                  initialData:
                                      player?.state.position ?? Duration.zero,
                                  builder: (context, snapshot) =>
                                      _CandidateAnnotationLayer(
                                        candidate: widget.candidate!,
                                        frameSize: widget.frameSize,
                                        positionMs:
                                            snapshot.data?.inMilliseconds ?? 0,
                                      ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (_ready && _error == null && player != null)
                      Center(
                        child: StreamBuilder<bool>(
                          stream: player.stream.playing,
                          initialData: player.state.playing,
                          builder: (context, snapshot) => _CenterPlaybackButton(
                            playing: snapshot.data == true,
                            onPressed: () {
                              widget.onInteraction();
                              unawaited(togglePlayPause());
                            },
                          ),
                        ),
                      ),
                    if (_loading)
                      const ColoredBox(
                        color: Colors.black26,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (widget.candidate != null)
                      Positioned(
                        top: Spacing.sm,
                        right: Spacing.sm,
                        child: _AnnotationToggle(
                          enabled: _showAnnotations,
                          onChanged: (value) =>
                              setState(() => _showAnnotations = value),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          _VideoControls(
            player: player,
            clipStartMs: widget.candidate == null
                ? null
                : _clipStart(widget.candidate!),
            clipEndMs: widget.candidate == null
                ? null
                : _clipEnd(widget.candidate!),
            enabled: _ready && _error == null,
            hasPrevious: widget.hasPrevious,
            hasNext: widget.hasNext,
            onPrevious: widget.onPrevious,
            onNext: widget.onNext,
            onSeek: _seek,
            onTogglePlayback: togglePlayPause,
            onReplayCandidate: _queueCandidatePlayback,
            loopEnabled: _loopCandidate,
            onToggleLoop: toggleCandidateLoop,
          ),
          if (widget.candidate != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.sm,
                  0,
                  Spacing.sm,
                  Spacing.xs,
                ),
                child: Text(
                  '候选 ${_formatMs(_candidateTime(widget.candidate!))}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            _CandidateEvidencePanel(
              candidate: widget.candidate!,
              onEditRange: widget.onEditRange,
              onEditNote: widget.onEditNote,
              onUndo: widget.onUndo,
            ),
          ],
        ],
      ),
    );
  }
}

class _CenterPlaybackButton extends StatelessWidget {
  const _CenterPlaybackButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tooltip(
      message: playing ? '暂停（Space）' : '播放（Space）',
      child: Material(
        color: c.background.withValues(alpha: playing ? 0.42 : 0.72),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 56,
            height: 56,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 31,
              color: c.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _AnnotationToggle extends StatelessWidget {
  const _AnnotationToggle({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: c.background.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(CsRadius.md),
      child: Padding(
        padding: const EdgeInsets.only(left: Spacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('标注', style: TextStyle(color: c.textPrimary, fontSize: 11)),
            Tooltip(
              message: enabled ? '关闭标注' : '显示标注',
              child: Switch(
                value: enabled,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateAnnotationLayer extends StatelessWidget {
  const _CandidateAnnotationLayer({
    required this.candidate,
    required this.frameSize,
    required this.positionMs,
  });

  final Map<String, dynamic> candidate;
  final Size frameSize;
  final int positionMs;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _CandidateAnnotationPainter(
        candidate: candidate,
        frameSize: frameSize,
        positionMs: positionMs,
      ),
      child: const SizedBox.expand(),
    ),
  );
}

class _CandidateAnnotationPainter extends CustomPainter {
  _CandidateAnnotationPainter({
    required this.candidate,
    required this.frameSize,
    required this.positionMs,
  });

  final Map<String, dynamic> candidate;
  final Size frameSize;
  final int positionMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameSize.width <= 0 || frameSize.height <= 0) return;
    final evidence = _candidateEvidence(candidate);
    final verdict = _candidateEvidenceValue(candidate, evidence, const [
      ['verification', 'verdict'],
      ['verdict'],
    ]);
    final completeCrossing = _candidateEvidenceValue(
      candidate,
      evidence,
      const [
        ['verification', 'complete_crossing'],
        ['complete_crossing'],
      ],
    );
    final rawOverlay = evidence['overlay'];
    if (rawOverlay is! Map) return;
    final overlay = rawOverlay.cast<String, dynamic>();
    final rim = overlay['rim'];
    if (rim is! Map) return;

    final current = positionMs / 1000.0;
    final centerX = _pointX(rim['center_x'], size.width);
    final rimY = _pointY(rim['rim_y'], size.height);
    final rimWidth = _scaledX(rim['width'], size.width);
    final rimHeight = _scaledY(rim['height'] ?? 12, size.height);
    final rimPaint = Paint()
      ..color = const Color(0xFFFFB454)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(centerX, rimY),
        width: rimWidth,
        height: rimHeight.clamp(4.0, 28.0).toDouble(),
      ),
      rimPaint,
    );
    canvas.drawLine(
      Offset(centerX - rimWidth / 2, rimY),
      Offset(centerX + rimWidth / 2, rimY),
      rimPaint,
    );

    final rawTrajectory = overlay['trajectory'];
    final points = rawTrajectory is List
        ? rawTrajectory
              .whereType<Map>()
              .map((point) => point.cast<String, dynamic>())
              .where((point) => _number(point['time']) <= current + 0.02)
              .map(
                (point) => Offset(
                  _pointX(point['x'], size.width),
                  _pointY(point['y'], size.height),
                ),
              )
              .toList()
        : <Offset>[];
    if (points.length >= 2) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF9AA6FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..strokeCap = StrokeCap.round,
      );
    }

    final crossing = overlay['crossing'];
    final crossingTime = crossing is Map ? _number(crossing['time']) : -1;
    final crossingX = crossing is Map
        ? _pointX(crossing['x'], size.width)
        : 0.0;
    final crossingY = crossing is Map
        ? _pointY(crossing['y'], size.height)
        : 0.0;
    final geometryValid = crossing is Map && crossing['valid'] == true;
    final crossingState = _crossingDisplayState(
      trajectory: geometryValid,
      verdict: verdict,
      completeCrossing: completeCrossing,
    );
    final resultColor = switch (crossingState) {
      _CrossingDisplay.confirmed => const Color(0xFF65C982),
      _CrossingDisplay.inferred => const Color(0xFFFFB454),
      _CrossingDisplay.rejected => const Color(0xFFF17D76),
      _CrossingDisplay.unknown => const Color(0xFF9AA6FF),
    };

    if (points.isNotEmpty && crossingTime > current) {
      final prediction = overlay['prediction'];
      if (prediction is Map && prediction['landing_x'] != null) {
        _drawDashedLine(
          canvas,
          points.last,
          Offset(_pointX(prediction['landing_x'], size.width), rimY),
          Paint()
            ..color = const Color(0xFF9AA6FF)
            ..strokeWidth = 1.0,
        );
      }
    }

    if (points.isNotEmpty) {
      final ballPaint = Paint()..color = const Color(0xFFE97832);
      canvas.drawCircle(points.last, 5, ballPaint);
      canvas.drawCircle(
        points.last,
        8,
        Paint()
          ..color = const Color(0xFFE97832).withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }

    if (crossingTime >= 0 && current >= crossingTime - 0.2) {
      final pulse = (1 - ((current - crossingTime).abs() / 0.45))
          .clamp(0.0, 1.0)
          .toDouble();
      canvas.drawCircle(
        Offset(crossingX, crossingY),
        8 + 8 * pulse,
        Paint()
          ..color = resultColor.withValues(alpha: 0.70 * pulse)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      canvas.drawCircle(
        Offset(crossingX, crossingY),
        4,
        Paint()..color = resultColor,
      );
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const segments = 10;
    for (var index = 0; index < segments; index += 2) {
      final startT = index / segments;
      final endT = (index + 1) / segments;
      canvas.drawLine(
        Offset.lerp(start, end, startT)!,
        Offset.lerp(start, end, endT)!,
        paint,
      );
    }
  }

  double _pointX(dynamic value, double width) =>
      (_number(value) / frameSize.width).clamp(0.0, 1.0) * width;

  double _pointY(dynamic value, double height) =>
      (_number(value) / frameSize.height).clamp(0.0, 1.0) * height;

  double _scaledX(dynamic value, double width) =>
      (_number(value) / frameSize.width).clamp(0.0, 1.0) * width;

  double _scaledY(dynamic value, double height) =>
      (_number(value) / frameSize.height).clamp(0.0, 1.0) * height;

  @override
  bool shouldRepaint(covariant _CandidateAnnotationPainter oldDelegate) =>
      oldDelegate.positionMs != positionMs ||
      oldDelegate.candidate != candidate;
}

class _VideoControls extends StatefulWidget {
  const _VideoControls({
    required this.player,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onTogglePlayback,
    required this.onReplayCandidate,
    required this.loopEnabled,
    required this.onToggleLoop,
  });

  final Player? player;
  final int? clipStartMs;
  final int? clipEndMs;
  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function() onReplayCandidate;
  final bool loopEnabled;
  final VoidCallback onToggleLoop;

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  double? _dragValue;

  @override
  void didUpdateWidget(covariant _VideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) _dragValue = null;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final player = widget.player;
    if (player == null) return const SizedBox(height: 32);
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, positionSnapshot) => StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: player.state.duration,
        builder: (context, durationSnapshot) {
          final duration = durationSnapshot.data ?? Duration.zero;
          final mediaEnd = duration.inMilliseconds;
          final rangeStart = (widget.clipStartMs ?? 0)
              .clamp(0, mediaEnd)
              .toInt();
          final requestedEnd = widget.clipEndMs ?? mediaEnd;
          final rangeEnd = requestedEnd
              .clamp(
                rangeStart + 1,
                mediaEnd > rangeStart ? mediaEnd : rangeStart + 1,
              )
              .toInt();
          final positionMs =
              (_dragValue?.round() ??
                      positionSnapshot.data?.inMilliseconds ??
                      rangeStart)
                  .clamp(rangeStart, rangeEnd)
                  .toInt();
          final value = positionMs.clamp(rangeStart, rangeEnd).toDouble();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: Column(
              children: [
                SizedBox(
                  height: 22,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 4,
                      ),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      min: rangeStart.toDouble(),
                      max: rangeEnd.toDouble(),
                      value: value,
                      onChanged: !widget.enabled || mediaEnd <= 0
                          ? null
                          : (next) => setState(() => _dragValue = next),
                      onChangeEnd: !widget.enabled || mediaEnd <= 0
                          ? null
                          : (next) async {
                              setState(() => _dragValue = null);
                              await widget.onSeek(
                                Duration(milliseconds: next.round()),
                              );
                            },
                    ),
                  ),
                ),
                Row(
                  children: [
                    Text(
                      '${_formatDuration(Duration(milliseconds: positionMs - rangeStart))} / '
                      '${_formatDuration(Duration(milliseconds: rangeEnd - rangeStart))}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '上一个候选 (↑)',
                      onPressed: widget.enabled && widget.hasPrevious
                          ? widget.onPrevious
                          : null,
                      icon: const Icon(Icons.skip_previous, size: 19),
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    StreamBuilder<bool>(
                      stream: player.stream.playing,
                      initialData: false,
                      builder: (context, snapshot) => IconButton(
                        tooltip: snapshot.data == true
                            ? '暂停 (Space)'
                            : '播放 (Space)',
                        onPressed: !widget.enabled
                            ? null
                            : () => unawaited(widget.onTogglePlayback()),
                        icon: Icon(
                          snapshot.data == true
                              ? Icons.pause
                              : Icons.play_arrow,
                          size: 22,
                        ),
                        constraints: const BoxConstraints.tightFor(
                          width: 36,
                          height: 36,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一个候选 (↓)',
                      onPressed: widget.enabled && widget.hasNext
                          ? widget.onNext
                          : null,
                      icon: const Icon(Icons.skip_next, size: 19),
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: '重播当前片段 (R)',
                      onPressed: widget.enabled
                          ? () => unawaited(widget.onReplayCandidate())
                          : null,
                      icon: const Icon(Icons.replay, size: 18),
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: widget.loopEnabled ? '关闭循环播放 (L)' : '循环当前片段 (L)',
                      onPressed: widget.enabled ? widget.onToggleLoop : null,
                      icon: Icon(
                        Icons.repeat,
                        size: 18,
                        color: widget.loopEnabled ? c.indigo : null,
                      ),
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CandidateEvidencePanel extends StatelessWidget {
  const _CandidateEvidencePanel({
    required this.candidate,
    required this.onEditRange,
    required this.onEditNote,
    required this.onUndo,
  });

  final Map<String, dynamic> candidate;
  final VoidCallback? onEditRange;
  final VoidCallback? onEditNote;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final evidence = _candidateEvidence(candidate);
    final trajectory = _candidateEvidenceValue(candidate, evidence, const [
      ['verification', 'trajectory_cross'],
      ['trajectory_cross'],
    ]);
    final net = _candidateEvidenceValue(candidate, evidence, const [
      ['signals', 'net_inside_motion_score'],
      ['net_inside_motion_score'],
      ['signals', 'net_score'],
      ['net_score'],
      ['net_motion_score'],
    ]);
    final rebound = _candidateEvidenceValue(candidate, evidence, const [
      ['verification', 'rebound'],
      ['rim_rebound'],
      ['rebound'],
    ]);
    final verdict = _candidateEvidenceValue(candidate, evidence, const [
      ['verification', 'verdict'],
      ['verdict'],
    ]);
    final completeCrossing = _candidateEvidenceValue(
      candidate,
      evidence,
      const [
        ['verification', 'complete_crossing'],
        ['complete_crossing'],
      ],
    );
    final crossingState = _crossingDisplayState(
      trajectory: trajectory,
      verdict: verdict,
      completeCrossing: completeCrossing,
    );
    final reason = _candidateEvidenceValue(candidate, evidence, const [
      ['review_reason_suggestion', 'primary'],
      ['review_reason'],
    ]);
    final clip =
        '片段 ${_formatMs(_clipStart(candidate))} - ${_formatMs(_clipEnd(candidate))} · '
        '时长 ${_formatClipDuration(_clipEnd(candidate) - _clipStart(candidate))}';

    return Container(
      width: double.infinity,
      height: 54,
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: 3,
              ),
              child: Row(
                children: [
                  _EvidenceCell(
                    label: '片段',
                    value: clip,
                    width: 190,
                    color: c.textPrimary,
                  ),
                  _EvidenceCell(
                    label: '备注',
                    value:
                        candidate['note']?.toString().trim().isNotEmpty == true
                        ? candidate['note']!.toString()
                        : '—',
                    width: 150,
                    color: c.textSecondary,
                  ),
                  _EvidenceCell(
                    label: '候选置信度',
                    value: _candidateConfidence(candidate) ?? '—',
                    width: 72,
                    color: c.textPrimary,
                  ),
                  _EvidenceCell(
                    label: '轨迹穿框',
                    value: _formatCrossing(crossingState),
                    width: 92,
                    color: _crossingColor(c, crossingState),
                  ),
                  _EvidenceCell(
                    label: '篮网运动',
                    value: _formatSignal(net),
                    width: 82,
                    color: _signalColor(c, net),
                  ),
                  _EvidenceCell(
                    label: '反弹判断',
                    value: _formatRebound(rebound),
                    width: 82,
                    color: _reboundColor(c, rebound),
                  ),
                  _EvidenceCell(
                    label: '系统说明',
                    value: _reviewReasonLabel(reason),
                    width: 135,
                    color: c.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: c.border)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '调整片段范围',
                  onPressed: onEditRange,
                  icon: const Icon(Icons.tune_rounded, size: 17),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: '编辑备注',
                  onPressed: onEditNote,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: '撤销上一次审核 (Cmd/Ctrl+Z)',
                  onPressed: onUndo,
                  icon: const Icon(Icons.undo_rounded, size: 17),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipRangeDialog extends StatefulWidget {
  const _ClipRangeDialog({
    required this.videoPath,
    required this.startMs,
    required this.endMs,
    required this.durationMs,
  });

  final String? videoPath;
  final int startMs;
  final int endMs;
  final int durationMs;

  @override
  State<_ClipRangeDialog> createState() => _ClipRangeDialogState();
}

class _ClipRangeDialogState extends State<_ClipRangeDialog> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  late int _startMs;
  late int _endMs;
  int _positionMs = 0;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startMs = widget.startMs;
    _endMs = widget.endMs;
    _positionMs = _startMs;
    unawaited(_openVideo());
  }

  Future<void> _openVideo() async {
    final path = widget.videoPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      if (mounted) setState(() => _error = '原始视频不可用，无法预览片段范围');
      return;
    }
    try {
      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      _controller = VideoController(player);
      _positionSubscription = player.stream.position.listen((position) {
        if (!mounted) return;
        final next = position.inMilliseconds;
        if ((next - _positionMs).abs() >= 100) {
          setState(() => _positionMs = next);
        }
      });
      await player.open(Media(Uri.file(path).toString()), play: false);
      await player.seek(Duration(milliseconds: _startMs));
      if (mounted && identical(player, _player)) {
        setState(() => _ready = true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _seek(int position) async {
    final target = position.clamp(0, widget.durationMs).toInt();
    setState(() => _positionMs = target);
    await _player?.seek(Duration(milliseconds: target));
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null) return;
    if (player.state.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  void _restoreDefault() {
    setState(() {
      _startMs = widget.startMs;
      _endMs = widget.endMs;
    });
    unawaited(_seek(_startMs));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final contextStart = (widget.startMs - 15000).clamp(0, widget.durationMs);
    final contextEnd = (widget.endMs + 15000).clamp(
      contextStart + 1000,
      widget.durationMs,
    );
    final start = _startMs.clamp(contextStart, contextEnd - 1000).toInt();
    final end = _endMs.clamp(start + 1000, contextEnd).toInt();
    final controller = _controller;
    return Dialog(
      insetPadding: const EdgeInsets.all(Spacing.lg),
      child: SizedBox(
        width: 860,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('调整片段范围', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Spacing.xs),
              Text(
                '拖动时间轴两端即可调整。视频会跳到正在拖动的一端；原视频不会被修改。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: Spacing.sm),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.black),
                  child: _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: c.error),
                          ),
                        )
                      : controller == null || !_ready
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Video(
                          controller: controller,
                          controls: NoVideoControls,
                        ),
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Row(
                children: [
                  IconButton(
                    tooltip: '播放/暂停',
                    onPressed: _ready
                        ? () => unawaited(_togglePlayback())
                        : null,
                    icon: StreamBuilder<bool>(
                      stream: _player?.stream.playing,
                      initialData: _player?.state.playing ?? false,
                      builder: (context, snapshot) => Icon(
                        snapshot.data == true
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                  ),
                  Text(
                    '当前位置 ${_formatMs(_positionMs)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '片段 ${_formatMs(start)} - ${_formatMs(end)} · '
                    '${_formatClipDuration(end - start)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              RangeSlider(
                min: contextStart.toDouble(),
                max: contextEnd.toDouble(),
                divisions: ((contextEnd - contextStart) ~/ 100).clamp(10, 600),
                values: RangeValues(start.toDouble(), end.toDouble()),
                onChanged: _ready
                    ? (value) {
                        final nextStart = value.start.round();
                        final nextEnd = value.end.round();
                        final startMoved = (nextStart - start).abs();
                        final endMoved = (nextEnd - end).abs();
                        setState(() {
                          _startMs = nextStart;
                          _endMs = nextEnd;
                        });
                        unawaited(
                          _seek(startMoved >= endMoved ? nextStart : nextEnd),
                        );
                      }
                    : null,
              ),
              Row(
                children: [
                  Text(
                    _formatMs(contextStart),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
                  ),
                  const Spacer(),
                  Text(
                    _formatMs(contextEnd),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _restoreDefault,
                    child: const Text('恢复默认'),
                  ),
                  const SizedBox(width: Spacing.sm),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: Spacing.sm),
                  FilledButton(
                    onPressed: end > start
                        ? () => Navigator.pop(context, (
                            startMs: start,
                            endMs: end,
                          ))
                        : null,
                    child: const Text('应用'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EvidenceCell extends StatelessWidget {
  const _EvidenceCell({
    required this.label,
    required this.value,
    required this.width,
    required this.color,
  });

  final String label;
  final String value;
  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: c.textTertiary, fontSize: 9)),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidatePanel extends StatelessWidget {
  const _CandidatePanel({
    required this.candidates,
    required this.selectedId,
    required this.includedCount,
    required this.totalCount,
    required this.filter,
    required this.busy,
    required this.hydrating,
    required this.hydrateError,
    required this.analyzing,
    required this.hasVideo,
    required this.onSelect,
    required this.onSetStatus,
    required this.onLoadCover,
    required this.onFilterChanged,
    required this.onReanalyze,
    required this.onRetryHydration,
    required this.onEditRange,
    required this.onEditNote,
    required this.onUndo,
    required this.onGoImport,
    required this.onExport,
  });

  final List<Map<String, dynamic>> candidates;
  final String? selectedId;
  final int includedCount;
  final int totalCount;
  final String filter;
  final bool busy;
  final bool hydrating;
  final String? hydrateError;
  final bool analyzing;
  final bool hasVideo;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final Future<void> Function(String, String) onSetStatus;
  final Future<String?> Function(String, int)? onLoadCover;
  final ValueChanged<String> onFilterChanged;
  final VoidCallback? onReanalyze;
  final VoidCallback? onRetryHydration;
  final VoidCallback? onEditRange;
  final VoidCallback? onEditNote;
  final VoidCallback onUndo;
  final VoidCallback onGoImport;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(CsRadius.md),
      ),
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.xs,
        Spacing.sm,
        Spacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('候选片段', style: theme.textTheme.titleSmall),
              const SizedBox(width: Spacing.sm),
              Text(
                '已选 $includedCount / $totalCount',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '筛选候选',
                initialValue: filter,
                onSelected: onFilterChanged,
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'all', child: Text('全部候选')),
                  PopupMenuItem(value: 'pending', child: Text('待审核')),
                  PopupMenuItem(value: 'confirmed', child: Text('已确认')),
                  PopupMenuItem(value: 'excluded', child: Text('已排除')),
                  PopupMenuItem(value: 'low', child: Text('低置信度')),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _candidateFilterLabel(filter),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                    Icon(Icons.expand_more, size: 15, color: c.textSecondary),
                  ],
                ),
              ),
              Tooltip(
                message:
                    '快捷键\nSpace  播放/暂停\nR  重播当前\nL  循环当前\n↑ / ↓  切换候选\n← / →  快退/快进 3 秒\nC / Enter  保留\nX / Backspace  排除\nCmd/Ctrl+Z  撤销',
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    Icons.keyboard_outlined,
                    size: 17,
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Expanded(
            child: candidates.isEmpty
                ? _EmptyCandidates(
                    hydrating: hydrating,
                    hydrateError: hydrateError,
                    analyzing: analyzing,
                    hasVideo: hasVideo,
                    filterEmpty: totalCount > 0,
                    onClearFilter: filter == 'all'
                        ? null
                        : () => onFilterChanged('all'),
                    onReanalyze: onReanalyze,
                    onRetryHydration: onRetryHydration,
                    onGoImport: onGoImport,
                  )
                : ListView.separated(
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: c.border.withValues(alpha: 0.7),
                    ),
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      final id = candidate['id']?.toString() ?? '';
                      final coverFuture = onLoadCover == null
                          ? null
                          : onLoadCover!(id, _candidateTime(candidate));
                      return _CandidateRow(
                        key: ValueKey(id),
                        candidate: candidate,
                        index: index,
                        selected: id == selectedId,
                        excluded: _isExcluded(candidate),
                        busy: busy,
                        onTap: () => onSelect(candidate),
                        onInclude: () => unawaited(onSetStatus(id, 'included')),
                        onExclude: () => unawaited(onSetStatus(id, 'excluded')),
                        coverFuture: coverFuture,
                      );
                    },
                  ),
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Expanded(
                child: CsButton(
                  label: Text('导出 $includedCount 个片段'),
                  icon: Icons.file_upload_outlined,
                  size: CsButtonSize.sm,
                  onPressed: onExport,
                ),
              ),
              if (onReanalyze != null) ...[
                const SizedBox(width: Spacing.xs),
                IconButton(
                  tooltip: '重新分析当前视频',
                  onPressed: onReanalyze,
                  icon: const Icon(Icons.replay, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyCandidates extends StatelessWidget {
  const _EmptyCandidates({
    required this.analyzing,
    required this.hydrating,
    required this.hydrateError,
    required this.hasVideo,
    required this.filterEmpty,
    required this.onClearFilter,
    required this.onReanalyze,
    required this.onRetryHydration,
    required this.onGoImport,
  });

  final bool analyzing;
  final bool hydrating;
  final String? hydrateError;
  final bool hasVideo;
  final bool filterEmpty;
  final VoidCallback? onClearFilter;
  final VoidCallback? onReanalyze;
  final VoidCallback? onRetryHydration;
  final VoidCallback onGoImport;

  @override
  Widget build(BuildContext context) {
    if (hydrating) {
      return const CsEmptyState(
        icon: Icons.sync,
        title: '正在恢复项目',
        description: '正在加载候选片段和审核记录。',
      );
    }
    if (hydrateError != null) {
      return CsEmptyState(
        icon: Icons.sync_problem_outlined,
        title: '项目数据加载失败',
        description: '候选片段没有成功恢复，请重试加载，不需要重新分析视频。',
        action: CsButton(
          label: const Text('重试加载'),
          icon: Icons.refresh,
          onPressed: onRetryHydration,
        ),
      );
    }
    if (analyzing) {
      return const CsEmptyState(
        icon: Icons.hourglass_top,
        title: '正在等待候选片段',
        description: '分析完成后会显示候选片段。',
      );
    }
    if (filterEmpty) {
      return CsEmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: '没有匹配的候选',
        description: '当前筛选条件下没有片段。',
        action: onClearFilter == null
            ? null
            : CsButton(
                label: const Text('显示全部'),
                icon: Icons.filter_alt_off,
                onPressed: onClearFilter,
              ),
      );
    }
    return CsEmptyState(
      icon: Icons.inbox_outlined,
      title: hasVideo ? '暂未找到候选片段' : '还没有分析结果',
      description: hasVideo ? '可以重新分析当前视频，或先调整篮筐区域。' : '先导入视频并框选篮筐区域，再开始分析。',
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: Spacing.xs,
        children: [
          if (hasVideo)
            CsButton(
              label: const Text('重新分析'),
              icon: Icons.replay,
              onPressed: onReanalyze,
            ),
          CsButton(
            label: Text(hasVideo ? '调整区域' : '去导入视频'),
            icon: hasVideo ? Icons.crop : Icons.upload_file,
            variant: CsButtonVariant.secondary,
            onPressed: onGoImport,
          ),
        ],
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.index,
    required this.selected,
    required this.excluded,
    required this.busy,
    required this.onTap,
    required this.onInclude,
    required this.onExclude,
    required this.coverFuture,
    super.key,
  });

  final Map<String, dynamic> candidate;
  final int index;
  final bool selected;
  final bool excluded;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onInclude;
  final VoidCallback onExclude;
  final Future<String?>? coverFuture;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label:
          '候选 ${index + 1}，${_formatMs(_candidateTime(candidate))}，${excluded ? '已排除' : '已保留'}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: DurationD.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.xs,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: selected ? c.indigo.withValues(alpha: 0.10) : null,
            borderRadius: BorderRadius.circular(CsRadius.sm),
            border: selected
                ? Border.all(color: c.indigo.withValues(alpha: 0.45))
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          _CandidateCover(
                            future: coverFuture,
                            excluded: excluded,
                          ),
                          const SizedBox(width: Spacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${index + 1}. ${_formatMs(_candidateTime(candidate))}',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: excluded
                                        ? c.textTertiary
                                        : c.textPrimary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '时长 ${_formatClipDuration(_clipEnd(candidate) - _clipStart(candidate))}',
                                  style: theme.textTheme.labelSmall?.copyWith(
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
              ),
              const SizedBox(width: Spacing.xs),
              _DecisionButton(
                tooltip: '保留片段 (C / Enter)',
                icon: Icons.check_rounded,
                active: !excluded,
                color: c.goal,
                enabled: !busy,
                onPressed: onInclude,
              ),
              const SizedBox(width: Spacing.xs),
              _DecisionButton(
                tooltip: '排除片段 (X / Backspace)',
                icon: Icons.close_rounded,
                active: excluded,
                color: c.error,
                enabled: !busy,
                onPressed: onExclude,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DecisionButton extends StatelessWidget {
  const _DecisionButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.color,
    required this.enabled,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final Color color;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final background = active
        ? color.withValues(alpha: 0.16)
        : c.surface3.withValues(alpha: 0.72);
    final foreground = active ? color : c.textTertiary;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: active,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(CsRadius.sm),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(CsRadius.sm),
            child: SizedBox(
              width: 52,
              height: 44,
              child: Icon(icon, size: 21, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

class _CandidateCover extends StatefulWidget {
  const _CandidateCover({required this.future, required this.excluded});

  final Future<String?>? future;
  final bool excluded;

  @override
  State<_CandidateCover> createState() => _CandidateCoverState();
}

class _CandidateCoverState extends State<_CandidateCover> {
  late Future<String?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.future ?? Future.value(null);
  }

  @override
  void didUpdateWidget(covariant _CandidateCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.future != widget.future) {
      _future = widget.future ?? Future.value(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snapshot) {
        final path = snapshot.data;
        final cover = path != null
            ? Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(c),
              )
            : _placeholder(c);
        return Opacity(
          opacity: widget.excluded ? 0.45 : 1,
          child: SizedBox(
            width: 82,
            height: 52,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CsRadius.sm),
              child: cover,
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(AppColors c) => ColoredBox(
    color: c.surface3,
    child: Icon(Icons.movie_outlined, size: 19, color: c.textTertiary),
  );
}

bool _isExcluded(Map<String, dynamic> candidate) =>
    candidate['selection_status']?.toString() == 'excluded' ||
    candidate['review_status']?.toString() == 'excluded';

bool _isConfirmed(Map<String, dynamic> candidate) =>
    candidate['review_status']?.toString() == 'goal' ||
    candidate['status']?.toString() == 'goal';

bool _isPending(Map<String, dynamic> candidate) =>
    !_isExcluded(candidate) && !_isConfirmed(candidate);

bool _isLowConfidence(Map<String, dynamic> candidate) {
  final confidence = candidate['confidence']?.toString().toLowerCase();
  if (confidence == 'low' || confidence == 'review') return true;
  final score = candidate['score'];
  return score is num && score < 0.48;
}

List<Map<String, dynamic>> _filterCandidates(
  List<Map<String, dynamic>> candidates,
  String filter,
) {
  return switch (filter) {
    'pending' => candidates.where(_isPending).toList(),
    'confirmed' => candidates.where(_isConfirmed).toList(),
    'excluded' => candidates.where(_isExcluded).toList(),
    'low' => candidates.where(_isLowConfidence).toList(),
    _ => candidates,
  };
}

String _candidateFilterLabel(String filter) =>
    const <String, String>{
      'all': '全部',
      'pending': '待审核',
      'confirmed': '已确认',
      'excluded': '已排除',
      'low': '低置信度',
    }[filter] ??
    '全部';

int _candidateTime(Map<String, dynamic> candidate) {
  final value = candidate['event_time_ms'];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

int _clipStart(Map<String, dynamic> candidate) {
  final value = candidate['review_start_ms'] ?? candidate['default_start_ms'];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

int _clipEnd(Map<String, dynamic> candidate) {
  final value = candidate['review_end_ms'] ?? candidate['default_end_ms'];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

String _candidateSignature(Map<String, dynamic>? candidate) {
  if (candidate == null) return '';
  return '${candidate['id']}|${_clipStart(candidate)}|${_clipEnd(candidate)}';
}

final Expando<Map<String, dynamic>> _candidateEvidenceCache = Expando();

Map<String, dynamic> _candidateEvidence(Map<String, dynamic> candidate) {
  final cached = _candidateEvidenceCache[candidate];
  if (cached != null) return cached;
  final raw = candidate['evidence_json'] ?? candidate['evidence'];
  if (raw is Map) {
    final parsed = raw.cast<String, dynamic>();
    _candidateEvidenceCache[candidate] = parsed;
    return parsed;
  }
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final parsed = decoded.cast<String, dynamic>();
        _candidateEvidenceCache[candidate] = parsed;
        return parsed;
      }
    } on FormatException {
      return const <String, dynamic>{};
    }
  }
  return const <String, dynamic>{};
}

double _number(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0.0;
}

Size _videoFrameSize(Map<String, dynamic>? video) {
  final width = _number(video?['width']);
  final height = _number(video?['height']);
  if (width <= 0 || height <= 0) return const Size(16, 9);
  return Size(width, height);
}

double _videoAspectRatio(Size frameSize) =>
    frameSize.width > 0 && frameSize.height > 0
    ? frameSize.width / frameSize.height
    : 16 / 9;

dynamic _candidateEvidenceValue(
  Map<String, dynamic> candidate,
  Map<String, dynamic> evidence,
  List<List<String>> paths,
) {
  for (final path in paths) {
    final fromEvidence = _readEvidencePath(evidence, path);
    if (fromEvidence != null) return fromEvidence;
    final fromCandidate = _readEvidencePath(candidate, path);
    if (fromCandidate != null) return fromCandidate;
  }
  return null;
}

dynamic _readEvidencePath(Map<String, dynamic> source, List<String> path) {
  dynamic current = source;
  for (final key in path) {
    if (current is! Map || !current.containsKey(key)) return null;
    current = current[key];
  }
  return current;
}

enum _CrossingDisplay { confirmed, inferred, rejected, unknown }

_CrossingDisplay _crossingDisplayState({
  required dynamic trajectory,
  required dynamic verdict,
  required dynamic completeCrossing,
}) {
  if (trajectory != true) {
    return trajectory is bool
        ? _CrossingDisplay.rejected
        : _CrossingDisplay.unknown;
  }
  if (verdict?.toString() == 'made' && completeCrossing == true) {
    return _CrossingDisplay.confirmed;
  }
  if (completeCrossing == false) return _CrossingDisplay.rejected;
  return _CrossingDisplay.inferred;
}

String _formatCrossing(_CrossingDisplay state) => switch (state) {
  _CrossingDisplay.confirmed => '通过',
  _CrossingDisplay.inferred => '推定穿框',
  _CrossingDisplay.rejected => '未通过',
  _CrossingDisplay.unknown => '—',
};

String _formatSignal(dynamic value) {
  if (value is bool) return value ? '有支持' : '信号较弱';
  if (value is num) {
    if (value >= 0.65) return '明显';
    if (value >= 0.15) return '有运动';
    return '信号较弱';
  }
  return '—';
}

String _formatRebound(dynamic value) {
  if (value is bool) return value ? '检测到' : '未发现';
  return '—';
}

String _reviewReasonLabel(dynamic value) =>
    const <String, String>{
      'pass_ball': '可能传球',
      'no_shot': '可能未形成投篮',
      'rim_out': '可能擦框/弹出',
      'rebound': '可能反弹',
      'net_no_motion': '篮网信号较弱',
      'uncertain': '证据不确定',
    }[value?.toString()] ??
    '—';

Color _crossingColor(AppColors c, _CrossingDisplay state) => switch (state) {
  _CrossingDisplay.confirmed => c.success,
  _CrossingDisplay.inferred => c.warning,
  _CrossingDisplay.rejected => c.error,
  _CrossingDisplay.unknown => c.textSecondary,
};

Color _signalColor(AppColors c, dynamic value) =>
    value is num && value >= 0.65 ? c.success : c.textSecondary;

Color _reboundColor(AppColors c, dynamic value) =>
    value is bool && value ? c.warning : c.textSecondary;

String? _candidateConfidence(Map<String, dynamic> candidate) {
  final raw = candidate['confidence']?.toString();
  if (raw != null && raw.isNotEmpty) {
    return const <String, String>{
          'high': '高',
          'review': '复核',
          'medium': '中',
          'low': '低',
        }[raw] ??
        raw;
  }
  final score = candidate['score'];
  if (score is num) return '${(score.clamp(0, 1) * 100).round()}%';
  return null;
}

String _formatClipDuration(int milliseconds) {
  final seconds = (milliseconds / 1000).round();
  if (seconds < 60) return '$seconds 秒';
  return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
}

String _formatMs(int milliseconds) {
  final totalSeconds = milliseconds.clamp(0, 359999999).toInt() ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${(totalSeconds % 60).toString().padLeft(2, '0')}';
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String? _resolvePlaybackPath(ProjectState state, {required bool analyzing}) {
  final paths = analyzing
      ? <String?>[state.reviewVideoPath, state.videoPath]
      : <String?>[state.videoPath, state.reviewVideoPath];
  for (final path in paths) {
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return path;
    }
  }
  for (final path in paths) {
    if (path != null && path.isNotEmpty) return path;
  }
  return null;
}

String _stageLabel(String stage) =>
    const <String, String>{
      'validate_input': '检查视频输入',
      'prepare_proxy': '生成预览视频',
      'coarse_scan': '快速扫描候选',
      'generate_candidates': '生成候选',
      'refine_candidates': '精细分析候选',
      'persist_candidates': '整理审核片段',
      'prepare_review_previews': '准备候选封面',
    }[stage] ??
    stage;

String _formatElapsed(String? startedAt) {
  if (startedAt == null || startedAt.isEmpty) return '';
  final started = DateTime.tryParse(startedAt);
  if (started == null) return '';
  final elapsed = DateTime.now().toUtc().difference(started.toUtc());
  return _formatDuration(elapsed.isNegative ? Duration.zero : elapsed);
}

String _formatEstimatedRemaining(String? startedAt, double progress) {
  if (startedAt == null ||
      startedAt.isEmpty ||
      progress < 0.03 ||
      progress >= 1) {
    return '';
  }
  final started = DateTime.tryParse(startedAt);
  if (started == null) return '';
  final elapsed = DateTime.now().toUtc().difference(started.toUtc());
  if (elapsed.isNegative || elapsed.inSeconds < 10) return '';
  final remainingMs = (elapsed.inMilliseconds * (1 - progress) / progress)
      .round();
  return _formatDuration(Duration(milliseconds: remainingMs));
}
