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
import 'media_readiness.dart';

bool _annotationHintSeen = false;

/// Opening the review video must not start playback without user input.
const bool reviewVideoAutoPlayAfterOpen = false;
const bool reviewVideoAutoPlayAfterSourceSwitch = true;
const bool reviewVideoAutoPlayAfterCandidateSwitch = true;

/// 审核工作台：视频优先，候选默认保留，用户只需要打叉剔除误检。
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  String? _selectedCandidateId;
  bool _showOriginalVideo = false;
  final Set<String> _selectedForBatch = <String>{};
  bool _batchMode = false;
  final Set<String> _reviewStartedCandidateIds = <String>{};
  String _candidateFilter = 'all';
  final _VideoPaneController _videoController = _VideoPaneController();
  int _videoSourceSwitchToken = 0;
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'review-shortcut-focus',
  );
  final Map<String, Future<String?>> _coverCache = <String, Future<String?>>{};
  final Map<String, GlobalKey> _candidateRowKeys = <String, GlobalKey>{};
  final ScrollController _candidateScrollController = ScrollController();
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureCandidateVisible(id);
      });
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

  void _toggleVideoSource() {
    final state = ref.read(projectProvider);
    final hasReviewSource =
        (state.reviewVideoPath ?? state.previewPath)?.isNotEmpty == true;
    if (!hasReviewSource) return;
    setState(() {
      _showOriginalVideo = !_showOriginalVideo;
      _videoSourceSwitchToken++;
    });
  }

  Future<void> _setPlayerForCandidate(
    Map<String, dynamic> candidate,
    ProjectNotifier notifier,
    String? playerId,
  ) async {
    if (!mounted) return;
    await notifier.setCandidatePlayer(candidate['id'].toString(), playerId);
  }

  Future<String?> _promptPlayerName() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TextEntryDialog(
        title: '添加球员',
        hintText: '例如：科比、罗斯',
        confirmLabel: '添加',
      ),
    );
    return name?.trim().isEmpty == true ? null : name?.trim();
  }

  Future<void> _createPlayerForCandidate(
    Map<String, dynamic> candidate,
    ProjectNotifier notifier,
  ) async {
    final name = await _promptPlayerName();
    if (!mounted || name == null) return;
    final playerId = await notifier.createPlayer(name);
    if (!mounted || playerId == null) return;
    await notifier.setCandidatePlayer(candidate['id'].toString(), playerId);
  }

  void _toggleBatchMode() {
    setState(() {
      _batchMode = !_batchMode;
      _selectedForBatch.clear();
    });
    _focusReviewShortcuts();
  }

  void _toggleBatchCandidate(String id) {
    setState(() {
      if (!_selectedForBatch.add(id)) _selectedForBatch.remove(id);
    });
  }

  Future<void> _setPlayerForBatch(
    ProjectNotifier notifier,
    String? playerId,
  ) async {
    if (_selectedForBatch.isEmpty) return;
    await notifier.setCandidatesPlayer(_selectedForBatch.toList(), playerId);
    if (mounted) setState(() => _selectedForBatch.clear());
  }

  Future<void> _createPlayerForBatch(ProjectNotifier notifier) async {
    if (_selectedForBatch.isEmpty) return;
    final name = await _promptPlayerName();
    if (!mounted || name == null) return;
    final playerId = await notifier.createPlayer(name);
    if (!mounted || playerId == null) return;
    await _setPlayerForBatch(notifier, playerId);
  }

  Future<void> _deletePlayer(String playerId, String playerName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除球员？'),
        content: Text('删除“$playerName”后，已标记的候选会变为未标记。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(projectProvider.notifier).deletePlayer(playerId);
  }

  void _togglePlayback() {
    unawaited(_videoController.togglePlayPause());
  }

  void _toggleCandidateLoop() {
    _videoController.toggleCandidateLoop();
  }

  void _focusReviewShortcuts() {
    _shortcutFocusNode.requestFocus();
  }

  void _seekBySeconds(double seconds) {
    unawaited(
      _videoController.seekBy(
        Duration(
          milliseconds: (seconds * Duration.millisecondsPerSecond).round(),
        ),
      ),
    );
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
      _seekBySeconds(-2);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBySeconds(2);
    } else if (key == LogicalKeyboardKey.space) {
      _togglePlayback();
    } else if (key == LogicalKeyboardKey.keyA) {
      _videoController.toggleAnnotations();
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

  Future<void> _createManualCandidate() async {
    final state = ref.read(projectProvider);
    if (state.videoPath == null || state.videoPath!.isEmpty) return;
    final durationMs = _number(state.video?['duration_ms']).round();
    if (durationMs <= 0) return;
    final positionMs = _videoController.currentPositionMs.clamp(0, durationMs);
    final startMs = (positionMs - 4000).clamp(0, durationMs - 1000).toInt();
    final endMs = (positionMs + 5000).clamp(startMs + 1000, durationMs).toInt();
    final result = await showDialog<({int startMs, int endMs})>(
      context: context,
      builder: (dialogContext) => _ClipRangeDialog(
        videoPath: state.videoPath,
        startMs: startMs,
        endMs: endMs,
        durationMs: durationMs,
        title: '补漏片段',
        description: '已定位到原视频当前时间。调整起止时间后加入候选。',
        confirmLabel: '加入候选',
      ),
    );
    if (!mounted || result == null) return;
    final created = await ref
        .read(projectProvider.notifier)
        .createManualCandidate(
          startMs: result.startMs,
          endMs: result.endMs,
          eventTimeMs: positionMs.clamp(result.startMs, result.endMs).toInt(),
        );
    if (mounted && created?['id'] != null) {
      setState(() => _selectedCandidateId = created!['id'].toString());
    }
  }

  Future<void> _editCandidateNote(Map<String, dynamic> candidate) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _TextEntryDialog(
        title: '候选备注',
        initialText: candidate['note']?.toString() ?? '',
        hintText: '例如：补篮、擦框、镜头遮挡',
        maxLines: 4,
        confirmLabel: '保存',
      ),
    );
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
      final nextId = nextIndex < 0 ? null : after[nextIndex]['id']?.toString();
      setState(() => _selectedCandidateId = nextId);
      if (nextId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _ensureCandidateVisible(nextId);
        });
      }
    }
    await future;
  }

  Future<void> _confirmReanalyze() async {
    await _confirmReanalyzeWithMode();
  }

  Future<void> _confirmReanalyzeWithMode({bool forceStandard = false}) async {
    final targetMode = forceStandard ? 'standard' : null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新分析当前视频？'),
        content: Text(
          forceStandard
              ? '快速分析可能漏检，建议改用标准模式重新分析。当前候选会在新结果成功后替换，原始视频不会被删除。'
              : '重新分析会替换当前候选列表，但不会删除原始视频。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(forceStandard ? '用标准模式重新分析' : '重新分析'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref
          .read(projectProvider.notifier)
          .startAnalysis(replaceRecoverable: true, mode: targetMode);
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
    final originalVideoPath = _resolveOriginalVideoPath(state);
    final reviewVideoPath = state.reviewVideoPath ?? state.previewPath;
    final showingOriginalVideo =
        _showOriginalVideo ||
        reviewVideoPath == null ||
        reviewVideoPath.isEmpty;
    final playbackPath = showingOriginalVideo
        ? originalVideoPath
        : reviewVideoPath;
    final reviewLocked = state.busy || state.hydrating;
    if (!reviewLocked && selectedId != null && selectedId.isNotEmpty) {
      _ensureReviewStarted(selectedId);
    }
    final includedCount = allCandidates
        .where((candidate) => !_isExcluded(candidate))
        .length;
    final fastCompleted =
        state.analysisMode == 'fast' && jobState == 'completed';
    final reanalyze = fastCompleted
        ? () => _confirmReanalyzeWithMode(forceStandard: true)
        : _confirmReanalyze;

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
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            if (analyzing ||
                jobState == 'failed' ||
                jobState == 'cancelled' ||
                job?['recoverable'] == true)
              Padding(
                key: const Key('review-status-inset'),
                padding: EdgeInsets.zero,
                child: _AnalysisBar(
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
                  onReanalyze: !analyzing && !state.busy ? reanalyze : null,
                ),
              )
            else if (jobState == 'completed')
              Padding(
                key: const Key('review-status-inset'),
                padding: EdgeInsets.zero,
                child: _CompletedLine(
                  candidateCount: allCandidates.length,
                  startedAt: job?['started_at']?.toString(),
                  finishedAt: job?['finished_at']?.toString(),
                  mode: state.analysisMode,
                  checkpoint: _decodeJobCheckpoint(job),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final video = _VideoPane(
                    controller: _videoController,
                    videoPath: playbackPath,
                    candidate: selected,
                    isOriginalVideo: showingOriginalVideo,
                    sourceSwitchToken: _videoSourceSwitchToken,
                    replayToken: _replayToken,
                    frameSize: _videoFrameSize(state.video),
                    hasPrevious: _candidateIndex(candidates, selected) > 0,
                    hasNext:
                        _candidateIndex(candidates, selected) <
                        candidates.length - 1,
                    onPrevious: () => _moveCandidate(candidates, -1),
                    onNext: () => _moveCandidate(candidates, 1),
                    onToggleVideoSource:
                        reviewVideoPath != null && reviewVideoPath.isNotEmpty
                        ? _toggleVideoSource
                        : null,
                    onInteraction: _focusReviewShortcuts,
                    onEditRange: selected == null || reviewLocked
                        ? null
                        : () => _editClipRange(selected),
                    onEditNote: selected == null || reviewLocked
                        ? null
                        : () => _editCandidateNote(selected),
                    onCreateManualCandidate:
                        reviewLocked || !showingOriginalVideo
                        ? null
                        : _createManualCandidate,
                    onUndo: () {
                      if (!reviewLocked) unawaited(notifier.undoReview());
                    },
                  );
                  final queueWidth = (constraints.maxWidth * 0.30)
                      .clamp(360.0, 460.0)
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
                    hasVideo: state.videoPath != null || state.video != null,
                    analysisMode: state.analysisMode,
                    analysisCompleted: jobState == 'completed',
                    onSelect: _selectCandidate,
                    candidateRowKeys: _candidateRowKeys,
                    candidateScrollController: _candidateScrollController,
                    onSetPlayer: (candidate, playerId) =>
                        _setPlayerForCandidate(candidate, notifier, playerId),
                    onCreatePlayer: (candidate) =>
                        _createPlayerForCandidate(candidate, notifier),
                    players: state.players,
                    batchMode: _batchMode,
                    selectedForBatch: _selectedForBatch,
                    onToggleBatch: _toggleBatchMode,
                    onToggleBatchCandidate: _toggleBatchCandidate,
                    onSetPlayerForBatch: (playerId) =>
                        _setPlayerForBatch(notifier, playerId),
                    onCreatePlayerForBatch: () =>
                        _createPlayerForBatch(notifier),
                    onDeletePlayer: _deletePlayer,
                    onSetStatus: (id, status) =>
                        _setCandidateStatus(id, status),
                    onLoadCover: state.video == null
                        ? null
                        : (id, timeMs) =>
                              _loadCandidateCover(notifier, id, timeMs),
                    onFilterChanged: (value) =>
                        setState(() => _candidateFilter = value),
                    onReanalyze: !analyzing && !state.busy && !state.hydrating
                        ? reanalyze
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
                    onCreateManualCandidate:
                        reviewLocked || !showingOriginalVideo
                        ? null
                        : _createManualCandidate,
                    onUndo: () {
                      if (!reviewLocked) unawaited(notifier.undoReview());
                    },
                    onGoImport: () => context.go('/import'),
                    onExport: includedCount == 0 || reviewLocked || analyzing
                        ? null
                        : () => context.go('/export'),
                  );
                  if (constraints.maxWidth >= Breakpoints.md) {
                    return Container(
                      color: AppColors.of(context).surface,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: video),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: AppColors.of(context).border,
                          ),
                          SizedBox(width: queueWidth, child: queue),
                        ],
                      ),
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
                        const SizedBox(height: Spacing.sm),
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

  void _ensureCandidateVisible(String id) {
    final targetContext = _candidateRowKeys[id]?.currentContext;
    if (targetContext != null) {
      unawaited(
        Scrollable.ensureVisible(
          targetContext,
          duration: DurationD.fast,
          curve: Curves.easeOut,
          alignment: 0.18,
        ),
      );
      return;
    }
    if (!_candidateScrollController.hasClients) return;
    final state = ref.read(projectProvider);
    final candidates = _filterCandidates(
      _orderedCandidates(state.candidates),
      _candidateFilter,
    );
    final index = candidates.indexWhere(
      (candidate) => candidate['id']?.toString() == id,
    );
    if (index < 0) return;
    final position = _candidateScrollController.position;
    unawaited(
      _candidateScrollController.animateTo(
        (index * 92.0).clamp(0.0, position.maxScrollExtent),
        duration: DurationD.fast,
        curve: Curves.easeOut,
      ),
    );
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
    _selectedCandidateId = null;
    _selectedForBatch.clear();
    _batchMode = false;
    _candidateFilter = 'all';
    _showOriginalVideo = false;
    _videoSourceSwitchToken++;
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
    _candidateScrollController.dispose();
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
    final attached = state == 'running' && !recoverable;
    final failed = state == 'failed' && !recoverable;
    final interrupted = recoverable || state == 'cancelled';
    final active = attached || (!failed && !interrupted);
    final value = progress.clamp(0.0, 1.0).toDouble();
    final color = failed
        ? c.error
        : interrupted
        ? c.warning
        : c.orange;
    final background = failed
        ? c.error.withValues(alpha: 0.06)
        : interrupted
        ? c.warning.withValues(alpha: 0.07)
        : c.surface2;
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
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: background,
        border: Border(bottom: BorderSide(color: c.borderStrong)),
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
                    if (active)
                      Padding(
                        padding: const EdgeInsets.only(left: Spacing.xs),
                        child: Text(
                          '分析进行中',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: c.textSecondary),
                        ),
                      ),
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
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(child: CsProgressTrack(value: value)),
                      if (elapsed.isNotEmpty) ...[
                        const SizedBox(width: Spacing.sm),
                        Text(
                          remaining.isEmpty
                              ? '已用 $elapsed'
                              : '已用 $elapsed · 剩余约 $remaining',
                          style: TextStyle(
                            fontSize: 10,
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
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
          if (onRetry != null && !attached)
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
  const _CompletedLine({
    required this.candidateCount,
    required this.startedAt,
    required this.finishedAt,
    required this.mode,
    required this.checkpoint,
  });

  final int candidateCount;
  final String? startedAt;
  final String? finishedAt;
  final String mode;
  final Map<String, dynamic> checkpoint;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final duration = _formatCompletedDuration(startedAt, finishedAt);
    final modeLabel = mode == 'fast' ? '快速分析 · 可能漏检' : '标准分析';
    final detail = _analysisDetailLabel(checkpoint);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(bottom: BorderSide(color: c.borderStrong)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 14, color: c.goal),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  '$modeLabel · $candidateCount 个候选${duration.isEmpty ? '' : ' · 用时 $duration'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
                ),
              ),
            ],
          ),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2),
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
              ),
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

class _TextEntryDialog extends StatefulWidget {
  const _TextEntryDialog({
    required this.title,
    required this.hintText,
    required this.confirmLabel,
    this.initialText = '',
    this.maxLines = 1,
  });

  final String title;
  final String hintText;
  final String confirmLabel;
  final String initialText;
  final int maxLines;

  @override
  State<_TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<_TextEntryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AlertDialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: c.borderStrong),
      ),
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: widget.maxLines,
        decoration: InputDecoration(
          hintText: widget.hintText,
          border: widget.maxLines > 1 ? const OutlineInputBorder() : null,
        ),
        onSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

class _VideoPane extends StatefulWidget {
  const _VideoPane({
    required this.controller,
    required this.videoPath,
    required this.candidate,
    required this.isOriginalVideo,
    required this.sourceSwitchToken,
    required this.replayToken,
    required this.frameSize,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onToggleVideoSource,
    required this.onInteraction,
    required this.onEditRange,
    required this.onEditNote,
    required this.onCreateManualCandidate,
    required this.onUndo,
  });

  final _VideoPaneController controller;
  final String? videoPath;
  final Map<String, dynamic>? candidate;
  final bool isOriginalVideo;
  final int sourceSwitchToken;
  final int replayToken;
  final Size frameSize;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback? onToggleVideoSource;
  final VoidCallback onInteraction;
  final VoidCallback? onEditRange;
  final VoidCallback? onEditNote;
  final VoidCallback? onCreateManualCandidate;
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
  bool _showAnnotationHint = false;
  int? _clipEndMs;
  bool _clipEndHandled = false;
  int _mediaGeneration = 0;
  bool _disposed = false;
  Future<void> _mediaQueue = Future<void>.value();
  int _playbackToken = 0;
  Timer? _annotationHintTimer;

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
    _clipEndMs = reviewTimelineBounds(
      isOriginalVideo: widget.isOriginalVideo,
      candidate: widget.candidate,
    ).endMs;
    _ensurePlayer();
    unawaited(_queueOpen(widget.videoPath));
  }

  void _ensurePlayer() {
    if (widget.videoPath == null || widget.videoPath!.isEmpty) {
      return;
    }
    if (_player == null || _controller == null) {
      try {
        MediaKit.ensureInitialized();
        _player ??= Player();
        _controller = VideoController(
          _player!,
          configuration: VideoControllerConfiguration(
            enableHardwareAcceleration: !Platform.isWindows,
          ),
        );
      } catch (error) {
        _error = error.toString();
        return;
      }
    }
    if (_positionSubscription != null) {
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
    if (oldWidget.videoPath != widget.videoPath ||
        oldWidget.isOriginalVideo != widget.isOriginalVideo) {
      // 复用 Player 时保留 VideoController(与 Player 绑定),
      // 切换片源由 _queueOpen 的 stop+open 完成。
      _ready = false;
      _loading = false;
      _error = null;
      _clipEndMs = reviewTimelineBounds(
        isOriginalVideo: widget.isOriginalVideo,
        candidate: widget.candidate,
      ).endMs;
      _clipEndHandled = false;
      if (widget.isOriginalVideo) _loopCandidate = false;
      unawaited(
        _queueOpen(
          widget.videoPath,
          playAfterOpen:
              reviewVideoAutoPlayAfterSourceSwitch &&
              oldWidget.sourceSwitchToken != widget.sourceSwitchToken,
          recreatePlayer: true,
        ),
      );
    } else if (oldWidget.replayToken != widget.replayToken) {
      if (widget.candidate != null && widget.candidate!.isNotEmpty) {
        _showAnnotationHintOnce();
        unawaited(_queueCandidatePlayback());
      }
    } else if (_candidateSignature(oldWidget.candidate) !=
        _candidateSignature(widget.candidate)) {
      final candidate = widget.candidate;
      if (!widget.isOriginalVideo &&
          candidate != null &&
          candidate.isNotEmpty) {
        setState(() {
          _clipEndMs = reviewTimelineBounds(
            isOriginalVideo: false,
            candidate: candidate,
          ).endMs;
          _clipEndHandled = false;
        });
        _showAnnotationHintOnce();
      } else if (widget.isOriginalVideo) {
        setState(() {
          _clipEndMs = null;
          _clipEndHandled = false;
        });
      }
      if (reviewVideoAutoPlayAfterCandidateSwitch) {
        unawaited(_queueCandidatePlayback());
      } else {
        unawaited(_queueCandidatePosition());
      }
    }
  }

  @override
  void dispose() {
    widget.controller._detach(this);
    _disposed = true;
    _mediaGeneration++;
    _playbackToken++;
    _annotationHintTimer?.cancel();
    final subscription = _positionSubscription;
    _positionSubscription = null;
    final player = _player;
    _player = null;
    unawaited(subscription?.cancel());
    if (player != null) {
      final pending = _mediaQueue;
      unawaited(
        pending.whenComplete(() async {
          // 此时 Video 组件已卸载、纹理不再渲染,销毁是安全的。
          try {
            await player.stop();
          } catch (_) {}
          try {
            await player.dispose();
          } catch (_) {}
        }),
      );
    }
    super.dispose();
  }

  Future<void> _queueOpen(
    String? path, {
    bool playAfterOpen = false,
    bool recreatePlayer = false,
  }) {
    final generation = ++_mediaGeneration;
    _playbackToken++;
    return _enqueueMediaAction(() async {
      if (!_isCurrent(generation)) return;
      // 复用 Player/VideoController:视频纹理渲染期间调用 player.dispose
      // 会触发原生 ~VideoOutput 析构,在 Windows 上与光栅线程死锁,
      // 整个应用无响应。切换片源只 stop + open,不销毁。
      _ensurePlayer();
      if (recreatePlayer) {
        final player = _player;
        if (player != null) {
          try {
            await player.stop();
          } catch (_) {}
        }
      }
      if (!_isCurrent(generation)) return;
      await _open(path, generation, playAfterOpen: playAfterOpen);
    });
  }

  void _reloadVideo() {
    setState(() {
      _error = null;
      _ready = false;
    });
    unawaited(_queueOpen(widget.videoPath, recreatePlayer: true));
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

  Future<void> _queueCandidatePosition() {
    final candidate = widget.candidate;
    final generation = _mediaGeneration;
    final playbackToken = ++_playbackToken;
    return _enqueueMediaAction(() async {
      if (!_isCurrent(generation, playbackToken: playbackToken)) return;
      await _prepareCandidate(
        candidate,
        generation,
        playbackToken: playbackToken,
      );
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

  Future<void> _open(
    String? path,
    int generation, {
    bool playAfterOpen = false,
  }) async {
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
      await waitForPlayableDuration(
        current: player.state.duration,
        updates: player.stream.duration,
      );
      if (!_isCurrent(generation)) return;
      setState(() {
        _ready = true;
        _loading = false;
        _error = null;
      });
      if (widget.candidate != null && widget.candidate!.isNotEmpty) {
        _showAnnotationHintOnce();
        await _prepareCandidate(
          widget.candidate,
          generation,
          playbackToken: _playbackToken,
        );
      }
      if (reviewVideoAutoPlayAfterOpen || playAfterOpen) {
        if (widget.isOriginalVideo) {
          await player.play();
        } else {
          await _playCandidate(
            widget.candidate,
            generation,
            playbackToken: _playbackToken,
          );
        }
      }
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
    setState(() {
      _clipEndMs = reviewTimelineBounds(
        isOriginalVideo: widget.isOriginalVideo,
        candidate: candidate,
      ).endMs;
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

  Future<void> _prepareCandidate(
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
    setState(() {
      _clipEndMs = reviewTimelineBounds(
        isOriginalVideo: widget.isOriginalVideo,
        candidate: candidate,
      ).endMs;
      _clipEndHandled = false;
    });
    try {
      await player.pause();
      await player.seek(Duration(milliseconds: start));
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() => _error = error.toString());
      }
    }
  }

  int get currentPositionMs => _player?.state.position.inMilliseconds ?? 0;

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
    final bounds = reviewTimelineBounds(
      isOriginalVideo: widget.isOriginalVideo,
      candidate: widget.candidate,
    );
    final start = bounds.startMs;
    final end = bounds.endMs;
    final requested = _player?.state.position.inMilliseconds ?? start;
    final targetRequested = requested + offset.inMilliseconds;
    final target =
        (end == null
                ? targetRequested.clamp(start, 1 << 62)
                : targetRequested.clamp(start, end))
            .toInt();
    await _seek(Duration(milliseconds: target));
  }

  Future<void> setPlaybackRate(double rate) async {
    await _queuePlayerAction(
      generation: _mediaGeneration,
      playbackToken: _playbackToken,
      action: (player) => player.setRate(rate),
    );
  }

  void toggleCandidateLoop() {
    setState(() => _loopCandidate = !_loopCandidate);
  }

  void toggleAnnotations() {
    if (widget.candidate == null) return;
    _setAnnotations(!_showAnnotations);
  }

  void _setAnnotations(bool value) {
    _annotationHintTimer?.cancel();
    setState(() {
      _showAnnotations = value;
      _showAnnotationHint = false;
    });
  }

  void _showAnnotationHintOnce() {
    if (_annotationHintSeen ||
        _disposed ||
        !mounted ||
        widget.candidate == null ||
        widget.candidate!.isEmpty) {
      return;
    }
    _annotationHintSeen = true;
    setState(() => _showAnnotationHint = true);
    _annotationHintTimer?.cancel();
    _annotationHintTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showAnnotationHint = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final player = _player;
    final controller = _controller;
    final hasVideo = widget.videoPath != null && widget.videoPath!.isNotEmpty;

    return Container(
      color: c.surface,
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
                            ? '分析完成后会在这里预览候选片段，点击播放开始'
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
                              IgnorePointer(
                                child: Video(
                                  controller: controller,
                                  controls: NoVideoControls,
                                ),
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
                        child: _CenterPlaybackOverlay(
                          player: player,
                          onPressed: () {
                            widget.onInteraction();
                            unawaited(togglePlayPause());
                          },
                        ),
                      ),
                    if (_loading)
                      const IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black26,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                    if (widget.onToggleVideoSource != null)
                      Positioned(
                        top: Spacing.sm,
                        left: Spacing.sm,
                        child: _VideoSourceToggle(
                          showingOriginal: widget.isOriginalVideo,
                          onPressed: widget.onToggleVideoSource!,
                        ),
                      ),
                    if (widget.candidate != null)
                      Positioned(
                        top: Spacing.sm,
                        right: Spacing.sm,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _AnnotationToggle(
                              enabled: _showAnnotations,
                              onChanged: _setAnnotations,
                            ),
                            if (_showAnnotationHint) ...[
                              const SizedBox(height: Spacing.xs),
                              const _AnnotationHint(),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: c.border),
          _VideoControls(
            player: player,
            clipStartMs: reviewTimelineBounds(
              isOriginalVideo: widget.isOriginalVideo,
              candidate: widget.candidate,
            ).startMs,
            clipEndMs: reviewTimelineBounds(
              isOriginalVideo: widget.isOriginalVideo,
              candidate: widget.candidate,
            ).endMs,
            eventTimeMs: widget.isOriginalVideo || widget.candidate == null
                ? null
                : _candidateTime(widget.candidate!),
            isOriginalVideo: widget.isOriginalVideo,
            enabled: _ready && _error == null,
            hasPrevious: widget.hasPrevious,
            hasNext: widget.hasNext,
            onPrevious: widget.onPrevious,
            onNext: widget.onNext,
            onSeek: _seek,
            onTogglePlayback: togglePlayPause,
            onReplayCandidate: _queueCandidatePlayback,
            onSetPlaybackRate: setPlaybackRate,
            loopEnabled: _loopCandidate,
            onToggleLoop: toggleCandidateLoop,
          ),
          if (widget.candidate != null)
            _CandidateEvidencePanel(
              candidate: widget.candidate!,
              onEditRange: widget.onEditRange,
              onEditNote: widget.onEditNote,
              onUndo: widget.onUndo,
            ),
        ],
      ),
    );
  }
}

class _VideoPaneController {
  _VideoPaneState? _state;

  int get currentPositionMs => _state?.currentPositionMs ?? 0;

  void _attach(_VideoPaneState state) => _state = state;

  void _detach(_VideoPaneState state) {
    if (identical(_state, state)) _state = null;
  }

  Future<void> togglePlayPause() => _state?.togglePlayPause() ?? Future.value();

  Future<void> seekBy(Duration offset) =>
      _state?.seekBy(offset) ?? Future.value();

  void toggleCandidateLoop() => _state?.toggleCandidateLoop();

  void toggleAnnotations() => _state?.toggleAnnotations();
}

class _CenterPlaybackOverlay extends StatefulWidget {
  const _CenterPlaybackOverlay({required this.player, required this.onPressed});

  final Player player;
  final VoidCallback onPressed;

  @override
  State<_CenterPlaybackOverlay> createState() => _CenterPlaybackOverlayState();
}

class _CenterPlaybackOverlayState extends State<_CenterPlaybackOverlay> {
  StreamSubscription<bool>? _playingSubscription;
  Timer? _hideTimer;
  late bool _playing;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _CenterPlaybackOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) _subscribe();
  }

  void _subscribe() {
    _playingSubscription?.cancel();
    _playing = widget.player.state.playing;
    _playingSubscription = widget.player.stream.playing.listen(_onPlaying);
    if (_playing) _scheduleHide();
  }

  void _onPlaying(bool playing) {
    if (!mounted) return;
    _hideTimer?.cancel();
    setState(() {
      _playing = playing;
      _visible = true;
    });
    if (playing) _scheduleHide();
  }

  void _reveal() {
    _hideTimer?.cancel();
    if (!_visible && mounted) setState(() => _visible = true);
    if (_playing) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted && _playing) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playingSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !_visible,
      child: MouseRegion(
        onHover: (_) => _reveal(),
        child: AnimatedOpacity(
          duration: DurationD.fast,
          opacity: _visible ? 1 : 0,
          child: _CenterPlaybackButton(
            playing: _playing,
            onPressed: widget.onPressed,
          ),
        ),
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
    final accent = enabled ? c.orange : c.textTertiary;
    return Tooltip(
      message: enabled ? '关闭标注（A）' : '显示标注（A）',
      child: Material(
        color: c.background.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(CsRadius.full),
        child: InkWell(
          onTap: () => onChanged(!enabled),
          borderRadius: BorderRadius.circular(CsRadius.full),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 5, 7, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome_outlined, size: 13, color: accent),
                const SizedBox(width: 5),
                Text(
                  '标注',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedContainer(
                  duration: DurationD.fast,
                  width: 22,
                  height: 12,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: enabled ? c.orange : c.surface3,
                    borderRadius: BorderRadius.circular(CsRadius.full),
                    border: Border.all(
                      color: enabled
                          ? c.orange.withValues(alpha: 0.8)
                          : c.borderStrong,
                    ),
                  ),
                  child: Align(
                    alignment: enabled
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: AnimatedContainer(
                      duration: DurationD.fast,
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: enabled ? Colors.white : c.textTertiary,
                        shape: BoxShape.circle,
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

class _VideoSourceToggle extends StatelessWidget {
  const _VideoSourceToggle({
    required this.showingOriginal,
    required this.onPressed,
  });

  final bool showingOriginal;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tooltip(
      message: '切换视频来源',
      child: Material(
        color: c.background.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(CsRadius.full),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _VideoSourceOption(
                label: '候选预览',
                icon: Icons.video_library_outlined,
                selected: !showingOriginal,
                onPressed: showingOriginal ? onPressed : null,
              ),
              _VideoSourceOption(
                label: '原视频',
                icon: Icons.movie_filter_outlined,
                selected: showingOriginal,
                onPressed: showingOriginal ? null : onPressed,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoSourceOption extends StatelessWidget {
  const _VideoSourceOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: selected ? '正在查看$label' : '切换到$label',
      child: Material(
        color: selected ? c.orange.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(CsRadius.full),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(CsRadius.full),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 13,
                  color: selected ? c.orange : c.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? c.textPrimary : c.textSecondary,
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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

class _AnnotationHint extends StatelessWidget {
  const _AnnotationHint();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Material(
        color: c.background.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(CsRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 210),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.xs,
            ),
            child: Text(
              '标注会显示轨迹与判定点 · 按 A 可开关',
              style: TextStyle(color: c.textSecondary, fontSize: 10),
              textAlign: TextAlign.right,
            ),
          ),
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
          ..color = const Color(0xFFFFB454)
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
      _CrossingDisplay.unknown => const Color(0xFFFFB454),
    };

    if (points.isNotEmpty && crossingTime > current) {
      final prediction = overlay['prediction'];
      if (prediction is Map && prediction['landing_x'] != null) {
        _drawDashedLine(
          canvas,
          points.last,
          Offset(_pointX(prediction['landing_x'], size.width), rimY),
          Paint()
            ..color = const Color(0xFFFFB454)
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
    required this.isOriginalVideo,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.eventTimeMs,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onTogglePlayback,
    required this.onReplayCandidate,
    required this.onSetPlaybackRate,
    required this.loopEnabled,
    required this.onToggleLoop,
  });

  final Player? player;
  final bool isOriginalVideo;
  final int? clipStartMs;
  final int? clipEndMs;
  final int? eventTimeMs;
  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function() onReplayCandidate;
  final Future<void> Function(double) onSetPlaybackRate;
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
    if (player == null) {
      return const Padding(
        key: Key('review-video-controls-inset'),
        padding: EdgeInsets.fromLTRB(
          Spacing.md,
          Spacing.xs,
          Spacing.md,
          Spacing.xs,
        ),
        child: SizedBox(height: 32),
      );
    }
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
          final slider = Slider(
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
                    await widget.onSeek(Duration(milliseconds: next.round()));
                  },
          );
          return Padding(
            key: const Key('review-video-controls-inset'),
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.xs,
              Spacing.md,
              Spacing.xs,
            ),
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
                    child: Platform.isWindows
                        ? ExcludeSemantics(child: slider)
                        : slider,
                  ),
                ),
                Row(
                  children: [
                    if (widget.isOriginalVideo) ...[
                      Text(
                        '原视频',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                    ] else if (widget.eventTimeMs != null) ...[
                      Text(
                        '候选 ${_formatMs(widget.eventTimeMs!)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                    ],
                    Text(
                      '${_formatDuration(Duration(milliseconds: positionMs - rangeStart))} / '
                      '${_formatDuration(Duration(milliseconds: rangeEnd - rangeStart))}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    StreamBuilder<double>(
                      stream: player.stream.rate,
                      initialData: player.state.rate,
                      builder: (context, snapshot) {
                        final rate = snapshot.data ?? 1.0;
                        return PopupMenuButton<double>(
                          tooltip: '播放速度：${_playbackRateLabel(rate)}',
                          initialValue: rate,
                          enabled: widget.enabled,
                          onSelected: (next) =>
                              unawaited(widget.onSetPlaybackRate(next)),
                          itemBuilder: (context) => [
                            for (final option in const [1.0, 1.25, 1.5, 2.0])
                              PopupMenuItem<double>(
                                value: option,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 18,
                                      child: (rate - option).abs() < 0.01
                                          ? const Icon(Icons.check, size: 16)
                                          : null,
                                    ),
                                    Text(_playbackRateLabel(option)),
                                  ],
                                ),
                              ),
                          ],
                          padding: EdgeInsets.zero,
                          child: SizedBox(
                            width: 44,
                            height: 34,
                            child: Center(
                              child: Text(
                                _playbackRateLabel(rate),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: widget.enabled
                                      ? c.textSecondary
                                      : c.textTertiary,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
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
                    if (widget.eventTimeMs != null) ...[
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
                        tooltip: widget.loopEnabled
                            ? '关闭循环播放 (L)'
                            : '循环当前片段 (L)',
                        onPressed: widget.enabled ? widget.onToggleLoop : null,
                        icon: Icon(
                          Icons.repeat,
                          size: 18,
                          color: widget.loopEnabled ? c.orange : null,
                        ),
                        constraints: const BoxConstraints.tightFor(
                          width: 34,
                          height: 34,
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
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
    final prediction = _candidateEvidenceValue(candidate, evidence, const [
      ['prediction', 'predict_score'],
      ['predict_score'],
    ]);
    final trajectoryScore = _candidateEvidenceValue(candidate, evidence, const [
      ['trajectory', 'trajectory_score'],
      ['trajectory_score'],
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
    final isCoarse =
        evidence['analysis_source']?.toString() == 'coarse' ||
        candidate['detector_version']?.toString().endsWith(':fast') == true;
    final isManual =
        candidate['detector_version']?.toString() == 'manual-v1' ||
        evidence['source']?.toString() == 'manual';
    final reason = _candidateEvidenceValue(candidate, evidence, const [
      ['review_reason_suggestion', 'primary'],
      ['review_reason'],
    ]);
    final clip =
        '片段 ${_formatMs(_clipStart(candidate))} - ${_formatMs(_clipEnd(candidate))} · '
        '时长 ${_formatClipDuration(_clipEnd(candidate) - _clipStart(candidate))}';

    return Container(
      width: double.infinity,
      height: 46,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: 1,
              ),
              child: Row(
                children: [
                  _EvidenceCell(
                    label: '候选 ${_formatMs(_candidateTime(candidate))}',
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
                    width: 112,
                    color: c.textSecondary,
                  ),
                  _EvidenceCell(
                    label: '候选置信度',
                    value: _candidateConfidence(candidate, evidence) ?? '—',
                    width: 72,
                    color: c.textPrimary,
                    tooltip: '综合轨迹穿框、篮网运动和反弹等信号得出，只用于排序和辅助审核。',
                  ),
                  _EvidenceCell(
                    label: '轨迹评分',
                    value: _formatScore(trajectoryScore),
                    width: 72,
                    color: c.textSecondary,
                  ),
                  _EvidenceCell(
                    label: '预测评分',
                    value: _formatPredictionScore(
                      prediction,
                      isCoarse: isCoarse,
                      isManual: isManual,
                    ),
                    width: 112,
                    color: prediction is num ? c.textSecondary : c.textTertiary,
                    tooltip: _predictionScoreTooltip(
                      prediction,
                      isCoarse: isCoarse,
                      isManual: isManual,
                    ),
                  ),
                  _EvidenceCell(
                    label: '轨迹穿框',
                    value: isCoarse && crossingState == _CrossingDisplay.unknown
                        ? '粗扫通过'
                        : _formatCrossing(crossingState),
                    width: 92,
                    color: isCoarse && crossingState == _CrossingDisplay.unknown
                        ? c.warning
                        : _crossingColor(c, crossingState),
                    tooltip: '判断篮球轨迹是否从篮筐上方进入，并在篮筐横向范围内向下穿过。',
                  ),
                  _EvidenceCell(
                    label: '篮网运动',
                    value: net == null && isCoarse ? '未计算' : _formatSignal(net),
                    width: 82,
                    color: net == null && isCoarse
                        ? c.textTertiary
                        : _signalColor(c, net),
                    tooltip: '检测白色篮网区域在球经过后的运动强度；光线、球员遮挡会影响该信号。',
                  ),
                  _EvidenceCell(
                    label: '反弹判断',
                    value: rebound == null && isCoarse
                        ? '未计算'
                        : _formatRebound(rebound),
                    width: 82,
                    color: rebound == null && isCoarse
                        ? c.textTertiary
                        : _reboundColor(c, rebound),
                    tooltip: '检测篮球撞框后向上或向外回弹；出现反弹通常降低进球可能性。',
                  ),
                  _EvidenceCell(
                    label: '系统说明',
                    value: _reviewReasonLabel(reason),
                    width: 118,
                    color: c.textSecondary,
                    tooltip: '当前候选被纳入审核列表的主要原因。',
                  ),
                ],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(color: c.surface3),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
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
    this.title = '调整片段范围',
    this.description = '拖动时间轴两端即可调整。视频会跳到正在拖动的一端；原视频不会被修改。',
    this.confirmLabel = '应用',
  });

  final String? videoPath;
  final int startMs;
  final int endMs;
  final int durationMs;
  final String title;
  final String description;
  final String confirmLabel;

  @override
  State<_ClipRangeDialog> createState() => _ClipRangeDialogState();
}

class _ClipRangeDialogState extends State<_ClipRangeDialog> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  late int _startMs;
  late int _endMs;
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  int _positionMs = 0;
  bool _ready = false;
  String? _error;
  int? _rangeDragStartMs;
  int? _rangeDragEndMs;

  @override
  void initState() {
    super.initState();
    _startMs = widget.startMs;
    _endMs = widget.endMs;
    _startController = TextEditingController(text: _formatMs(_startMs));
    _endController = TextEditingController(text: _formatMs(_endMs));
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
      _controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !Platform.isWindows,
        ),
      );
      _positionSubscription = player.stream.position.listen((position) {
        if (!mounted) return;
        final next = position.inMilliseconds;
        if ((next - _positionMs).abs() >= 100) {
          setState(() => _positionMs = next);
        }
      });
      await player.open(Media(Uri.file(path).toString()), play: false);
      // 等媒体元数据就绪后再 seek:open 后立即 seek 在加载较慢时
      // (Windows 软件解码)会被丢弃,导致播放从 0 开始而非片段起点。
      await waitForPlayableDuration(
        current: player.state.duration,
        updates: player.stream.duration,
      );
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
    final player = _player;
    _player = null;
    unawaited(() async {
      if (player == null) return;
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }());
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  Future<void> _seek(int position) async {
    final target = position.clamp(0, widget.durationMs).toInt();
    final player = _player;
    if (player == null || !mounted) return;
    setState(() => _positionMs = target);
    try {
      await player.seek(Duration(milliseconds: target));
    } catch (error) {
      if (mounted && identical(player, _player)) {
        setState(() => _error = error.toString());
      }
    }
  }

  void _startRangeDrag(RangeValues value) {
    _rangeDragStartMs = _startMs;
    _rangeDragEndMs = _endMs;
  }

  void _endRangeDrag(RangeValues value) {
    final nextStart = value.start.round();
    final nextEnd = value.end.round();
    final previousStart = _rangeDragStartMs ?? _startMs;
    final previousEnd = _rangeDragEndMs ?? _endMs;
    _rangeDragStartMs = null;
    _rangeDragEndMs = null;
    final startMoved = (nextStart - previousStart).abs();
    final endMoved = (nextEnd - previousEnd).abs();
    unawaited(_seek(startMoved >= endMoved ? nextStart : nextEnd));
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
    _setRange(widget.startMs, widget.endMs);
    unawaited(_seek(_startMs));
  }

  void _setRange(int startMs, int endMs) {
    setState(() {
      _startMs = startMs;
      _endMs = endMs;
      _startController.text = _formatMs(startMs);
      _endController.text = _formatMs(endMs);
    });
  }

  void _submitTimeField({required bool isStart}) {
    final controller = isStart ? _startController : _endController;
    final parsed = _parseTimeMs(controller.text);
    if (parsed == null) {
      controller.text = _formatMs(isStart ? _startMs : _endMs);
      return;
    }
    final value = parsed.clamp(0, widget.durationMs).toInt();
    if (isStart) {
      if (value >= _endMs - 1000) {
        controller.text = _formatMs(_startMs);
        return;
      }
      _setRange(value, _endMs);
      unawaited(_seek(value));
    } else {
      if (value <= _startMs + 1000) {
        controller.text = _formatMs(_endMs);
        return;
      }
      _setRange(_startMs, value);
      unawaited(_seek(value));
    }
  }

  int? _parseTimeMs(String value) {
    final parts = value.trim().split(':');
    if (parts.length == 1) {
      final seconds = int.tryParse(parts.first);
      return seconds == null ? null : seconds * 1000;
    }
    if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]);
      final seconds = int.tryParse(parts[1]);
      if (minutes == null || seconds == null || seconds > 59) return null;
      return (minutes * 60 + seconds) * 1000;
    }
    if (parts.length == 3) {
      final hours = int.tryParse(parts[0]);
      final minutes = int.tryParse(parts[1]);
      final seconds = int.tryParse(parts[2]);
      if (hours == null ||
          minutes == null ||
          seconds == null ||
          minutes > 59 ||
          seconds > 59) {
        return null;
      }
      return (hours * 3600 + minutes * 60 + seconds) * 1000;
    }
    return null;
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
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: c.borderStrong),
      ),
      insetPadding: const EdgeInsets.all(Spacing.lg),
      child: SizedBox(
        width: 860,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                widget.description,
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
                      : GestureDetector(
                          // 与主审核面板一致:点击视频切换播放/暂停。
                          behavior: HitTestBehavior.translucent,
                          onTap: _ready
                              ? () => unawaited(_togglePlayback())
                              : null,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Video(
                              controller: controller,
                              controls: NoVideoControls,
                            ),
                          ),
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
                        _setRange(nextStart, nextEnd);
                      }
                    : null,
                onChangeStart: _ready ? _startRangeDrag : null,
                onChangeEnd: _ready ? _endRangeDrag : null,
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
                children: [
                  Expanded(
                    child: _ClipTimeField(
                      label: '开始',
                      controller: _startController,
                      onSubmitted: () => _submitTimeField(isStart: true),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
                    child: Icon(Icons.arrow_forward, size: 16),
                  ),
                  Expanded(
                    child: _ClipTimeField(
                      label: '结束',
                      controller: _endController,
                      onSubmitted: () => _submitTimeField(isStart: false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _restoreDefault,
                    style: TextButton.styleFrom(
                      foregroundColor: c.textSecondary,
                    ),
                    child: const Text('恢复默认'),
                  ),
                  const SizedBox(width: Spacing.xs),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textPrimary,
                      side: BorderSide(color: c.borderStrong),
                    ),
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
                    style: FilledButton.styleFrom(
                      backgroundColor: c.orange,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: c.surface3,
                      disabledForegroundColor: c.textTertiary,
                    ),
                    child: Text(widget.confirmLabel),
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

class _ClipTimeField extends StatelessWidget {
  const _ClipTimeField({
    required this.label,
    required this.controller,
    required this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return TextField(
      controller: controller,
      onSubmitted: (_) => onSubmitted(),
      textInputAction: TextInputAction.done,
      keyboardType: TextInputType.number,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: c.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: '00:00',
        suffixText: '时:分:秒',
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: 10,
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
    this.tooltip,
  });

  final String label;
  final String value;
  final double width;
  final Color color;
  final String? tooltip;

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
            tooltip == null
                ? Text(
                    label,
                    style: TextStyle(color: c.textTertiary, fontSize: 9),
                  )
                : Tooltip(
                    message: tooltip,
                    child: Text(
                      label,
                      style: TextStyle(color: c.textTertiary, fontSize: 9),
                    ),
                  ),
            const SizedBox(height: 2),
            Builder(
              builder: (context) {
                // 空态(未计算/无数据)用空心圆点+更轻字重标记,
                // 与"有数值但信号弱"的中性灰一眼区分。
                final empty = value == '—' || value == '未计算';
                return Text(
                  empty ? '○ $value' : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: empty ? FontWeight.w400 : FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                );
              },
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
    required this.analysisMode,
    required this.analysisCompleted,
    required this.onSelect,
    required this.candidateRowKeys,
    required this.candidateScrollController,
    required this.onSetPlayer,
    required this.onCreatePlayer,
    required this.players,
    required this.batchMode,
    required this.selectedForBatch,
    required this.onToggleBatch,
    required this.onToggleBatchCandidate,
    required this.onSetPlayerForBatch,
    required this.onCreatePlayerForBatch,
    required this.onDeletePlayer,
    required this.onSetStatus,
    required this.onLoadCover,
    required this.onFilterChanged,
    required this.onReanalyze,
    required this.onRetryHydration,
    required this.onEditRange,
    required this.onEditNote,
    required this.onCreateManualCandidate,
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
  final String analysisMode;
  final bool analysisCompleted;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final Map<String, GlobalKey> candidateRowKeys;
  final ScrollController candidateScrollController;
  final Future<void> Function(Map<String, dynamic>, String?) onSetPlayer;
  final Future<void> Function(Map<String, dynamic>) onCreatePlayer;
  final List<Map<String, dynamic>> players;
  final bool batchMode;
  final Set<String> selectedForBatch;
  final VoidCallback onToggleBatch;
  final ValueChanged<String> onToggleBatchCandidate;
  final ValueChanged<String?> onSetPlayerForBatch;
  final VoidCallback onCreatePlayerForBatch;
  final Future<void> Function(String, String) onDeletePlayer;
  final Future<void> Function(String, String) onSetStatus;
  final Future<String?> Function(String, int)? onLoadCover;
  final ValueChanged<String> onFilterChanged;
  final VoidCallback? onReanalyze;
  final VoidCallback? onRetryHydration;
  final VoidCallback? onEditRange;
  final VoidCallback? onEditNote;
  final VoidCallback? onCreateManualCandidate;
  final VoidCallback onUndo;
  final VoidCallback onGoImport;
  final VoidCallback? onExport;

  void _showBatchPlayerMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _PlayerPickerMenuContent(
        players: players,
        onSelected: (playerId) {
          Navigator.of(context).pop();
          onSetPlayerForBatch(playerId);
        },
        onCreate: () {
          Navigator.of(context).pop();
          onCreatePlayerForBatch();
        },
        onDelete: (playerId, playerName) async {
          Navigator.of(context).pop();
          await onDeletePlayer(playerId, playerName);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Container(
      key: const Key('candidate-panel-inset'),
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.md,
        Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final heading = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '候选片段',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.surface3,
                      borderRadius: BorderRadius.circular(CsRadius.full),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        '已选 $includedCount / $totalCount',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              );
              final actions = Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 0,
                runSpacing: 0,
                children: [
                  if (batchMode && selectedForBatch.isNotEmpty) ...[
                    Text(
                      '批量 ${selectedForBatch.length} 个',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.orange,
                      ),
                    ),
                    IconButton(
                      tooltip: '设置批量球员标签',
                      onPressed: busy
                          ? null
                          : () => _showBatchPlayerMenu(context),
                      icon: const Icon(
                        Icons.person_add_alt_1_outlined,
                        size: 18,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                  IconButton(
                    tooltip: batchMode ? '退出批量选择' : '批量选择候选',
                    onPressed: busy ? null : onToggleBatch,
                    icon: Icon(
                      batchMode
                          ? Icons.close_fullscreen
                          : Icons.checklist_outlined,
                      size: 18,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
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
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: c.surface2,
                        borderRadius: BorderRadius.circular(CsRadius.sm),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _candidateFilterLabel(filter),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: c.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: 15,
                            color: c.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Tooltip(
                    message:
                        '快捷键\nSpace  播放/暂停\nR  重播当前\nL  循环当前\nA  显示/关闭标注\n↑ / ↓  切换候选\n← / →  快退/快进 2 秒\nC / Enter  保留\nX / Backspace  排除\nCmd/Ctrl+Z  撤销',
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
              );
              if (constraints.maxWidth < 430) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading,
                    const SizedBox(height: Spacing.xs),
                    actions,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: heading),
                  actions,
                ],
              );
            },
          ),
          const SizedBox(height: Spacing.xs),
          Expanded(
            child: candidates.isEmpty
                ? _EmptyCandidates(
                    hydrating: hydrating,
                    hydrateError: hydrateError,
                    analyzing: analyzing,
                    hasVideo: hasVideo,
                    analysisMode: analysisMode,
                    analysisCompleted: analysisCompleted,
                    filterEmpty: totalCount > 0,
                    onClearFilter: filter == 'all'
                        ? null
                        : () => onFilterChanged('all'),
                    onReanalyze: onReanalyze,
                    onRetryHydration: onRetryHydration,
                    onGoImport: onGoImport,
                  )
                : ListView.separated(
                    controller: candidateScrollController,
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.xs),
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      final id = candidate['id']?.toString() ?? '';
                      final coverFuture = onLoadCover == null
                          ? null
                          : onLoadCover!(id, _candidateTime(candidate));
                      return _CandidateRow(
                        key: candidateRowKeys.putIfAbsent(id, GlobalKey.new),
                        candidate: candidate,
                        index: index,
                        selected: id == selectedId,
                        batchMode: batchMode,
                        batchSelected: selectedForBatch.contains(id),
                        excluded: _isExcluded(candidate),
                        busy: busy,
                        onTap: () => onSelect(candidate),
                        onSetPlayer: (playerId) =>
                            unawaited(onSetPlayer(candidate, playerId)),
                        onCreatePlayer: () =>
                            unawaited(onCreatePlayer(candidate)),
                        onDeletePlayer: onDeletePlayer,
                        players: players,
                        playerColor: _playerColor(
                          candidate['player_id']?.toString(),
                          _playerIndex(candidate, players),
                        ),
                        onToggleBatch: () => onToggleBatchCandidate(id),
                        onInclude: () => unawaited(onSetStatus(id, 'included')),
                        onExclude: () => unawaited(onSetStatus(id, 'excluded')),
                        coverFuture: coverFuture,
                      );
                    },
                  ),
          ),
          const SizedBox(height: Spacing.xs),
          Padding(
            key: const Key('candidate-actions-inset'),
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: CsButton(
                    label: Text('导出 $includedCount 个片段'),
                    icon: Icons.file_upload_outlined,
                    size: CsButtonSize.sm,
                    onPressed: onExport,
                  ),
                ),
                if (onCreateManualCandidate != null) ...[
                  const SizedBox(width: Spacing.xs),
                  Tooltip(
                    message: '从原视频当前时间补漏候选',
                    child: IconButton(
                      key: const Key('create-manual-candidate'),
                      tooltip: '补漏',
                      onPressed: onCreateManualCandidate,
                      icon: const Icon(Icons.playlist_add_rounded, size: 18),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
                if (hasVideo) ...[
                  const SizedBox(width: Spacing.xs),
                  IconButton(
                    tooltip: '重新配置分析区域和范围',
                    onPressed: busy ? null : onGoImport,
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
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
    required this.analysisMode,
    required this.analysisCompleted,
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
  final String analysisMode;
  final bool analysisCompleted;
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
    final fastEmpty = hasVideo && analysisCompleted && analysisMode == 'fast';
    return CsEmptyState(
      icon: Icons.inbox_outlined,
      title: fastEmpty
          ? '快速分析未找到候选 · 可能漏检'
          : hasVideo
          ? '暂未找到候选片段'
          : '还没有分析结果',
      description: hasVideo
          ? fastEmpty
                ? '快速模式可能漏检，建议用标准模式重新分析。'
                : '重新分析直接使用当前配置；重新配置可以修改分析范围和篮筐区域。'
          : '先导入视频并完成配置，再开始分析。',
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: Spacing.xs,
        children: [
          if (hasVideo)
            CsButton(
              label: Text(fastEmpty ? '用标准模式重新分析' : '重新分析'),
              icon: Icons.replay,
              onPressed: onReanalyze,
            ),
          CsButton(
            label: Text(hasVideo ? '重新配置' : '去导入视频'),
            icon: hasVideo ? Icons.tune : Icons.upload_file,
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
    required this.batchMode,
    required this.batchSelected,
    required this.excluded,
    required this.busy,
    required this.onTap,
    required this.onSetPlayer,
    required this.onCreatePlayer,
    required this.onDeletePlayer,
    required this.players,
    required this.playerColor,
    required this.onToggleBatch,
    required this.onInclude,
    required this.onExclude,
    required this.coverFuture,
    super.key,
  });

  final Map<String, dynamic> candidate;
  final int index;
  final bool selected;
  final bool batchMode;
  final bool batchSelected;
  final bool excluded;
  final bool busy;
  final VoidCallback onTap;
  final ValueChanged<String?> onSetPlayer;
  final VoidCallback onCreatePlayer;
  final Future<void> Function(String, String) onDeletePlayer;
  final List<Map<String, dynamic>> players;
  final Color playerColor;
  final VoidCallback onToggleBatch;
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
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: selected
                ? c.orange.withValues(alpha: 0.09)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(CsRadius.md),
            border: Border.all(
              color: selected
                  ? c.orange.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (batchMode)
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.xs),
                  child: Checkbox(
                    value: batchSelected,
                    onChanged: busy ? null : (_) => onToggleBatch(),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onTap,
                    focusColor: Colors.transparent,
                    hoverColor: Colors.transparent,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _CandidateCover(
                              future: coverFuture,
                              excluded: excluded,
                            ),
                          ),
                          const SizedBox(width: Spacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '#${index + 1} ${_formatMs(_candidateTime(candidate))}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: excluded
                                        ? c.textTertiary
                                        : c.textPrimary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 3),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final duration = Text(
                                      '时长 ${_formatClipDuration(_clipEnd(candidate) - _clipStart(candidate))}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: c.textTertiary,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                    );
                                    final playerChip = _PlayerChip(
                                      key: ValueKey(
                                        'player-chip-${candidate['id']}',
                                      ),
                                      name: candidate['player_name']
                                          ?.toString(),
                                      color: playerColor,
                                      players: players,
                                      onSelected: onSetPlayer,
                                      onCreate: onCreatePlayer,
                                      onDelete: onDeletePlayer,
                                    );
                                    if (constraints.maxWidth < 190) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          duration,
                                          const SizedBox(height: 3),
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: playerChip,
                                          ),
                                        ],
                                      );
                                    }
                                    return Row(
                                      children: [
                                        Expanded(child: duration),
                                        const SizedBox(width: Spacing.xs),
                                        Flexible(
                                          fit: FlexFit.loose,
                                          child: playerChip,
                                        ),
                                      ],
                                    );
                                  },
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
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(CsRadius.md),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DecisionButton(
                      tooltip: '保留片段 (C / Enter)',
                      icon: Icons.check_rounded,
                      active: !excluded,
                      color: c.goal,
                      enabled: !busy,
                      onPressed: onInclude,
                    ),
                    const SizedBox(width: 3),
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
              width: 48,
              height: 44,
              child: Icon(icon, size: 21, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerChip extends StatefulWidget {
  const _PlayerChip({
    required this.name,
    required this.color,
    required this.players,
    required this.onSelected,
    required this.onCreate,
    required this.onDelete,
    super.key,
  });

  final String? name;
  final Color color;
  final List<Map<String, dynamic>> players;
  final ValueChanged<String?> onSelected;
  final VoidCallback onCreate;
  final Future<void> Function(String, String) onDelete;

  @override
  State<_PlayerChip> createState() => _PlayerChipState();
}

class _PlayerChipState extends State<_PlayerChip> {
  final MenuController _menuController = MenuController();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '设置球员标签',
      child: MenuAnchor(
        controller: _menuController,
        alignmentOffset: const Offset(0, 4),
        menuChildren: [
          _PlayerPickerMenuContent(
            players: widget.players,
            onSelected: (playerId) {
              _menuController.close();
              widget.onSelected(playerId);
            },
            onCreate: () {
              _menuController.close();
              widget.onCreate();
            },
            onDelete: (playerId, playerName) async {
              _menuController.close();
              await widget.onDelete(playerId, playerName);
            },
          ),
        ],
        builder: (context, controller, child) => Material(
          color: widget.color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(CsRadius.full),
          child: InkWell(
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            borderRadius: BorderRadius.circular(CsRadius.full),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_outline, size: 14, color: widget.color),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      widget.name == null || widget.name!.isEmpty
                          ? '未标记'
                          : widget.name!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.color,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerPickerMenuContent extends StatelessWidget {
  const _PlayerPickerMenuContent({
    required this.players,
    required this.onSelected,
    required this.onCreate,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> players;
  final ValueChanged<String?> onSelected;
  final VoidCallback onCreate;
  final Future<void> Function(String, String)? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(CsRadius.sm),
      child: SizedBox(
        width: 276,
        height: 330,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                child: Text(
                  '选择球员',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: c.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _PlayerPickerOption(
                label: '未标记',
                icon: Icons.person_off_outlined,
                color: c.textTertiary,
                onTap: () => onSelected(null),
              ),
              Expanded(
                child: players.isNotEmpty
                    ? ListView.builder(
                        primary: false,
                        itemCount: players.length,
                        itemBuilder: (context, index) {
                          final player = players[index];
                          final id = player['id']?.toString();
                          final name = player['name']?.toString() ?? '';
                          return _PlayerPickerOption(
                            label: name,
                            color: _playerColor(id, index),
                            onTap: id == null ? null : () => onSelected(id),
                            trailing: onDelete == null || id == null
                                ? null
                                : IconButton(
                                    tooltip: '删除$name',
                                    onPressed: () => onDelete!(id, name),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 16,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                          );
                        },
                      )
                    : Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            '暂无球员',
                            style: TextStyle(
                              color: c.textTertiary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
              ),
              const Divider(height: 8),
              _PlayerPickerOption(
                label: '新建球员',
                icon: Icons.add,
                color: c.orange,
                onTap: onCreate,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerPickerOption extends StatelessWidget {
  const _PlayerPickerOption({
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
    this.trailing,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CsRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(icon ?? Icons.person_outline, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

Color _playerColor(String? playerId, [int fallbackIndex = -1]) {
  const palette = <Color>[
    Color(0xFFFFB454),
    Color(0xFF7DD3A8),
    Color(0xFF5CC8C0),
    Color(0xFFFF6B8A),
    Color(0xFF4CC9F0),
    Color(0xFFB6A1FF),
  ];
  if (playerId == null || playerId.isEmpty) {
    return const Color(0xFF8B93A7);
  }
  if (fallbackIndex >= 0) {
    return palette[fallbackIndex % palette.length];
  }
  final hash = playerId.codeUnits.fold<int>(
    0,
    (value, unit) => value * 31 + unit,
  );
  return palette[hash.abs() % palette.length];
}

int _playerIndex(
  Map<String, dynamic> candidate,
  List<Map<String, dynamic>> players,
) {
  final playerId = candidate['player_id']?.toString();
  if (playerId == null || playerId.isEmpty) return -1;
  return players.indexWhere((player) => player['id']?.toString() == playerId);
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
            width: 112,
            height: 68,
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

String _formatScore(dynamic value) {
  if (value is num) return '${(value.clamp(0, 1) * 100).round()}%';
  return '—';
}

String _formatPredictionScore(
  dynamic value, {
  required bool isCoarse,
  required bool isManual,
}) {
  if (value is num) return _formatScore(value);
  if (isManual) return '手动片段';
  if (isCoarse) return '快速分析未计算';
  return '轨迹不足';
}

String _predictionScoreTooltip(
  dynamic value, {
  required bool isCoarse,
  required bool isManual,
}) {
  if (value is num) {
    return '预测篮球继续下落后的落点是否接近篮筐中心，不是进球概率。';
  }
  if (isManual) return '补漏片段没有模型预测评分。';
  if (isCoarse) return '快速分析不会拟合完整轨迹；切换到标准分析后才会计算。';
  return '标准分析未获得足够的有效轨迹点，无法可靠预测落点。';
}

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

String? _candidateConfidence(
  Map<String, dynamic> candidate, [
  Map<String, dynamic>? evidence,
]) {
  final raw = candidate['confidence']?.toString().toLowerCase();
  if (raw != null && raw.isNotEmpty && raw != 'pending') {
    return const <String, String>{
          'high': '高',
          'review': '复核',
          'medium': '中',
          'low': '低',
        }[raw] ??
        raw;
  }
  final score =
      candidate['score'] ?? _coarseDetectionConfidence(candidate, evidence);
  if (score is num) return '${(score.clamp(0, 1) * 100).round()}%';
  return null;
}

double? _coarseDetectionConfidence(
  Map<String, dynamic> candidate,
  Map<String, dynamic>? evidence,
) {
  final direct =
      candidate['coarse_detection_confidence'] ??
      evidence?['coarse_detection_confidence'];
  if (direct is num) return direct.toDouble();
  final source = evidence ?? candidate;
  final above = source['above'];
  final below = source['below'];
  final values = [above, below]
      .whereType<Map>()
      .map((point) => point['confidence'])
      .whereType<num>()
      .map((value) => value.toDouble())
      .toList();
  if (values.isEmpty) return null;
  return values.reduce((left, right) => left + right) / values.length;
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

String _playbackRateLabel(double rate) {
  final text = rate == rate.roundToDouble()
      ? rate.toStringAsFixed(0)
      : rate.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  return '$text×';
}

String? _resolveOriginalVideoPath(ProjectState state) {
  final path = state.video?['source_path']?.toString();
  if (path == null || path.isEmpty) return null;
  return path;
}

/// Returns the seek/playback bounds for the review timeline.
///
/// The review player always opens the original video. A candidate only changes
/// the initial seek position; it must not shorten the original video's
/// timeline or make playback stop at the candidate end.
ReviewTimelineBounds reviewTimelineBounds({
  required bool isOriginalVideo,
  Map<String, dynamic>? candidate,
}) {
  if (isOriginalVideo || candidate == null || candidate.isEmpty) {
    return const ReviewTimelineBounds(startMs: 0, endMs: null);
  }
  return ReviewTimelineBounds(
    startMs: _clipStart(candidate),
    endMs: _clipEnd(candidate),
  );
}

class ReviewTimelineBounds {
  const ReviewTimelineBounds({required this.startMs, required this.endMs});

  final int startMs;
  final int? endMs;
}

Map<String, dynamic> _decodeJobCheckpoint(Map<String, dynamic>? job) {
  if (job == null) return const <String, dynamic>{};
  final checkpoint = job['checkpoint'];
  if (checkpoint is Map) return checkpoint.cast<String, dynamic>();
  final raw = job['checkpoint_json'];
  if (raw is! String || raw.isEmpty) return const <String, dynamic>{};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : const <String, dynamic>{};
  } on FormatException {
    return const <String, dynamic>{};
  }
}

String _analysisDetailLabel(Map<String, dynamic> checkpoint) {
  final rawTimings = checkpoint['stage_timings_ms'];
  final timings = rawTimings is Map
      ? rawTimings.cast<String, dynamic>()
      : const <String, dynamic>{};
  final parts = <String>[];
  for (final entry in const <String, String>{
    'prepare_proxy': '代理',
    'coarse_scan': '粗扫',
    'generate_candidates': '候选',
    'refine_candidates': '精筛',
    'prepare_review_previews': '封面',
    'persist_candidates': '落库',
  }.entries) {
    final value = timings[entry.key];
    if (value is num) {
      parts.add('${entry.value} ${_formatSeconds(value / 1000)}');
    }
  }
  final cacheHits = checkpoint['cache_hits'];
  if (cacheHits is num) parts.add('缓存命中 ${cacheHits.toInt()}');
  return parts.isEmpty ? '' : '分析详情：${parts.join(' · ')}';
}

String _formatSeconds(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? '${rounded.round()} 秒'
      : '$rounded 秒';
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

String _formatCompletedDuration(String? startedAt, String? finishedAt) {
  if (startedAt == null || finishedAt == null) return '';
  final started = DateTime.tryParse(startedAt);
  final finished = DateTime.tryParse(finishedAt);
  if (started == null || finished == null) return '';
  final duration = finished.toUtc().difference(started.toUtc());
  return _formatDuration(duration.isNegative ? Duration.zero : duration);
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
