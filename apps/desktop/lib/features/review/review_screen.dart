import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import '../feedback/feedback_dialog.dart';
import '../../components/cs_button.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_progress_track.dart';
import 'candidate_status_labels.dart';
import '../../core/video_orientation.dart';
import '../../providers/player_groups_provider.dart';
import '../../providers/project_state.dart';
import '../../providers/playback_coordinator.dart';
import '../../core/project_session.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';
import 'clip_range_timeline.dart';
import 'media_readiness.dart';
import 'player_group_editor.dart';
import 'review_video_viewport.dart';
import 'shooter_quick_label.dart';
import 'review_module_tabs.dart';
import 'review_text_entry_dialog.dart';

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
  bool _showShooter = false, _switchingModule = false, _shooterSaving = false;
  ProjectSessionScope? _shooterScope;
  int _shooterReloadToken = 0;
  String? _selectedCandidateId;
  bool _showOriginalVideo = false;
  final Set<String> _reviewStartedCandidateIds = <String>{};
  String _candidateFilter = 'all';
  String _playerFilter = 'all';
  String _rimFilter = 'all';
  String _segmentFilter = 'all';
  final _VideoPaneController _videoController = _VideoPaneController();
  int _videoSourceSwitchToken = 0;
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'review-shortcut-focus',
  );
  final Map<String, Future<String?>> _coverCache = <String, Future<String?>>{};
  final Map<String, BuildContext> _candidateRowContexts =
      <String, BuildContext>{};
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
    ordered.sort((left, right) {
      final bySegment = _candidateSegment(
        left,
      ).compareTo(_candidateSegment(right));
      return bySegment != 0
          ? bySegment
          : _candidateTime(left).compareTo(_candidateTime(right));
    });
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

  Future<void> _switchReviewModule(bool shooter, {String? candidateId}) async {
    if (_switchingModule ||
        _shooterSaving ||
        (_showShooter == shooter && candidateId == null)) {
      return;
    }
    final session = ref.read(projectSessionProvider);
    setState(() => _switchingModule = true);
    try {
      final scope = session.snapshot();
      await ref.read(projectProvider.notifier).flushReviewQueue();
      if (shooter) {
        await ref
            .read(playbackCoordinatorProvider)
            .withPausedPlayback(() async {});
      } else {
        await ref
            .read(projectProvider.notifier)
            .refreshCandidates(scope: scope);
      }
      if (!mounted || session.projectRoot != scope.projectRoot) return;
      setState(() {
        _shooterScope ??= scope;
        _showShooter = shooter;
        if (shooter) _shooterReloadToken++;
      });
      if (candidateId == null) return;
      final candidate = ref
          .read(projectProvider)
          .candidates
          .where((row) => row['id'] == candidateId)
          .firstOrNull;
      if (candidate != null) _selectCandidate(candidate);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _switchingModule = false);
    }
  }

  void _toggleVideoSource() {
    // 能否切换只看实际会播放的源。导入页静帧(previewPath)不参与审核播放，
    // 多段项目导入后它已经被清空，不能用它判断可切换状态。
    final playbackPath = _reviewPlaybackPath(ref.read(projectProvider));
    if (playbackPath == null || playbackPath.isEmpty) return;
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
    final before = _filterCandidates(
      _orderedCandidates(ref.read(projectProvider).candidates),
      _candidateFilter,
      playerFilter: _playerFilter,
      rimFilter: _rimFilter,
      segmentFilter: _segmentFilter,
    );
    await notifier.setCandidatePlayer(candidate['id'].toString(), playerId);
    _keepSelectionVisibleAfterEdit(candidate['id'].toString(), before);
  }

  Future<String?> _promptPlayerName() => promptReviewPlayerName(context);

  Future<void> _createPlayerForCandidate(
    Map<String, dynamic> candidate,
    ProjectNotifier notifier,
  ) async {
    final name = await _promptPlayerName();
    if (!mounted || name == null) return;
    final before = _filterCandidates(
      _orderedCandidates(ref.read(projectProvider).candidates),
      _candidateFilter,
      playerFilter: _playerFilter,
      rimFilter: _rimFilter,
      segmentFilter: _segmentFilter,
    );
    await notifier.createPlayer(
      name,
      candidateIds: [candidate['id'].toString()],
    );
    _keepSelectionVisibleAfterEdit(candidate['id'].toString(), before);
  }

  void _changeFilters({
    String? status,
    String? player,
    String? rim,
    String? segment,
  }) {
    setState(() {
      _candidateFilter = status ?? _candidateFilter;
      _playerFilter = player ?? _playerFilter;
      _rimFilter = rim ?? _rimFilter;
      _segmentFilter = segment ?? _segmentFilter;
      final candidates = _filterCandidates(
        _orderedCandidates(ref.read(projectProvider).candidates),
        _candidateFilter,
        playerFilter: _playerFilter,
        rimFilter: _rimFilter,
        segmentFilter: _segmentFilter,
      );
      _selectedCandidateId = _selectedCandidate(candidates)?['id']?.toString();
    });
    final id = _selectedCandidateId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureCandidateVisible(id);
      });
    }
  }

  Future<void> _showBatchRangeDialog(
    BuildContext context,
    ProjectNotifier notifier,
    List<Map<String, dynamic>> candidates,
  ) async {
    if (candidates.isEmpty) return;
    final beforeController = TextEditingController(text: '3');
    final afterController = TextEditingController(text: '1');
    var overwriteManual = false;
    final result = await showDialog<({int before, int after, bool overwrite})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.bheText('批量设置片段时长')),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.bheText('进球前后时间会以每个候选的进球时刻为中心计算。')),
                const SizedBox(height: 16),
                Text(
                  Localizations.of<BheLocalizations>(
                        context,
                        BheLocalizations,
                      )?.reviewBatchRangeScope(candidates.length) ??
                      '应用范围：当前列表的 ${candidates.length} 个候选（随状态和球员标签筛选变化）',
                  key: const Key('batch-range-scope'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(width: 72, child: Text(context.bheText('进球前'))),
                    Expanded(
                      child: TextField(
                        controller: beforeController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          suffixText: context.bheText('秒'),
                        ),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    SizedBox(width: 72, child: Text(context.bheText('进球后'))),
                    Expanded(
                      child: TextField(
                        controller: afterController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          suffixText: context.bheText('秒'),
                        ),
                      ),
                    ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: overwriteManual,
                  onChanged: (value) =>
                      setDialogState(() => overwriteManual = value ?? false),
                  title: Text(context.bheText('覆盖手动调整过的片段')),
                  subtitle: Text(context.bheText('关闭时自动保留手动调整的范围')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.bheText('取消')),
            ),
            FilledButton(
              onPressed: () {
                final before = int.tryParse(beforeController.text.trim());
                final after = int.tryParse(afterController.text.trim());
                if (before == null ||
                    after == null ||
                    before < 0 ||
                    after < 0 ||
                    before + after == 0) {
                  return;
                }
                Navigator.pop(dialogContext, (
                  before: before,
                  after: after,
                  overwrite: overwriteManual,
                ));
              },
              child: Text(context.bheText('应用到 ${candidates.length} 个片段')),
            ),
          ],
        ),
      ),
    );
    beforeController.dispose();
    afterController.dispose();
    if (result == null || !mounted) return;
    final ids = candidates
        .map((candidate) => candidate['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    await notifier.updateClipRanges(
      candidateIds: ids,
      beforeMs: result.before * 1000,
      afterMs: result.after * 1000,
      overwriteManual: result.overwrite,
    );
  }

  Future<void> _deletePlayer(String playerId, String playerName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.bheText('删除球员？')),
        content: Text(context.bheText('删除“$playerName”后，已标记的候选会变为未标记。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.bheText('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.bheText('删除')),
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
    final keyboard = HardwareKeyboard.instance;
    final commandPressed = keyboard.isControlPressed || keyboard.isMetaPressed;
    // System combos such as Cmd+C must not trigger single-key review actions.
    if ((commandPressed || keyboard.isAltPressed) &&
        !(commandPressed && key == LogicalKeyboardKey.keyZ)) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveCandidate(candidates, -1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveCandidate(candidates, 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBySeconds(keyboard.isShiftPressed ? -0.1 : -2);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBySeconds(keyboard.isShiftPressed ? 0.1 : 2);
    } else if (key == LogicalKeyboardKey.space) {
      _togglePlayback();
    } else if (key == LogicalKeyboardKey.keyA) {
      _videoController.toggleAnnotations();
    } else if (key == LogicalKeyboardKey.keyL) {
      _toggleCandidateLoop();
    } else if (key == LogicalKeyboardKey.keyZ && commandPressed) {
      if (!reviewLocked) unawaited(notifier.undoReview());
    } else if (key == LogicalKeyboardKey.keyX ||
        key == LogicalKeyboardKey.backquote ||
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
    } else if (_playerShortcutIndex(key) case final int index) {
      // 0 clears the tag; the other keys follow the player order shown in the tag menu.
      final players = ref.read(projectProvider).players;
      if (index > players.length) return KeyEventResult.ignored;
      if (!reviewLocked && selected != null) {
        final playerId = index == 0
            ? null
            : players[index - 1]['id']?.toString();
        unawaited(_setPlayerForCandidate(selected, notifier, playerId));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static const List<(LogicalKeyboardKey, LogicalKeyboardKey)> _playerKeys = [
    (LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0),
    (LogicalKeyboardKey.digit1, LogicalKeyboardKey.numpad1),
    (LogicalKeyboardKey.digit2, LogicalKeyboardKey.numpad2),
    (LogicalKeyboardKey.digit3, LogicalKeyboardKey.numpad3),
    (LogicalKeyboardKey.digit4, LogicalKeyboardKey.numpad4),
    (LogicalKeyboardKey.digit5, LogicalKeyboardKey.numpad5),
    (LogicalKeyboardKey.digit6, LogicalKeyboardKey.numpad6),
    (LogicalKeyboardKey.digit7, LogicalKeyboardKey.numpad7),
    (LogicalKeyboardKey.digit8, LogicalKeyboardKey.numpad8),
    (LogicalKeyboardKey.digit9, LogicalKeyboardKey.numpad9),
    // 第 10 个以后用 Q 到 P 这一排字母。
    (LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyQ),
    (LogicalKeyboardKey.keyW, LogicalKeyboardKey.keyW),
    (LogicalKeyboardKey.keyE, LogicalKeyboardKey.keyE),
    (LogicalKeyboardKey.keyR, LogicalKeyboardKey.keyR),
    (LogicalKeyboardKey.keyT, LogicalKeyboardKey.keyT),
    (LogicalKeyboardKey.keyY, LogicalKeyboardKey.keyY),
    (LogicalKeyboardKey.keyU, LogicalKeyboardKey.keyU),
    (LogicalKeyboardKey.keyI, LogicalKeyboardKey.keyI),
    (LogicalKeyboardKey.keyO, LogicalKeyboardKey.keyO),
    (LogicalKeyboardKey.keyP, LogicalKeyboardKey.keyP),
  ];

  int? _playerShortcutIndex(LogicalKeyboardKey key) {
    final index = _playerKeys.indexWhere(
      (pair) => pair.$1 == key || pair.$2 == key,
    );
    return index < 0 ? null : index;
  }

  Future<({int startMs, int endMs})?> _showRangeDialog(
    WidgetBuilder builder,
  ) async {
    try {
      return await ref.read(playbackCoordinatorProvider).withPausedPlayback(() {
        if (!mounted) return Future<({int startMs, int endMs})?>.value();
        return showDialog<({int startMs, int endMs})>(
          context: context,
          builder: builder,
        );
      });
    } catch (error) {
      if (mounted) {
        final l10n = Localizations.of<BheLocalizations>(
          context,
          BheLocalizations,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n?.reviewRangeOpenFailed(error.toString()) ??
                  '无法暂停预览并打开范围编辑：$error',
            ),
          ),
        );
      }
      return null;
    }
  }

  Future<void> _editClipRange(Map<String, dynamic> candidate) async {
    final clipEnd = _clipEnd(candidate);
    final videoDurationMs = _number(
      ref.read(projectProvider).video?['duration_ms'],
    ).round();
    // Missing duration metadata must not leave the dialog without a valid axis.
    final durationMs = videoDurationMs >= 1000
        ? videoDurationMs
        : clipEnd > 1000
        ? clipEnd
        : 1000;
    final result = await _showRangeDialog(
      (dialogContext) => _ClipRangeDialog(
        videoPath: ref.read(projectProvider).videoPath,
        frameSize: _videoFrameSize(ref.read(projectProvider).video),
        rotation: _videoRotation(ref.read(projectProvider).video),
        startMs: _clipStart(candidate),
        endMs: clipEnd,
        defaultStartMs: candidate['default_start_ms'] == null
            ? null
            : _number(candidate['default_start_ms']).round(),
        defaultEndMs: candidate['default_end_ms'] == null
            ? null
            : _number(candidate['default_end_ms']).round(),
        durationMs: durationMs,
        title: context.bheText('调整片段范围'),
        eventMs: candidate['event_time_ms'] == null
            ? null
            : _candidateTime(candidate),
        confirmLabel: context.bheText('应用'),
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
    if (durationMs < 1000) return;
    final positionMs = _videoController.currentPositionMs.clamp(0, durationMs);
    final startMs = (positionMs - 4000).clamp(0, durationMs - 1000).toInt();
    final endMs = (positionMs + 5000).clamp(startMs + 1000, durationMs).toInt();
    final result = await _showRangeDialog(
      (dialogContext) => _ClipRangeDialog(
        videoPath: state.videoPath,
        frameSize: _videoFrameSize(state.video),
        rotation: _videoRotation(state.video),
        startMs: startMs,
        endMs: endMs,
        durationMs: durationMs,
        title: context.bheText('补漏片段'),
        eventMs: positionMs.toInt(),
        description:
            Localizations.of<BheLocalizations>(
              context,
              BheLocalizations,
            )?.rangeManualHint ??
            '已定位到原视频当前时间。用 I / O 设定开始和结束后加入候选。',
        confirmLabel: context.bheText('加入候选'),
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
      builder: (_) => ReviewTextEntryDialog(
        title: context.bheText('候选备注'),
        initialText: candidate['note']?.toString() ?? '',
        hintText: context.bheText('例如：补篮、擦框、镜头遮挡'),
        maxLines: 4,
        confirmLabel: context.bheText('保存'),
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
      playerFilter: _playerFilter,
      rimFilter: _rimFilter,
      segmentFilter: _segmentFilter,
    );
    final future = ref
        .read(projectProvider.notifier)
        .reviewCandidate(id, status, showNotice: false);
    _keepSelectionVisibleAfterEdit(id, before);
    await future;
  }

  void _keepSelectionVisibleAfterEdit(
    String id,
    List<Map<String, dynamic>> before,
  ) {
    if (!mounted) return;
    final previousIndex = before.indexWhere(
      (candidate) => candidate['id']?.toString() == id,
    );
    final after = _filterCandidates(
      _orderedCandidates(ref.read(projectProvider).candidates),
      _candidateFilter,
      playerFilter: _playerFilter,
      rimFilter: _rimFilter,
      segmentFilter: _segmentFilter,
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
  }

  Future<void> _confirmReanalyze() async {
    await _confirmReanalyzeWithMode();
  }

  Future<void> _confirmReanalyzeWithMode({bool forceStandard = false}) async {
    final targetMode = forceStandard ? 'standard' : null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.bheText('重新分析当前视频？')),
        content: Text(
          context.bheText(
            forceStandard
                ? context.bheText(
                    '快速分析可能漏检，建议改用标准模式重新分析。当前候选会在新结果成功后替换，原始视频不会被删除。',
                  )
                : context.bheText('重新分析会替换当前候选列表，但不会删除原始视频。'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.bheText('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.bheText(forceStandard ? '用标准模式重新分析' : '重新分析')),
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
    if (_shooterScope != null &&
        _shooterScope!.projectRoot !=
            ref.read(projectSessionProvider).projectRoot) {
      _shooterScope = null;
      _showShooter = false;
      _shooterSaving = false;
    }
    _syncPreviewScope(state);
    final allCandidates = _orderedCandidates(state.candidates);
    if (_playerFilter.startsWith('player:') &&
        !state.players.any(
          (player) => 'player:${player['id']}' == _playerFilter,
        )) {
      _playerFilter = 'all';
    }
    final statusCandidates = _filterCandidates(allCandidates, _candidateFilter);
    final candidates = _filterCandidates(
      statusCandidates,
      'all',
      playerFilter: _playerFilter,
      rimFilter: _rimFilter,
      segmentFilter: _segmentFilter,
    );
    final selected = _selectedCandidate(candidates);
    final selectedId = selected?['id']?.toString();
    final selectedVideoId = selected?['video_id']?.toString();
    if (state.multiVideo &&
        selectedVideoId != null &&
        selectedVideoId != state.video?['id']?.toString()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.activateVideo(selectedVideoId);
      });
    }
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
    final reviewVideoPath = _reviewPlaybackPath(state);
    final showingOriginalVideo =
        _showOriginalVideo ||
        reviewVideoPath == null ||
        reviewVideoPath.isEmpty;
    final playbackPath = showingOriginalVideo
        ? originalVideoPath
        : reviewVideoPath;
    final reviewLocked = state.busy || state.hydrating;
    if (!_showShooter &&
        !reviewLocked &&
        selectedId != null &&
        selectedId.isNotEmpty) {
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

    final basketReview = Builder(
      builder: (context) {
        return Column(
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
                    rotation: _videoRotation(state.video),
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
                      if (!reviewLocked) {unawaited(notifier.undoReview());
                    }},
                    excluded: selected != null && _isExcluded(selected),
                    reviewLocked: reviewLocked,
                    players: state.players,
                    playerColor: selected == null
                        ? AppColors.of(context).textTertiary
                        : _playerColor(
                            AppColors.of(context),
                            selected['player_id']?.toString(),
                            _playerIndex(selected, state.players),
                          ),
                    onInclude: () {
                      final id = selectedId;
                      if (id != null) {unawaited(_setCandidateStatus(id, 'included'),);
                    }},
                    onExclude: () {
                      final id = selectedId;
                      if (id != null) {unawaited(_setCandidateStatus(id, 'excluded'),);
                    }},
                    onSetPlayer: (playerId) {
                      if (selected != null) {
                        unawaited(
                          _setPlayerForCandidate(selected, notifier, playerId,),
                        );
                      }
                    },
                    onCreatePlayer: () {
                      if (selected != null) {
                        unawaited(_createPlayerForCandidate(selected, notifier,),);
                      }
                    },
                    onDeletePlayer: _deletePlayer,
                  );
                  final queueWidth = (constraints.maxWidth * 0.30)
                      .clamp(360.0, 460.0)
                      .toDouble();
                  final queue = _CandidatePanel(
                    candidates: candidates,
                    overlappingIds: _overlappingCandidateIds(allCandidates,),
                    selectedId: selected?['id']?.toString(),
                    includedCount: includedCount,
                    reviewedCount: allCandidates.where(_isReviewed).length,
                    totalCount: allCandidates.length,
                    filter: _candidateFilter,
                    playerFilter: _playerFilter,
                    rimFilter: _rimFilter,
                    segmentFilter: _segmentFilter,
                    statusCandidates: statusCandidates,
                    busy: reviewLocked,
                    busyMessage: state.busyMessage,
                    hydrating: state.hydrating,
                    hydrateError: state.hydrateError,
                    analyzing: analyzing,
                    hasVideo: state.videoPath != null || state.video != null,
                    analysisMode: state.analysisMode,
                    analysisCompleted: jobState == 'completed',
                    onSelect: _selectCandidate,
                    candidateRowContexts: _candidateRowContexts,
                    candidateScrollController: _candidateScrollController,
                    onSetPlayer: (candidate, playerId) =>
                        _setPlayerForCandidate(candidate, notifier, playerId,),
                    onCreatePlayer: (candidate) =>
                        _createPlayerForCandidate(candidate, notifier,),
                    players: state.players,
                    onDeletePlayer: _deletePlayer,
                    onBatchRange: () =>
                        _showBatchRangeDialog(context, notifier, candidates,),
                    onSetStatus: (id, status) =>
                        _setCandidateStatus(id, status),
                    onLoadCover: state.video == null
                        ? null
                        : (id, timeMs) =>
                              _loadCandidateCover(notifier, id, timeMs,),
                    onFilterChanged: (value) => _changeFilters(status: value),
                    onPlayerFilterChanged: (value) =>
                        _changeFilters(player: value),
                    onRimFilterChanged: (value) => _changeFilters(rim: value),
                    segments: [
                      if (state.multiVideo)
                        for (final (index, video) in state.videos.indexed)
                          (video['id'].toString(), index + 1),
                    ],
                    onSegmentFilterChanged: (value) =>
                        _changeFilters(segment: value),
                    onClearFilters: () => _changeFilters(
                      status: 'all',
                      player: 'all',
                      rim: 'all',
                      segment: 'all',
                    ),
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
                      if (!reviewLocked) {unawaited(notifier.undoReview());
                    }},
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
                          SizedBox(width: queueWidth, child: queue,),
                        ],
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: Spacing.lg,),
                    child: Column(
                      children: [
                        SizedBox(
                          // The transport and the current-clip card stack
                          // under the frame on narrow screens.
                          height:
                              (constraints.maxWidth * 0.5625)
                                  .clamp(240.0, 520.0)
                                  .toDouble() +
                              420,
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
        );
      },
    );
    return Focus(
      key: const Key('review-shortcut-focus'),
      focusNode: _shortcutFocusNode,
      autofocus: true,
      onKeyEvent: (_, event) => _showShooter
          ? KeyEventResult.ignored
          : _handleShortcut(
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
            ReviewModuleTabs(
              shooterSelected: _showShooter,
              enabled: !reviewLocked && !_switchingModule && !_shooterSaving,
              onSelected: (shooter) => unawaited(_switchReviewModule(shooter)),
            ),
            Expanded(
              child: IndexedStack(
                index: _showShooter ? 1 : 0,
                children: [
                  TickerMode(
                    enabled: !_showShooter,
                    child: ExcludeFocus(
                      excluding: _showShooter,
                      child: basketReview,
                    ),
                  ),
                  if (_shooterScope case final scope?)
                    ShooterQuickLabel(
                      key: ValueKey('shooter-module-${scope.projectRoot}'),
                      initialVideoId: scope.videoId,
                      embedded: true,
                      active: _showShooter,
                      reloadToken: _shooterReloadToken,
                      onSavingChanged: (saving) {
                        if (mounted) setState(() => _shooterSaving = saving);
                      },
                      onWatchClip: (id) => unawaited(
                        _switchReviewModule(false, candidateId: id),
                      ),
                      request: (command, payload) =>
                          scope.engine.client.request(command, {
                            'project_root': scope.projectRoot,
                            ...payload,
                          }),
                    ),
                ],
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
    final targetContext = _candidateRowContexts[id];
    if (targetContext != null && targetContext.mounted) {
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
      playerFilter: _playerFilter,
      rimFilter: _rimFilter,
      segmentFilter: _segmentFilter,
    );
    final index = candidates.indexWhere(
      (candidate) => candidate['id']?.toString() == id,
    );
    if (index < 0) return;
    final position = _candidateScrollController.position;
    unawaited(
      _candidateScrollController.animateTo(
        (index * 80.0).clamp(0.0, position.maxScrollExtent),
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
    // 多段项目里选中候选会切换当前段，不能因此清空审核状态。
    final key = state.multiVideo
        ? ([
            for (final video in state.videos) video['id'].toString(),
          ]..sort()).join('|')
        : '${state.video?['id'] ?? ''}|${state.videoPath ?? ''}';
    if (_previewScopeKey == key) return;
    _previewScopeKey = key;
    _previewGeneration++;
    _coverCache.clear();
    _reviewStartedCandidateIds.clear();
    _selectedCandidateId = null;
    _candidateFilter = 'all';
    _playerFilter = 'all';
    _rimFilter = 'all';
    _segmentFilter = 'all';
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
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
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
        ? (l10n?.text('分析失败') ?? '分析失败')
        : interrupted
        ? (l10n?.text('上次分析没有完成') ?? '上次分析没有完成')
        : (l10n?.analysisInProgress ?? '正在分析视频');
    final detail = failed
        ? (l10n?.text(errorMessage ?? '请检查视频后重试') ??
              (errorMessage ?? '请检查视频后重试'))
        : interrupted
        ? (l10n?.text('已有候选可以继续使用，也可以重新分析') ?? '已有候选可以继续使用，也可以重新分析')
        : '${l10n?.text(_stageLabel(stage)) ?? _stageLabel(stage)} · ${(value * 100).round()}%';
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
                          l10n?.text('分析进行中') ?? '分析进行中',
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
                              ? '${l10n?.text('已用') ?? '已用'} $elapsed'
                              : '${l10n?.text('已用') ?? '已用'} $elapsed · ${l10n?.text('剩余约') ?? '剩余约'} $remaining',
                          style: TextStyle(
                            fontSize: 11,
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
              label: l10n?.cancel ?? '取消',
              icon: Icons.stop_circle_outlined,
              onPressed: onCancel!,
            ),
          if (failed)
            _SmallAction(
              label: l10n?.text('反馈问题') ?? '反馈问题',
              icon: Icons.feedback_outlined,
              onPressed: () =>
                  showFeedbackDialog(context, error: errorMessage),
            ),
          if (onRetry != null && !attached)
            _SmallAction(
              label: l10n?.text('重试分析') ?? '重试分析',
              icon: Icons.refresh,
              onPressed: onRetry!,
            ),
          if (onReanalyze != null)
            _SmallAction(
              label: l10n?.redoAnalysis ?? '重新分析',
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
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final duration = _formatCompletedDuration(startedAt, finishedAt);
    final modeLabel = mode == 'fast' ? '快速分析 · 可能漏检' : '标准分析';
    final detail = _analysisDetailLabel(checkpoint, l10n);
    final status = context.bheText(
      '$modeLabel · $candidateCount 个候选${duration.isEmpty ? '' : ' · 用时 $duration'}',
    );
    // GPU 标记拼在 bheText 外面：整串翻译依赖固定文案，后缀不能进正则。
    final badge = _inferenceAccelerated(checkpoint) ? ' · GPU' : '';
    return Container(
      width: double.infinity,
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 14, color: c.goal),
          const SizedBox(width: Spacing.xs),
          Flexible(
            child: Text(
              '$status$badge',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
            ),
          ),
          if (detail.isNotEmpty)
            Tooltip(
              message: detail,
              child: Semantics(
                label: l10n?.reviewAnalysisDetails ?? '分析详情',
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.info_outline,
                    size: 14,
                    color: c.textTertiary,
                  ),
                ),
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

class _VideoPane extends ConsumerStatefulWidget {
  const _VideoPane({
    required this.controller,
    required this.videoPath,
    required this.candidate,
    required this.isOriginalVideo,
    required this.sourceSwitchToken,
    required this.replayToken,
    required this.frameSize,
    this.rotation = 0,
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
    required this.excluded,
    required this.reviewLocked,
    required this.players,
    required this.playerColor,
    required this.onInclude,
    required this.onExclude,
    required this.onSetPlayer,
    required this.onCreatePlayer,
    required this.onDeletePlayer,
  });

  final _VideoPaneController controller;
  final String? videoPath;
  final Map<String, dynamic>? candidate;
  final bool isOriginalVideo;
  final int sourceSwitchToken;
  final int replayToken;
  final Size frameSize;
  final int rotation;
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
  final bool excluded;
  final bool reviewLocked;
  final List<Map<String, dynamic>> players;
  final Color playerColor;
  final VoidCallback onInclude;
  final VoidCallback onExclude;
  final ValueChanged<String?> onSetPlayer;
  final VoidCallback onCreatePlayer;
  final Future<void> Function(String, String) onDeletePlayer;

  @override
  ConsumerState<_VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends ConsumerState<_VideoPane> {
  late final _playback = ref.read(playbackCoordinatorProvider);
  bool _routeActive = true;
  bool get _mayPlay => _routeActive && !_playback.dialogActive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (_routeActive && !active) {
      unawaited(
        _pauseForDialog().catchError((Object error) {
          if (mounted) setState(() => _error = error.toString());
        }),
      );
    }
    _routeActive = active;
  }

  Future<void> _pauseForDialog() async {
    _playbackToken++;
    await _mediaQueue;
    await _player?.pause();
  }

  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  String? _error;
  bool _ready = false;
  bool _loading = false;
  bool _showAnnotations = false;
  bool _loopCandidate = true;
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
    _playback.register(this, _pauseForDialog);
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
            enableHardwareAcceleration: !useSoftwareVideo(),
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
    final player = _player!;
    // A modal pause can be undone by a late native resume; keep the background
    // preview silent while another player owns the screen.
    _playingSubscription = player.stream.playing.listen((playing) {
      if (playing && !_disposed && !_mayPlay && identical(player, _player)) {
        unawaited(player.pause());
      }
    });
    _positionSubscription = _player!.stream.position.listen((position) {
      if (_disposed || !mounted || !_mayPlay) return;
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
    _playback.unregister(this);
    _disposed = true;
    _mediaGeneration++;
    _playbackToken++;
    _annotationHintTimer?.cancel();
    final subscription = _positionSubscription;
    _positionSubscription = null;
    unawaited(_playingSubscription?.cancel());
    _playingSubscription = null;
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
      if (path != null && path.isNotEmpty && !File(path).existsSync()) {
        setState(() {
          _ready = false;
          _loading = false;
          _error = '源视频找不到，请到导入页重新定位视频';
        });
        return;
      }
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
      await matchPlayerToSourceRotation(player, rotation: widget.rotation);
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
      if (_mayPlay && (reviewVideoAutoPlayAfterOpen || playAfterOpen)) {
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
        !_mayPlay ||
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
    if (!_mayPlay) return;
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
      action: (player) async {
        await player.setRate(rate);
        // 从高倍速切回来时画面会落后于声音，原地 seek 一次让音画重新对齐。
        await player.seek(player.state.position);
      },
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
                        title: !hasVideo
                            ? context.bheText('还没有视频')
                            : context.bheText(_error ?? '视频加载失败'),
                        description: _error == null && hasVideo
                            ? context.bheText('分析完成后会在这里预览候选片段，点击播放开始')
                            : null,
                        action: _error != null && hasVideo
                            ? CsButton(
                                label: Text(context.bheText('重新加载视频')),
                                icon: Icons.refresh,
                                onPressed: _reloadVideo,
                              )
                            : null,
                      )
                    else
                      ReviewVideoViewport(
                        frameSize: widget.frameSize,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            IgnorePointer(
                              // 带 rotation 的原视频在 Windows 上要自己转正。
                              child: OrientedVideo(
                                controller: controller,
                                rotation: playerAppliesRotation()
                                    ? 0
                                    : widget.rotation,
                                fit: BoxFit.cover,
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
                    if (widget.candidate != null && _showAnnotationHint)
                      const Positioned(
                        top: Spacing.sm,
                        right: Spacing.sm,
                        child: _AnnotationHint(),
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
            annotationsEnabled: _showAnnotations,
            onToggleAnnotations: widget.candidate == null
                ? null
                : _setAnnotations,
          ),
          if (widget.candidate != null)
            _CandidateInspector(
              candidate: widget.candidate!,
              excluded: widget.excluded,
              busy: widget.reviewLocked,
              players: widget.players,
              playerColor: widget.playerColor,
              onInclude: widget.onInclude,
              onExclude: widget.onExclude,
              onSetPlayer: widget.onSetPlayer,
              onCreatePlayer: widget.onCreatePlayer,
              onDeletePlayer: widget.onDeletePlayer,
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
      message: context.bheText(playing ? '暂停（Space）' : '播放（Space）'),
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
      message: context.bheText(enabled ? '关闭标注（A）' : '显示标注（A）'),
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
                  context.bheText('标注'),
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 11,
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
      message: context.bheText('切换视频来源'),
      child: Material(
        color: c.background.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(CsRadius.full),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _VideoSourceOption(
                label: context.bheText('候选预览'),
                icon: Icons.video_library_outlined,
                selected: !showingOriginal,
                onPressed: showingOriginal ? onPressed : null,
              ),
              _VideoSourceOption(
                label: context.bheText('原视频'),
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
      label: selected
          ? '${context.bheText('正在查看')}$label'
          : '${context.bheText('切换到')}$label',
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
                    fontSize: 11,
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
              context.bheText('标注会显示轨迹与判定点 · 按 A 可开关'),
              style: TextStyle(color: c.textSecondary, fontSize: 11),
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
      final isCoarse = overlay['source'] == 'coarse_crossing';
      final trajectoryPaint = Paint()
        ..color = const Color(0xFFFFB454)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..strokeCap = StrokeCap.round;
      if (isCoarse && points.length <= 2) {
        // 仅剩起止两点时连线是估算:用虚线与实测轨迹区分;
        // 多点粗扫轨迹是真实检测,走平滑实线。
        for (var i = 0; i + 1 < points.length; i++) {
          _drawDashedLine(canvas, points[i], points[i + 1], trajectoryPaint);
        }
      } else {
        // 检测点是离散采样(约 10fps),直接连线呈折线;用二次贝塞尔
        // 过中点的方式平滑为弧线。
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (var i = 0; i + 1 < points.length; i++) {
          final mid = Offset(
            (points[i].dx + points[i + 1].dx) / 2,
            (points[i].dy + points[i + 1].dy) / 2,
          );
          path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
        }
        path.lineTo(points.last.dx, points.last.dy);
        canvas.drawPath(path, trajectoryPaint);
      }
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
    required this.annotationsEnabled,
    required this.onToggleAnnotations,
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
  final bool annotationsEnabled;
  final ValueChanged<bool>? onToggleAnnotations;

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
      return Padding(
        key: const Key('review-video-controls-inset'),
        padding: const EdgeInsets.fromLTRB(
          Spacing.md,
          Spacing.xs,
          Spacing.md,
          Spacing.xs,
        ),
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onToggleAnnotations != null)
                _AnnotationToggle(
                  enabled: widget.annotationsEnabled,
                  onChanged: widget.onToggleAnnotations!,
                ),
            ],
          ),
        ),
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
          final event = widget.eventTimeMs;
          final eventRatio =
              event == null || event < rangeStart || event > rangeEnd
              ? null
              : (event - rangeStart) / (rangeEnd - rangeStart);
          const compact = BoxConstraints.tightFor(width: 34, height: 34);
          final labelStyle = theme.textTheme.labelSmall?.copyWith(
            color: c.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          );
          final playback = <Widget>[
            IconButton(
              tooltip: '${context.bheText('上一个候选')} (↑)',
              onPressed: widget.enabled && widget.hasPrevious
                  ? widget.onPrevious
                  : null,
              icon: const Icon(Icons.skip_previous, size: 19),
              constraints: compact,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: false,
              builder: (context, snapshot) => IconButton(
                tooltip: snapshot.data == true
                    ? '${context.bheText('暂停')} (Space)'
                    : '${context.bheText('播放')} (Space)',
                onPressed: !widget.enabled
                    ? null
                    : () => unawaited(widget.onTogglePlayback()),
                style: IconButton.styleFrom(
                  backgroundColor: c.textPrimary,
                  foregroundColor: c.background,
                  disabledBackgroundColor: c.surface3,
                ),
                icon: Icon(
                  snapshot.data == true ? Icons.pause : Icons.play_arrow,
                  size: 20,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
            IconButton(
              tooltip: '${context.bheText('下一个候选')} (↓)',
              onPressed: widget.enabled && widget.hasNext
                  ? widget.onNext
                  : null,
              icon: const Icon(Icons.skip_next, size: 19),
              constraints: compact,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ];
          final time = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.isOriginalVideo) ...[
                Text(context.bheText('原视频'), style: labelStyle),
                const SizedBox(width: Spacing.sm),
              ],
              Text(
                '${_formatDuration(Duration(milliseconds: positionMs - rangeStart))} / '
                '${_formatDuration(Duration(milliseconds: rangeEnd - rangeStart))}',
                style: labelStyle?.copyWith(color: c.textPrimary),
              ),
            ],
          );
          final track = SizedBox(
            height: 22,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The slider insets its track by the thumb radius.
                const inset = 5.0;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: inset,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Platform.isWindows
                            ? ExcludeSemantics(child: slider)
                            : slider,
                      ),
                    ),
                    if (eventRatio != null)
                      Positioned(
                        left:
                            inset +
                            eventRatio * (constraints.maxWidth - inset * 2) -
                            1,
                        top: 0,
                        child: IgnorePointer(
                          child: Container(
                            width: 2,
                            height: 7,
                            color: c.warning,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
          final extras = <Widget>[
            if (event != null) ...[
              IconButton(
                tooltip: context.bheText('重播当前片段'),
                onPressed: widget.enabled
                    ? () => unawaited(widget.onReplayCandidate())
                    : null,
                icon: const Icon(Icons.replay, size: 18),
                constraints: compact,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: widget.loopEnabled
                    ? context.bheText('关闭循环播放 (L)')
                    : context.bheText('循环当前片段 (L)'),
                onPressed: widget.enabled ? widget.onToggleLoop : null,
                style: IconButton.styleFrom(
                  backgroundColor: widget.loopEnabled
                      ? c.orange.withValues(alpha: 0.14)
                      : null,
                ),
                icon: Icon(
                  Icons.repeat,
                  size: 18,
                  color: widget.loopEnabled ? c.orange : null,
                ),
                constraints: compact,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ],
            if (widget.onToggleAnnotations != null) ...[
              const SizedBox(width: Spacing.xs),
              _AnnotationToggle(
                enabled: widget.annotationsEnabled,
                onChanged: widget.onToggleAnnotations!,
              ),
            ],
            StreamBuilder<double>(
              stream: player.stream.rate,
              initialData: player.state.rate,
              builder: (context, snapshot) {
                final rate = snapshot.data ?? 1.0;
                return PopupMenuButton<double>(
                  tooltip:
                      '${context.bheText('播放速度')}：${_playbackRateLabel(rate)}',
                  initialValue: rate,
                  enabled: widget.enabled,
                  onSelected: (next) =>
                      unawaited(widget.onSetPlaybackRate(next)),
                  itemBuilder: (context) => [
                    for (final option in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
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
                        style: labelStyle?.copyWith(
                          color: widget.enabled
                              ? c.textSecondary
                              : c.textTertiary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ];
          return Padding(
            key: const Key('review-video-controls-inset'),
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.xs,
              Spacing.md,
              Spacing.xs,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 600) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      track,
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: Spacing.sm,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: playback,
                          ),
                          time,
                          Row(mainAxisSize: MainAxisSize.min, children: extras),
                        ],
                      ),
                    ],
                  );
                }
                return SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      ...playback,
                      const SizedBox(width: Spacing.sm),
                      time,
                      const SizedBox(width: Spacing.md),
                      Expanded(child: track),
                      const SizedBox(width: Spacing.sm),
                      ...extras,
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _CandidateInspector extends StatelessWidget {
  const _CandidateInspector({
    required this.candidate,
    required this.excluded,
    required this.busy,
    required this.players,
    required this.playerColor,
    required this.onInclude,
    required this.onExclude,
    required this.onSetPlayer,
    required this.onCreatePlayer,
    required this.onDeletePlayer,
    required this.onEditRange,
    required this.onEditNote,
    required this.onUndo,
  });

  final Map<String, dynamic> candidate;
  final bool excluded;
  final bool busy;
  final List<Map<String, dynamic>> players;
  final Color playerColor;
  final VoidCallback onInclude;
  final VoidCallback onExclude;
  final ValueChanged<String?> onSetPlayer;
  final VoidCallback onCreatePlayer;
  final Future<void> Function(String, String) onDeletePlayer;
  final VoidCallback? onEditRange;
  final VoidCallback? onEditNote;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
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
    final clip = context.bheText(
      '片段 ${_formatMs(_clipStart(candidate))} - ${_formatMs(_clipEnd(candidate))} · '
      '时长 ${_formatClipDuration(_clipEnd(candidate) - _clipStart(candidate))}',
    );
    final note = candidate['note']?.toString().trim() ?? '';
    final statusColor = excluded ? c.error : c.goal;
    final mono = theme.textTheme.labelSmall?.copyWith(
      color: c.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                _candidateSegment(candidate) > 0
                    ? '${context.bheText('第 ${_candidateSegment(candidate)} 段')} · ${_formatMs(_candidateTime(candidate))}'
                    : context.bheText(
                        '候选 ${_formatMs(_candidateTime(candidate))}',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            DecoratedBox(
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(CsRadius.xs),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  excluded
                      ? l10n?.reviewWillNotExport ?? '不会导出'
                      : l10n?.reviewWillExport ?? '会导出',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(clip, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.sticky_note_2_outlined,
                size: 13,
                color: c.textTertiary,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _PlayerChip(
              key: const ValueKey('inspector-player-chip'),
              name: candidate['player_name']?.toString(),
              color: playerColor,
              players: players,
              onSelected: onSetPlayer,
              onCreate: onCreatePlayer,
              onDelete: onDeletePlayer,
            ),
            Tooltip(
              message: context.bheText('调整片段范围'),
              child: _InspectorAction(
                icon: Icons.tune_rounded,
                label: l10n?.reviewAdjustRange ?? '调整范围',
                onPressed: onEditRange,
              ),
            ),
            Tooltip(
              message: context.bheText('编辑备注'),
              child: _InspectorAction(
                icon: Icons.edit_outlined,
                label: l10n?.reviewNote ?? '备注',
                onPressed: onEditNote,
              ),
            ),
          ],
        ),
      ],
    );

    final crossingUnknown =
        isCoarse && crossingState == _CrossingDisplay.unknown;
    final rimCheck = _rimCheckDisplay(c, evidence['rim_check']);
    final metrics = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _InspectorMetricRow(
          label: l10n?.reviewScores ?? '评分',
          cells: [
            _InspectorMetric(
              label: context.bheText('候选置信度'),
              value: context.bheText(
                _candidateConfidence(candidate, evidence) ?? '—',
              ),
              color: c.textPrimary,
              tooltip: context.bheText('综合轨迹穿框、篮网运动和反弹等信号得出，只用于排序和辅助审核。'),
            ),
            _InspectorMetric(
              label: context.bheText('轨迹评分'),
              value: _formatScore(trajectoryScore),
              color: c.textPrimary,
              ratio: trajectoryScore is num ? trajectoryScore.toDouble() : null,
            ),
            _InspectorMetric(
              label: context.bheText('预测评分'),
              value: context.bheText(
                _formatPredictionScore(
                  prediction,
                  isCoarse: isCoarse,
                  isManual: isManual,
                ),
              ),
              color: prediction is num ? c.textPrimary : c.textTertiary,
              ratio: prediction is num ? prediction.toDouble() : null,
              tooltip: context.bheText(
                _predictionScoreTooltip(
                  prediction,
                  isCoarse: isCoarse,
                  isManual: isManual,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _InspectorMetricRow(
          label: l10n?.reviewSignals ?? '信号',
          cells: [
            _InspectorMetric(
              label: context.bheText('轨迹穿框'),
              value: crossingUnknown
                  ? context.bheText('粗扫通过')
                  : context.bheText(_formatCrossing(crossingState)),
              color: crossingUnknown
                  ? c.warning
                  : _crossingColor(c, crossingState),
              dot: true,
              tooltip: context.bheText('判断篮球轨迹是否从篮筐上方进入，并在篮筐横向范围内向下穿过。'),
            ),
            _InspectorMetric(
              label: context.bheText('篮网运动'),
              value: net == null && isCoarse
                  ? context.bheText('未计算')
                  : context.bheText(_formatSignal(net)),
              color: net == null && isCoarse
                  ? c.textTertiary
                  : _signalColor(c, net),
              dot: true,
              tooltip: context.bheText('检测白色篮网区域在球经过后的运动强度；光线、球员遮挡会影响该信号。'),
            ),
            _InspectorMetric(
              label: context.bheText('反弹判断'),
              value: rebound == null && isCoarse
                  ? context.bheText('未计算')
                  : context.bheText(_formatRebound(rebound)),
              color: rebound == null && isCoarse
                  ? c.textTertiary
                  : _reboundColor(c, rebound),
              dot: true,
              tooltip: context.bheText('检测篮球撞框后向上或向外回弹；出现反弹通常降低进球可能性。'),
            ),
          ],
        ),
        if (rimCheck != null) ...[
          const SizedBox(height: 10),
          Tooltip(
            message: context.bheText(
              '按原视频逐帧放大篮筐区域，确认球从篮筐上方进入、被篮网遮挡并从网底落下。只有看清球没进的候选会自动排除；没看清的保留并标为未确认，都可以随时修改。',
            ),
            child: Row(
              key: const Key('inspector-rim-check'),
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: rimCheck.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  context.bheText('篮筐复核'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textTertiary,
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    context.bheText(rimCheck.label),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: rimCheck.color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Tooltip(
          message: context.bheText('当前候选被纳入审核列表的主要原因。'),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 13, color: c.textTertiary),
              const SizedBox(width: 4),
              Text(
                context.bheText('系统说明'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textTertiary,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  context.bheText(_reviewReasonLabel(reason)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final keep = _InspectorDecision(
      key: const Key('inspector-keep'),
      icon: Icons.check_rounded,
      label: l10n?.reviewKeepAction ?? '保留',
      shortcut: 'C',
      active: !excluded,
      color: c.goal,
      onPressed: busy ? null : onInclude,
    );
    final exclude = _InspectorDecision(
      key: const Key('inspector-exclude'),
      icon: Icons.close_rounded,
      label: l10n?.reviewExcludeAction ?? '排除',
      shortcut: 'X',
      active: excluded,
      color: c.error,
      onPressed: busy ? null : onExclude,
    );
    final undo = Tooltip(
      message: context.bheText('撤销上一次审核 (Cmd/Ctrl+Z)'),
      child: TextButton.icon(
        onPressed: busy ? null : onUndo,
        icon: const Icon(Icons.undo_rounded, size: 15),
        label: Text(l10n?.reviewUndoLast ?? '撤销上一步'),
        style: TextButton.styleFrom(
          foregroundColor: c.textSecondary,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );

    return Semantics(
      container: true,
      label: l10n?.reviewCurrentClip ?? '当前片段',
      child: Container(
        key: const Key('candidate-inspector'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(Spacing.md, 12, Spacing.md, 14),
        decoration: BoxDecoration(
          color: c.surface2,
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 680) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  summary,
                  const SizedBox(height: 12),
                  metrics,
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: keep),
                      const SizedBox(width: Spacing.sm),
                      Expanded(child: exclude),
                      undo,
                    ],
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 10, child: summary),
                const SizedBox(width: 20),
                Expanded(flex: 14, child: metrics),
                const SizedBox(width: 20),
                SizedBox(
                  width: 156,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      keep,
                      const SizedBox(height: Spacing.sm),
                      exclude,
                      const SizedBox(height: 4),
                      undo,
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InspectorAction extends StatelessWidget {
  const _InspectorAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textPrimary,
        side: BorderSide(color: c.borderStrong),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: Theme.of(context).textTheme.labelMedium,
      ),
    );
  }
}

class _InspectorMetricRow extends StatelessWidget {
  const _InspectorMetricRow({required this.label, required this.cells});

  final String label;
  final List<Widget> cells;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 40,
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textTertiary, fontSize: 11),
            ),
          ),
        ),
        for (var index = 0; index < cells.length; index++) ...[
          if (index > 0) const SizedBox(width: 12),
          Expanded(child: cells[index]),
        ],
      ],
    );
  }
}

class _InspectorMetric extends StatelessWidget {
  const _InspectorMetric({
    required this.label,
    required this.value,
    required this.color,
    this.tooltip,
    this.ratio,
    this.dot = false,
  });

  final String label;
  final String value;
  final Color color;
  final String? tooltip;
  final double? ratio;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: c.textTertiary, fontSize: 11),
    );
    // 空态(未计算/无数据)用空心圆点+更轻字重标记,
    // 与"有数值但信号弱"的中性灰一眼区分。
    final empty = value == '—' || value == '未计算';
    final bar = ratio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        tooltip == null
            ? labelText
            : Tooltip(message: tooltip, child: labelText),
        const SizedBox(height: 3),
        Row(
          children: [
            if (dot && !empty) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                empty ? '○ $value' : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: empty ? FontWeight.w400 : FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        if (bar != null) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: bar.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: c.surface3,
              color: c.data,
            ),
          ),
        ],
      ],
    );
  }
}

class _InspectorDecision extends StatelessWidget {
  const _InspectorDecision({
    required this.icon,
    required this.label,
    required this.shortcut,
    required this.active,
    required this.color,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final String shortcut;
  final bool active;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final foreground = active ? color : c.textSecondary;
    return Semantics(
      button: true,
      selected: active,
      child: Material(
        color: active ? color.withValues(alpha: 0.14) : c.surface3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.md),
          side: BorderSide(
            color: active ? color.withValues(alpha: 0.5) : c.border,
          ),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(CsRadius.md),
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, size: 17, color: foreground),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    shortcut,
                    style: TextStyle(
                      color: c.textTertiary,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
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

class _ClipRangeDialog extends StatefulWidget {
  const _ClipRangeDialog({
    required this.videoPath,
    required this.frameSize,
    this.rotation = 0,
    required this.startMs,
    required this.endMs,
    required this.durationMs,
    this.defaultStartMs,
    this.defaultEndMs,
    this.eventMs,
    this.title = '调整片段范围',
    this.description,
    this.confirmLabel = '应用',
  });

  final String? videoPath;
  final Size frameSize;
  final int rotation;
  final int startMs;
  final int endMs;
  final int durationMs;
  final int? defaultStartMs;
  final int? defaultEndMs;
  final int? eventMs;
  final String title;
  final String? description;
  final String confirmLabel;

  @override
  State<_ClipRangeDialog> createState() => _ClipRangeDialogState();
}

class _ClipRangeDialogState extends State<_ClipRangeDialog> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  bool _playbackRequested = false;
  late int _startMs;
  late int _endMs;
  late int _windowStartMs;
  late int _windowEndMs;
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  int _positionMs = 0;
  bool _ready = false;
  String? _error;
  String? _rangeError;
  bool _startTimeEdited = false;
  bool _endTimeEdited = false;
  // Playback that started inside the range stays inside it: it loops, or
  // stops at the end for an ending preview. Playback started outside the
  // range browses freely so a later or earlier moment can be found.
  bool _boundedPlayback = false;
  bool _loopRange = true;
  bool _wrapping = false;
  Timer? _scrubTimer;
  int? _pendingScrubMs;
  final FocusNode _keyFocus = FocusNode(debugLabel: 'clip-range-shortcuts');

  static const int _windowPaddingMs = 15000;
  static const int _windowStepMs = 5000;
  static const int _minClipMs = 1000;

  @override
  void initState() {
    super.initState();
    _startMs = widget.startMs;
    _endMs = widget.endMs;
    _windowStartMs = (_startMs - _windowPaddingMs)
        .clamp(0, widget.durationMs - _minClipMs)
        .toInt();
    _windowEndMs = (_endMs + _windowPaddingMs)
        .clamp(_windowStartMs + _minClipMs, widget.durationMs)
        .toInt();
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
          enableHardwareAcceleration: !useSoftwareVideo(),
        ),
      );
      _positionSubscription = player.stream.position.listen((position) {
        if (!mounted || !identical(player, _player)) return;
        final next = position.inMilliseconds;
        if (_pendingScrubMs == null && (next - _positionMs).abs() >= 40) {
          setState(() => _positionMs = next);
        }
        if (_boundedPlayback &&
            !_wrapping &&
            player.state.playing &&
            next >= _endMs) {
          unawaited(_handleRangeEnd(player));
        }
      });
      _playingSubscription = player.stream.playing.listen((playing) {
        // 防自动播放闸:未经用户请求的播放立即暂停,避免"界面没在
        // 播放却有声音"。
        if (playing &&
            !_playbackRequested &&
            mounted &&
            identical(player, _player)) {
          unawaited(player.pause());
        }
      });
      await matchPlayerToSourceRotation(player, rotation: widget.rotation);
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
    unawaited(_playingSubscription?.cancel());
    _scrubTimer?.cancel();
    _keyFocus.dispose();
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

  Future<void> _handleRangeEnd(Player player) async {
    _wrapping = true;
    try {
      if (_loopRange) {
        await player.seek(Duration(milliseconds: _startMs));
      } else {
        _playbackRequested = false;
        _boundedPlayback = false;
        await player.pause();
        await player.seek(Duration(milliseconds: _endMs));
        if (mounted) setState(() => _positionMs = _endMs);
      }
    } catch (error) {
      if (mounted && identical(player, _player)) {
        setState(() => _error = error.toString());
      }
    } finally {
      _wrapping = false;
    }
  }

  /// Moves the playhead at once and throttles decoder seeks while dragging.
  void _scrubTo(int position) {
    final target = position.clamp(0, widget.durationMs).toInt();
    setState(() => _positionMs = target);
    _pendingScrubMs = target;
    if (_scrubTimer != null) return;
    unawaited(_seek(target));
    _scrubTimer = Timer(const Duration(milliseconds: 120), () {
      _scrubTimer = null;
      final pending = _pendingScrubMs;
      if (pending != null && pending != target && mounted) _scrubTo(pending);
    });
  }

  void _finishScrub(int position) {
    _scrubTimer?.cancel();
    _scrubTimer = null;
    _pendingScrubMs = null;
    unawaited(_seek(position));
  }

  Future<void> _pauseForEditing() async {
    final player = _player;
    if (player == null || !player.state.playing) return;
    _playbackRequested = false;
    _boundedPlayback = false;
    await player.pause();
  }

  void _onTimelineRangeChanged(ClipRangeHandle handle, int startMs, int endMs) {
    if (_player?.state.playing == true) unawaited(_pauseForEditing());
    _setRange(startMs, endMs, expandWindow: false);
    _scrubTo(handle == ClipRangeHandle.start ? startMs : endMs);
  }

  void _onTimelineRangeChangeEnd(ClipRangeHandle handle) {
    _finishScrub(handle == ClipRangeHandle.start ? _startMs : _endMs);
  }

  void _extendWindow(ClipRangeHandle handle) {
    setState(() {
      if (handle == ClipRangeHandle.start) {
        _windowStartMs = (_windowStartMs - _windowStepMs)
            .clamp(0, _windowStartMs)
            .toInt();
      } else {
        _windowEndMs = (_windowEndMs + _windowStepMs)
            .clamp(_windowEndMs, widget.durationMs)
            .toInt();
      }
    });
  }

  void _nudge(ClipRangeHandle handle, int deltaMs) {
    if (handle == ClipRangeHandle.start) {
      final start = (_startMs + deltaMs).clamp(0, _endMs - _minClipMs).toInt();
      _setRange(start, _endMs);
      _finishScrub(start);
    } else {
      final end = (_endMs + deltaMs)
          .clamp(_startMs + _minClipMs, widget.durationMs)
          .toInt();
      _setRange(_startMs, end);
      _finishScrub(end);
    }
  }

  void _extendBoth() {
    final start = (_startMs - 2000).clamp(0, _startMs).toInt();
    final end = (_endMs + 2000).clamp(_endMs, widget.durationMs).toInt();
    _setRange(start, end);
  }

  /// Sets one end at the playhead. A playhead on the far side of the other
  /// end slides the clip there and keeps its length.
  void _setHandleAtPosition(ClipRangeHandle handle) {
    final position = _positionMs.clamp(0, widget.durationMs).toInt();
    final length = _endMs - _startMs;
    if (handle == ClipRangeHandle.start) {
      if (position <= _endMs - _minClipMs) {
        _setRange(position, _endMs);
      } else {
        final end = (position + length).clamp(position, widget.durationMs);
        final start = (end - length).clamp(0, position).toInt();
        _setRange(start, end.toInt());
      }
    } else {
      if (position >= _startMs + _minClipMs) {
        _setRange(_startMs, position);
      } else {
        final start = (position - length).clamp(0, position).toInt();
        final end = (start + length).clamp(position, widget.durationMs);
        _setRange(start, end.toInt());
      }
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null) return;
    if (player.state.playing) {
      _playbackRequested = false;
      _boundedPlayback = false;
      await player.pause();
      return;
    }
    final position = _positionMs;
    const tolerance = 200;
    if (position >= _startMs && position < _endMs - tolerance) {
      _boundedPlayback = true;
    } else if (position < _startMs - tolerance ||
        position > _endMs + tolerance) {
      _boundedPlayback = false;
    } else {
      await _seek(_startMs);
      _boundedPlayback = true;
    }
    _loopRange = true;
    _playbackRequested = true;
    await player.play();
  }

  Future<void> _previewEnding() async {
    final player = _player;
    if (player == null) return;
    final from = (_endMs - 3000).clamp(_startMs, _endMs).toInt();
    _playbackRequested = false;
    await player.pause();
    await _seek(from);
    _boundedPlayback = true;
    _loopRange = false;
    _playbackRequested = true;
    await player.play();
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !_ready ||
        clipRangeTextFieldFocused() ||
        clipRangeCommandPressed()) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      unawaited(_togglePlayback());
    } else if (key == LogicalKeyboardKey.keyI) {
      _setHandleAtPosition(ClipRangeHandle.start);
    } else if (key == LogicalKeyboardKey.keyO) {
      _setHandleAtPosition(ClipRangeHandle.end);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _finishScrub(_positionMs - 1000);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _finishScrub(_positionMs + 1000);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _restoreDefault() {
    _setRange(
      widget.defaultStartMs ?? widget.startMs,
      widget.defaultEndMs ?? widget.endMs,
    );
    unawaited(_seek(_startMs));
  }

  void _setRange(int startMs, int endMs, {bool expandWindow = true}) {
    setState(() {
      _startMs = startMs;
      _endMs = endMs;
      // Programmatic edits may need a wider axis. Dragging keeps its axis
      // stable or the handles move underneath the pointer on every update.
      if (expandWindow) {
        if (startMs < _windowStartMs + 1000) {
          _windowStartMs = (startMs - _windowStepMs).clamp(0, startMs).toInt();
        }
        if (endMs > _windowEndMs - 1000) {
          _windowEndMs = (endMs + _windowStepMs)
              .clamp(endMs, widget.durationMs)
              .toInt();
        }
      }
      _startController.text = _formatMs(startMs);
      _endController.text = _formatMs(endMs);
      _startTimeEdited = false;
      _endTimeEdited = false;
      _rangeError = null;
    });
  }

  void _submitTimeField({required bool isStart}) {
    final range = _readDraftRange();
    if (range == null) return;
    _setRange(range.startMs, range.endMs);
    unawaited(_seek(isStart ? range.startMs : range.endMs));
  }

  ({int startMs, int endMs})? _readDraftRange() {
    // Unchanged fields retain their millisecond precision despite the compact
    // whole-second display. Both drafts are read even when only one used Enter.
    final start = _startTimeEdited
        ? _parseTimeMs(_startController.text)
        : _startMs;
    final end = _endTimeEdited ? _parseTimeMs(_endController.text) : _endMs;
    if (start == null ||
        end == null ||
        start < 0 ||
        end > widget.durationMs ||
        end - start < 1000) {
      final l10n = Localizations.of<BheLocalizations>(
        context,
        BheLocalizations,
      );
      setState(
        () => _rangeError =
            l10n?.reviewInvalidClipRange ?? '请输入有效时间：范围须在视频内，且时长至少为 1 秒。',
      );
      return null;
    }
    return (startMs: start, endMs: end);
  }

  void _applyRange() {
    final range = _readDraftRange();
    if (range != null) Navigator.pop(context, range);
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
      if (minutes == null ||
          seconds == null ||
          minutes < 0 ||
          seconds < 0 ||
          seconds > 59) {
        return null;
      }
      return (minutes * 60 + seconds) * 1000;
    }
    if (parts.length == 3) {
      final hours = int.tryParse(parts[0]);
      final minutes = int.tryParse(parts[1]);
      final seconds = int.tryParse(parts[2]);
      if (hours == null ||
          minutes == null ||
          seconds == null ||
          hours < 0 ||
          minutes < 0 ||
          seconds < 0 ||
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
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final start = _startMs;
    final end = _endMs;
    final inside = _positionMs >= start && _positionMs <= end;
    final status = _positionMs < start
        ? l10n?.rangeStatusBefore ?? '范围前'
        : _positionMs > end
        ? l10n?.rangeStatusAfter ?? '范围后'
        : l10n?.rangeStatusInside ?? '范围内';
    final statusColor = inside ? c.success : c.warning;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: c.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final controller = _controller;
    return Focus(
      focusNode: _keyFocus,
      autofocus: true,
      onKeyEvent: (_, event) => _handleKey(event),
      child: Dialog(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.md),
          side: BorderSide(color: c.borderStrong),
        ),
        insetPadding: const EdgeInsets.all(Spacing.lg),
        child: SingleChildScrollView(
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
                    widget.description ??
                        l10n?.rangeEditorHint ??
                        '播放片段会在范围内循环；拖动两端、拖到边缘可继续延长，或用 I / O 把当前位置设为开始 / 结束。原视频不会被修改。',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: Spacing.sm),
                  AspectRatio(
                    key: const Key('clip-range-video-frame'),
                    aspectRatio: widget.frameSize.aspectRatio,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(color: Colors.black),
                      child: _error != null
                          ? Center(
                              child: Text(
                                context.bheText(_error!),
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
                                  ? () {
                                      _keyFocus.requestFocus();
                                      unawaited(_togglePlayback());
                                    }
                                  : null,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: OrientedVideo(
                                  controller: controller,
                                  // 框已是视频比例。Windows 软件渲染的纹理比例
                                  // 可能不对、里面带黑边,cover 正好把黑边裁掉;
                                  // 带 rotation 的原视频在 Windows 上要自己转正。
                                  rotation: playerAppliesRotation()
                                      ? 0
                                      : widget.rotation,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Row(
                    children: [
                      StreamBuilder<bool>(
                        stream: _player?.stream.playing,
                        initialData: _player?.state.playing ?? false,
                        builder: (context, snapshot) {
                          final playing = snapshot.data == true;
                          return IconButton(
                            key: const Key('clip-range-play'),
                            tooltip: playing
                                ? l10n?.rangePause ?? '暂停（Space）'
                                : l10n?.rangePlayClip ?? '播放片段（Space）',
                            onPressed: _ready
                                ? () => unawaited(_togglePlayback())
                                : null,
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          );
                        },
                      ),
                      TextButton.icon(
                        key: const Key('clip-range-preview-ending'),
                        onPressed: _ready
                            ? () => unawaited(_previewEnding())
                            : null,
                        icon: const Icon(Icons.last_page_rounded, size: 18),
                        label: Text(l10n?.rangePreviewEnding ?? '预览结尾'),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Text(
                        l10n?.rangePosition(_formatMs(_positionMs)) ??
                            '当前位置 ${_formatMs(_positionMs)}',
                        style: labelStyle,
                      ),
                      const SizedBox(width: Spacing.xs),
                      Container(
                        key: const Key('clip-range-status'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(CsRadius.xs),
                        ),
                        child: Text(
                          status,
                          style: labelStyle?.copyWith(color: statusColor),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          l10n?.rangeSummary(
                                _formatMs(start),
                                _formatMs(end),
                                _formatClipDuration(end - start),
                              ) ??
                              '片段 ${_formatMs(start)} – ${_formatMs(end)} · '
                                  '${_formatClipDuration(end - start)}',
                          style: labelStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.xs),
                  Listener(
                    onPointerDown: (_) => _keyFocus.requestFocus(),
                    child: ClipRangeTimeline(
                      key: const Key('clip-range-timeline'),
                      windowStartMs: _windowStartMs,
                      windowEndMs: _windowEndMs,
                      startMs: start,
                      endMs: end,
                      positionMs: _positionMs,
                      eventMs: widget.eventMs,
                      originalStartMs: widget.startMs,
                      originalEndMs: widget.endMs,
                      enabled: _ready,
                      minDurationMs: _minClipMs,
                      semanticLabel: l10n?.rangeTimelineLabel ?? '片段时间轴',
                      onRangeChanged: _onTimelineRangeChanged,
                      onRangeChangeEnd: _onTimelineRangeChangeEnd,
                      onScrub: _scrubTo,
                      onScrubEnd: _finishScrub,
                      onExtendWindow: _extendWindow,
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        _formatMs(_windowStartMs),
                        style: labelStyle?.copyWith(color: c.textTertiary),
                      ),
                      const Spacer(),
                      if (widget.eventMs != null) ...[
                        Icon(Icons.arrow_drop_down, size: 16, color: c.warning),
                        Text(
                          l10n?.rangeLegendEvent ?? '进球时刻',
                          style: labelStyle?.copyWith(color: c.textTertiary),
                        ),
                        const SizedBox(width: Spacing.sm),
                      ],
                      if (start != widget.startMs || end != widget.endMs) ...[
                        Text(
                          '┄ ',
                          style: labelStyle?.copyWith(color: c.textSecondary),
                        ),
                        Text(
                          l10n?.rangeLegendOriginal ?? '原范围',
                          style: labelStyle?.copyWith(color: c.textTertiary),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        _formatMs(_windowEndMs),
                        style: labelStyle?.copyWith(color: c.textTertiary),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _RangeHandleEditor(
                          label: context.bheText('开始'),
                          controller: _startController,
                          keyPrefix: 'clip-range-start',
                          setHereLabel: l10n?.rangeSetStart ?? '设为开始（I）',
                          enabled: _ready,
                          onChanged: () => _startTimeEdited = true,
                          onSubmitted: () => _submitTimeField(isStart: true),
                          onNudge: (delta) =>
                              _nudge(ClipRangeHandle.start, delta),
                          onSetHere: () =>
                              _setHandleAtPosition(ClipRangeHandle.start),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: _RangeHandleEditor(
                          label: context.bheText('结束'),
                          controller: _endController,
                          keyPrefix: 'clip-range-end',
                          setHereLabel: l10n?.rangeSetEnd ?? '设为结束（O）',
                          enabled: _ready,
                          onChanged: () => _endTimeEdited = true,
                          onSubmitted: () => _submitTimeField(isStart: false),
                          onNudge: (delta) =>
                              _nudge(ClipRangeHandle.end, delta),
                          onSetHere: () =>
                              _setHandleAtPosition(ClipRangeHandle.end),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.xs),
                  Wrap(
                    spacing: Spacing.xs,
                    runSpacing: Spacing.xs,
                    children: [
                      ActionChip(
                        key: const Key('clip-range-extend-start'),
                        avatar: const Icon(Icons.first_page_rounded, size: 16),
                        label: Text(l10n?.rangeExtendStart ?? '开头 −2 秒'),
                        onPressed: () => _nudge(ClipRangeHandle.start, -2000),
                      ),
                      ActionChip(
                        key: const Key('clip-range-extend-end'),
                        avatar: const Icon(Icons.last_page_rounded, size: 16),
                        label: Text(l10n?.rangeExtendEnd ?? '结尾 +2 秒'),
                        onPressed: () => _nudge(ClipRangeHandle.end, 2000),
                      ),
                      ActionChip(
                        key: const Key('clip-range-extend-both'),
                        avatar: const Icon(Icons.unfold_more_rounded, size: 16),
                        label: Text(l10n?.rangeExtendBoth ?? '前后各 +2 秒'),
                        onPressed: _extendBoth,
                      ),
                    ],
                  ),
                  if (_rangeError != null) ...[
                    const SizedBox(height: Spacing.xs),
                    Text(_rangeError!, style: TextStyle(color: c.error)),
                  ],
                  const SizedBox(height: Spacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _restoreDefault,
                        style: TextButton.styleFrom(
                          foregroundColor: c.textSecondary,
                        ),
                        child: Text(context.bheText('恢复默认')),
                      ),
                      const SizedBox(width: Spacing.xs),
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.textPrimary,
                          side: BorderSide(color: c.borderStrong),
                        ),
                        child: Text(context.bheText('取消')),
                      ),
                      const SizedBox(width: Spacing.sm),
                      FilledButton(
                        onPressed: _applyRange,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.orangeFill,
                          foregroundColor: c.onOrange,
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
        ),
      ),
    );
  }
}

class _RangeHandleEditor extends StatelessWidget {
  const _RangeHandleEditor({
    required this.label,
    required this.controller,
    required this.keyPrefix,
    required this.setHereLabel,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
    required this.onNudge,
    required this.onSetHere,
  });

  final String label;
  final TextEditingController controller;
  final String keyPrefix;
  final String setHereLabel;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onSubmitted;
  final ValueChanged<int> onNudge;
  final VoidCallback onSetHere;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final compact = TextButton.styleFrom(
      foregroundColor: c.textSecondary,
      minimumSize: const Size(44, 36),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ClipTimeField(
          label: label,
          controller: controller,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
        const SizedBox(height: Spacing.xs),
        Row(
          children: [
            for (final delta in const [-1000, -500, 500, 1000])
              TextButton(
                key: ValueKey('$keyPrefix-nudge-$delta'),
                style: compact,
                onPressed: () => onNudge(delta),
                child: Text(
                  '${delta > 0 ? '+' : '−'}${(delta.abs() / 1000).toStringAsFixed(delta.abs() % 1000 == 0 ? 0 : 1)}s',
                ),
              ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: ValueKey('$keyPrefix-set'),
                  onPressed: enabled ? onSetHere : null,
                  icon: const Icon(Icons.my_location_rounded, size: 16),
                  label: Text(
                    setHereLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textPrimary,
                    side: BorderSide(color: c.borderStrong),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ClipTimeField extends StatelessWidget {
  const _ClipTimeField({
    required this.label,
    required this.controller,
    required this.onSubmitted,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onSubmitted;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return TextField(
      controller: controller,
      onSubmitted: (_) => onSubmitted(),
      onChanged: (_) => onChanged(),
      textInputAction: TextInputAction.done,
      keyboardType: TextInputType.number,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: c.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: '00:00',
        suffixText: context.bheText('时:分:秒'),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: 10,
        ),
      ),
    );
  }
}

class _CandidatePanel extends StatelessWidget {
  const _CandidatePanel({
    required this.candidates,
    required this.overlappingIds,
    required this.selectedId,
    required this.includedCount,
    required this.reviewedCount,
    required this.totalCount,
    required this.filter,
    required this.playerFilter,
    required this.rimFilter,
    required this.segmentFilter,
    required this.statusCandidates,
    required this.busy,
    required this.busyMessage,
    required this.hydrating,
    required this.hydrateError,
    required this.analyzing,
    required this.hasVideo,
    required this.analysisMode,
    required this.analysisCompleted,
    required this.onSelect,
    required this.candidateRowContexts,
    required this.candidateScrollController,
    required this.onSetPlayer,
    required this.onCreatePlayer,
    required this.players,
    required this.onDeletePlayer,
    required this.onBatchRange,
    required this.onSetStatus,
    required this.onLoadCover,
    required this.onFilterChanged,
    required this.onPlayerFilterChanged,
    required this.onRimFilterChanged,
    required this.segments,
    required this.onSegmentFilterChanged,
    required this.onClearFilters,
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
  final Set<String> overlappingIds;
  final String? selectedId;
  final int includedCount;
  final int reviewedCount;
  final int totalCount;
  final String filter;
  final String playerFilter;
  final String rimFilter;
  final String segmentFilter;
  final List<Map<String, dynamic>> statusCandidates;
  final bool busy;
  final String? busyMessage;
  final bool hydrating;
  final String? hydrateError;
  final bool analyzing;
  final bool hasVideo;
  final String analysisMode;
  final bool analysisCompleted;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final Map<String, BuildContext> candidateRowContexts;
  final ScrollController candidateScrollController;
  final Future<void> Function(Map<String, dynamic>, String?) onSetPlayer;
  final Future<void> Function(Map<String, dynamic>) onCreatePlayer;
  final List<Map<String, dynamic>> players;
  final Future<void> Function(String, String) onDeletePlayer;
  final VoidCallback onBatchRange;
  final Future<void> Function(String, String) onSetStatus;
  final Future<String?> Function(String, int)? onLoadCover;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<String> onPlayerFilterChanged;
  final ValueChanged<String> onRimFilterChanged;

  /// 多段项目的 (视频 id, 段号)，单段项目为空。
  final List<(String, int)> segments;
  final ValueChanged<String> onSegmentFilterChanged;
  final VoidCallback onClearFilters;
  final VoidCallback? onReanalyze;
  final VoidCallback? onRetryHydration;
  final VoidCallback? onEditRange;
  final VoidCallback? onEditNote;
  final VoidCallback? onCreateManualCandidate;
  final VoidCallback onUndo;
  final VoidCallback onGoImport;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
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
          SizedBox(
            height: 34,
            child: Row(
              children: [
                Flexible(
                  child: Semantics(
                    liveRegion: busy && busyMessage != null,
                    child: Text(
                      context.bheText(busyMessage ?? '候选片段'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                if (busy && busyMessage != null)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Text(
                    '$totalCount',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: c.textTertiary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: context.bheText('批量设置片段时长'),
                  onPressed: busy ? null : onBatchRange,
                  icon: const Icon(Icons.schedule_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
                Tooltip(
                  message: context.bheText(
                    '快捷键\nSpace  播放/暂停\nL  循环当前\nA  显示/关闭标注\n↑ / ↓  切换候选\n← / →  快退/快进 2 秒 · 加 Shift 每次 0.1 秒\nC / Enter  保留\nX / ` / Backspace  排除\n1–9、Q–P  设置球员标签 · 0  清除\nCmd/Ctrl+Z  撤销',
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.keyboard_outlined,
                      size: 17,
                      color: c.textSecondary,
                    ),
                  ),
                ),
                if (hasVideo)
                  PopupMenuButton<String>(
                    key: const Key('review-more-actions'),
                    tooltip: l10n?.reviewMoreActions ?? '更多操作',
                    icon: Icon(
                      Icons.more_horiz,
                      size: 18,
                      color: c.textSecondary,
                    ),
                    onSelected: (value) => switch (value) {
                      'reanalyze' => onReanalyze?.call(),
                      _ => onGoImport(),
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'reanalyze',
                        enabled: onReanalyze != null,
                        child: Text(context.bheText('重新分析当前视频')),
                      ),
                      PopupMenuItem(
                        value: 'reconfigure',
                        enabled: !busy,
                        child: Text(context.bheText('重新配置分析区域和范围')),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (totalCount > 0) ...[
            const SizedBox(height: 2),
            Row(
              key: const Key('review-progress'),
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: reviewedCount / totalCount,
                      minHeight: 3,
                      backgroundColor: c.surface3,
                      color: c.data,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  l10n?.reviewProgress(reviewedCount, totalCount) ??
                      '已审核 $reviewedCount / $totalCount',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.sm),
          _StatusSegments(
            value: filter,
            total: totalCount,
            included: includedCount,
            onChanged: onFilterChanged,
          ),
          const SizedBox(height: Spacing.sm),
          _PlayerTagChips(
            value: playerFilter,
            candidates: statusCandidates,
            players: players,
            onChanged: onPlayerFilterChanged,
          ),
          if (statusCandidates.any((c) => _rimCheckStatus(c) != null)) ...[
            const SizedBox(height: Spacing.sm),
            _RimCheckChips(
              value: rimFilter,
              candidates: statusCandidates,
              onChanged: onRimFilterChanged,
            ),
          ],
          if (segments.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            _SegmentChips(
              value: segmentFilter,
              segments: segments,
              candidates: statusCandidates,
              onChanged: onSegmentFilterChanged,
            ),
          ],
          if (filter != 'all' ||
              playerFilter != 'all' ||
              rimFilter != 'all' ||
              segmentFilter != 'all') ...[
            const SizedBox(height: Spacing.sm),
            Container(
              key: const Key('review-filter-banner'),
              padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(CsRadius.sm),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.filter_alt_outlined,
                    size: 14,
                    color: c.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n?.reviewFilterCount(candidates.length, totalCount) ??
                          '显示 ${candidates.length} / $totalCount',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onClearFilters,
                    style: TextButton.styleFrom(
                      foregroundColor: c.textPrimary,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(l10n?.reviewClearFilters ?? '清除筛选'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: Spacing.sm),
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
                    onClearFilter:
                        filter == 'all' &&
                            playerFilter == 'all' &&
                            rimFilter == 'all' &&
                            segmentFilter == 'all'
                        ? null
                        : onClearFilters,
                    onReanalyze: onReanalyze,
                    onRetryHydration: onRetryHydration,
                    onGoImport: onGoImport,
                  )
                : ListView.separated(
                    controller: candidateScrollController,
                    // A hovered row asks to be kept alive. When it is scrolled
                    // away it is then never laid out, and a tooltip it just
                    // opened breaks mouse hit testing for the whole window.
                    addAutomaticKeepAlives: false,
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.xs),
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      final id = candidate['id']?.toString() ?? '';
                      final coverFuture = onLoadCover == null
                          ? null
                          : onLoadCover!(id, _candidateTime(candidate));
                      return _RowContextAnchor(
                        key: ValueKey('candidate-row-$id'),
                        id: id,
                        contexts: candidateRowContexts,
                        child: _CandidateRow(
                          candidate: candidate,
                          overlapsPrevious: overlappingIds.contains(id),
                          index: index,
                          selected: id == selectedId,
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
                            c,
                            candidate['player_id']?.toString(),
                            _playerIndex(candidate, players),
                          ),
                          onInclude: () =>
                              unawaited(onSetStatus(id, 'included')),
                          onExclude: () =>
                              unawaited(onSetStatus(id, 'excluded')),
                          coverFuture: coverFuture,
                        ),
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
                  flex: 3,
                  child: CsButton(
                    label: Flexible(
                      child: Text(
                        context.bheText('导出 $includedCount 个片段'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    icon: Icons.file_upload_outlined,
                    onPressed: onExport,
                  ),
                ),
                if (hasVideo) ...[
                  const SizedBox(width: Spacing.sm),
                  Flexible(
                    flex: 2,
                    child: Tooltip(
                      message: context.bheText('从原视频当前时间补漏候选'),
                      child: OutlinedButton.icon(
                        key: const Key('create-manual-candidate'),
                        onPressed: onCreateManualCandidate,
                        icon: const Icon(Icons.playlist_add_rounded, size: 18),
                        label: Text(
                          l10n?.reviewAddMissed ?? '补漏片段',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.textPrimary,
                          side: BorderSide(color: c.borderStrong),
                          minimumSize: const Size(0, 40),
                        ),
                      ),
                    ),
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

class _StatusSegments extends StatelessWidget {
  const _StatusSegments({
    required this.value,
    required this.total,
    required this.included,
    required this.onChanged,
  });

  final String value;
  final int total;
  final int included;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final options = [
      ('all', l10n?.reviewStatusAll ?? '全部', total),
      ('included', l10n?.reviewStatusKept ?? '保留', included),
      ('excluded', l10n?.reviewStatusExcluded ?? '排除', total - included),
    ];
    return Semantics(
      container: true,
      label: l10n?.reviewStatusFilter ?? '按保留／排除筛选',
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(CsRadius.md),
        ),
        child: Row(
          children: [
            for (final (key, label, count) in options)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: value == key,
                  child: Material(
                    key: ValueKey('review-status-$key'),
                    color: value == key ? c.surface3 : Colors.transparent,
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                    child: InkWell(
                      onTap: () => onChanged(key),
                      borderRadius: BorderRadius.circular(CsRadius.sm),
                      child: SizedBox(
                        height: 30,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: value == key
                                      ? c.textPrimary
                                      : c.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '$count',
                              style: TextStyle(
                                color: c.textTertiary,
                                fontSize: 11,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Records a row's context for scrolling it into view. Rows use value keys:
/// a global key would reparent a row whose tooltip is open when the list
/// reorders, which corrupts the overlay layout and breaks mouse tracking.
class _RowContextAnchor extends StatefulWidget {
  const _RowContextAnchor({
    required this.id,
    required this.contexts,
    required this.child,
    super.key,
  });

  final String id;
  final Map<String, BuildContext> contexts;
  final Widget child;

  @override
  State<_RowContextAnchor> createState() => _RowContextAnchorState();
}

class _RowContextAnchorState extends State<_RowContextAnchor> {
  @override
  void initState() {
    super.initState();
    widget.contexts[widget.id] = context;
  }

  @override
  void didUpdateWidget(covariant _RowContextAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id &&
        identical(oldWidget.contexts[oldWidget.id], context)) {
      oldWidget.contexts.remove(oldWidget.id);
    }
    widget.contexts[widget.id] = context;
  }

  @override
  void dispose() {
    if (identical(widget.contexts[widget.id], context)) {
      widget.contexts.remove(widget.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SegmentChips extends StatelessWidget {
  const _SegmentChips({
    required this.value,
    required this.segments,
    required this.candidates,
    required this.onChanged,
  });

  final String value;
  final List<(String, int)> segments;
  final List<Map<String, dynamic>> candidates;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final counts = <String, int>{'all': candidates.length};
    for (final candidate in candidates) {
      counts.update(
        candidate['video_id']?.toString() ?? '',
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final options = <(String, String)>[
      ('all', context.bheText('全部')),
      for (final (id, segment) in segments)
        (id, context.bheText('第 $segment 段')),
    ];
    return Semantics(
      container: true,
      label: context.bheText('按视频段筛选'),
      child: SizedBox(
        key: const Key('review-segment-filter'),
        height: 30,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Text(
                context.bheText('视频段'),
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
              for (final (key, label) in options) ...[
                const SizedBox(width: 6),
                Semantics(
                  button: true,
                  selected: value == key,
                  child: Material(
                    key: ValueKey('review-segment-option-$key'),
                    color: value == key ? c.surface3 : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(CsRadius.full),
                      side: BorderSide(
                        color: value == key ? c.borderStrong : c.border,
                      ),
                    ),
                    child: InkWell(
                      onTap: () => onChanged(key),
                      customBorder: const StadiumBorder(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          '$label ${counts[key] ?? 0}',
                          style: TextStyle(
                            color: value == key
                                ? c.textPrimary
                                : c.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RimCheckChips extends StatelessWidget {
  const _RimCheckChips({
    required this.value,
    required this.candidates,
    required this.onChanged,
  });

  final String value;
  final List<Map<String, dynamic>> candidates;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final counts = <String, int>{'all': candidates.length};
    for (final candidate in candidates) {
      final status = _rimCheckStatus(candidate);
      if (status != null) {
        counts.update(status, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final options = <(String, String, Color?)>[
      ('all', '全部', null),
      ('made', '通过', c.success),
      ('unsure', '未确认', c.warning),
      if ((counts['rejected'] ?? 0) > 0) ('rejected', '未通过', c.error),
    ];
    return Semantics(
      container: true,
      label: context.bheText('按篮筐复核结果筛选'),
      child: SizedBox(
        key: const Key('review-rim-filter'),
        height: 30,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Text(
                context.bheText('篮筐复核'),
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
              for (final (key, label, color) in options) ...[
                const SizedBox(width: 6),
                Semantics(
                  button: true,
                  selected: value == key,
                  child: Material(
                    key: ValueKey('review-rim-option-$key'),
                    color: value == key ? c.surface3 : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(CsRadius.full),
                      side: BorderSide(
                        color: value == key ? c.borderStrong : c.border,
                      ),
                    ),
                    child: InkWell(
                      onTap: () => onChanged(key),
                      customBorder: const StadiumBorder(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (color != null) ...[
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              context.bheText(label),
                              style: TextStyle(
                                color: value == key
                                    ? c.textPrimary
                                    : c.textSecondary,
                                fontSize: 12,
                                fontWeight: value == key
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${counts[key] ?? 0}',
                              style: TextStyle(
                                color: c.textTertiary,
                                fontSize: 11,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerTagChips extends StatelessWidget {
  const _PlayerTagChips({
    required this.value,
    required this.candidates,
    required this.players,
    required this.onChanged,
  });

  final String value;
  final List<Map<String, dynamic>> candidates;
  final List<Map<String, dynamic>> players;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final c = AppColors.of(context);
    final counts = <String, int>{'all': candidates.length};
    for (final candidate in candidates) {
      final id = candidate['player_id']?.toString() ?? '';
      final bucket = id.isEmpty ? 'untagged' : 'tagged';
      counts.update(bucket, (count) => count + 1, ifAbsent: () => 1);
      if (id.isNotEmpty) {
        counts.update('player:$id', (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final options = <(String, String, Color?)>[
      ('all', l10n?.reviewAllTags ?? '全部标签', null),
      ('tagged', l10n?.reviewTagged ?? '已标记', null),
      ('untagged', l10n?.reviewUntagged ?? '未标记', null),
      for (var index = 0; index < players.length; index++)
        (
          'player:${players[index]['id']}',
          // The number is the shortcut that assigns this player.
          index < 9
              ? '${index + 1} · ${players[index]['name'] ?? ''}'
              : players[index]['name']?.toString() ?? '',
          _playerColor(c, players[index]['id']?.toString(), index),
        ),
    ];
    return Semantics(
      container: true,
      label: l10n?.reviewFilterPlayerTags ?? '筛选球员标签',
      child: SizedBox(
        key: const Key('review-player-filter'),
        height: 30,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fixed = options.take(3).toList();
            final playerOptions = options.skip(3).toList();
            final visible = _visiblePlayers(
              context,
              constraints.maxWidth,
              fixed,
              playerOptions,
              counts,
            );
            final hidden = [
              for (final option in playerOptions)
                if (!visible.contains(option)) option,
            ];
            final shown = [...fixed, ...visible];
            // Only scrolls when even the fixed chips do not fit.
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var index = 0; index < shown.length; index++) ...[
                    if (index > 0) const SizedBox(width: 6),
                    _tagChip(context, c, shown[index], counts),
                  ],
                  if (hidden.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _moreChip(context, c, hidden, counts),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static const _chipGap = 6.0;
  static const _labelStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );
  static const _countStyle = TextStyle(
    fontSize: 11,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  double _chipWidth(
    BuildContext context,
    (String, String, Color?) option,
    Map<String, int> counts,
  ) {
    final (key, label, color) = option;
    final labelWidth = _textWidth(context, label, _labelStyle);
    return 22 +
        (color == null ? 0 : 13) +
        (labelWidth > 140 ? 140 : labelWidth) +
        6 +
        _textWidth(context, '${counts[key] ?? 0}', _countStyle);
  }

  /// Players that fit after the fixed chips, leaving room for "+N".
  /// A selected player always stays visible so the active filter is legible.
  List<(String, String, Color?)> _visiblePlayers(
    BuildContext context,
    double maxWidth,
    List<(String, String, Color?)> fixed,
    List<(String, String, Color?)> players,
    Map<String, int> counts,
  ) {
    final moreWidth =
        _chipGap + 40 + _textWidth(context, '+${players.length}', _labelStyle);
    double widthOf(List<(String, String, Color?)> chips) {
      var total = 0.0;
      for (final chip in chips) {
        total += _chipWidth(context, chip, counts) + _chipGap;
      }
      return total - _chipGap;
    }

    bool fits(List<(String, String, Color?)> chosen) {
      final rest = players.length - chosen.length;
      return widthOf([...fixed, ...chosen]) + (rest > 0 ? moreWidth : 0) <=
          maxWidth;
    }

    final visible = <(String, String, Color?)>[];
    for (final player in players) {
      if (!fits([...visible, player])) break;
      visible.add(player);
    }
    final selected = players.where((option) => option.$1 == value).toList();
    if (selected.isNotEmpty && !visible.contains(selected.first)) {
      while (visible.isNotEmpty && !fits([...visible, selected.first])) {
        visible.removeLast();
      }
      visible.add(selected.first);
    }
    return [
      for (final player in players)
        if (visible.contains(player)) player,
    ];
  }

  Widget _moreChip(
    BuildContext context,
    AppColors c,
    List<(String, String, Color?)> hidden,
    Map<String, int> counts,
  ) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return PopupMenuButton<String>(
      key: const Key('review-tag-more'),
      tooltip: l10n?.reviewFilterPlayerTags ?? '筛选球员标签',
      onSelected: onChanged,
      constraints: const BoxConstraints(maxWidth: 320),
      itemBuilder: (context) => [
        for (final (key, label, color) in hidden)
          PopupMenuItem<String>(
            key: ValueKey('review-tag-option-$key'),
            value: key,
            child: Row(
              children: [
                if (color != null) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Text(
                  '${counts[key] ?? 0}',
                  style: TextStyle(
                    color: c.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.only(left: 10, right: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CsRadius.full),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '+${hidden.length}',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Icon(Icons.expand_more, size: 16, color: c.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _tagChip(
    BuildContext context,
    AppColors c,
    (String, String, Color?) option,
    Map<String, int> counts,
  ) {
    final (key, label, color) = option;
    final selected = value == key;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        key: ValueKey('review-tag-option-$key'),
        color: selected ? c.surface3 : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.full),
          side: BorderSide(color: selected ? c.borderStrong : c.border),
        ),
        child: InkWell(
          onTap: () => onChanged(key),
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (color != null) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Tooltip(
                    message: label,
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? c.textPrimary : c.textSecondary,
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${counts[key] ?? 0}',
                  style: TextStyle(
                    color: c.textTertiary,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
      return CsEmptyState(
        icon: Icons.sync,
        title: context.bheText('正在恢复项目'),
        description: context.bheText('正在加载候选片段和审核记录。'),
      );
    }
    if (hydrateError != null) {
      return CsEmptyState(
        icon: Icons.sync_problem_outlined,
        title: context.bheText('项目数据加载失败'),
        description: context.bheText('候选片段没有成功恢复，请重试加载，不需要重新分析视频。'),
        action: CsButton(
          label: Text(context.bheText('重试加载')),
          icon: Icons.refresh,
          onPressed: onRetryHydration,
        ),
      );
    }
    if (analyzing) {
      return CsEmptyState(
        icon: Icons.hourglass_top,
        title: context.bheText('正在等待候选片段'),
        description: context.bheText('分析完成后会显示候选片段。'),
      );
    }
    if (filterEmpty) {
      return CsEmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: context.bheText('没有匹配的候选'),
        description: context.bheText('当前筛选条件下没有片段。'),
        action: onClearFilter == null
            ? null
            : CsButton(
                label: Text(context.bheText('显示全部')),
                icon: Icons.filter_alt_off,
                onPressed: onClearFilter,
              ),
      );
    }
    final fastEmpty = hasVideo && analysisCompleted && analysisMode == 'fast';
    return CsEmptyState(
      icon: Icons.inbox_outlined,
      title: fastEmpty
          ? context.bheText('快速分析未找到候选 · 可能漏检')
          : hasVideo
          ? context.bheText('暂未找到候选片段')
          : context.bheText('还没有分析结果'),
      description: hasVideo
          ? fastEmpty
                ? context.bheText('快速模式可能漏检，建议用标准模式重新分析。')
                : context.bheText('重新分析直接使用当前配置；重新配置可以修改分析范围和篮筐区域。')
          : context.bheText('先导入视频并完成配置，再开始分析。'),
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: Spacing.xs,
        children: [
          if (hasVideo)
            CsButton(
              label: Text(context.bheText(fastEmpty ? '用标准模式重新分析' : '重新分析')),
              icon: Icons.replay,
              onPressed: onReanalyze,
            ),
          CsButton(
            label: Text(context.bheText(hasVideo ? '重新配置' : '去导入视频')),
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
    required this.overlapsPrevious,
    required this.index,
    required this.selected,
    required this.excluded,
    required this.busy,
    required this.onTap,
    required this.onSetPlayer,
    required this.onCreatePlayer,
    required this.onDeletePlayer,
    required this.players,
    required this.playerColor,
    required this.onInclude,
    required this.onExclude,
    required this.coverFuture,
  });

  final Map<String, dynamic> candidate;
  final int index;
  final bool selected;
  final bool overlapsPrevious;
  final bool excluded;
  final bool busy;
  final VoidCallback onTap;
  final ValueChanged<String?> onSetPlayer;
  final VoidCallback onCreatePlayer;
  final Future<void> Function(String, String) onDeletePlayer;
  final List<Map<String, dynamic>> players;
  final Color playerColor;
  final VoidCallback onInclude;
  final VoidCallback onExclude;
  final Future<String?>? coverFuture;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final adjusted = _hasAdjustedRange(candidate);
    final rimStatus = _rimCheckStatus(candidate);
    final statusLabel = excluded
        ? (_isAutoExcluded(candidate) ? '自动排除' : '已排除')
        : rimStatus == 'made' ? '通过' : rimStatus == 'unsure' ? '未确认' : null;
    final statusColor = excluded ? c.error : rimStatus == 'made' ? c.success : c.warning;
    return Semantics(
      button: true,
      selected: selected,
      label: context.bheText(
        '候选 ${index + 1}，${_formatMs(_candidateTime(candidate))}，${excluded ? (_isAutoExcluded(candidate) ? '自动排除' : '已排除') : '已保留'}',
      ),
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
                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _CandidateCover(
                            future: coverFuture,
                            excluded: excluded,
                            durationLabel: context.bheText(
                              _formatClipDuration(
                                _clipEnd(candidate) - _clipStart(candidate),
                              ),
                            ),
                          ),
                          const SizedBox(width: Spacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    if (!_isReviewed(candidate)) ...[
                                      Semantics(
                                        label:
                                            Localizations.of<BheLocalizations>(
                                              context,
                                              BheLocalizations,
                                            )?.reviewUnreviewed ??
                                            '未审核',
                                        child: Container(
                                          key: ValueKey(
                                            'unreviewed-${candidate['id']}',
                                          ),
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            color: c.data,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    Flexible(
                                      child: Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text: '#${index + 1} ',
                                              style: TextStyle(
                                                color: c.textTertiary,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            if (_candidateSegment(candidate) > 0)
                                              TextSpan(
                                                text:
                                                    '${context.bheText('第 ${_candidateSegment(candidate)} 段')} ',
                                                style: TextStyle(
                                                  color: c.textSecondary,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            TextSpan(
                                              text: _formatMs(
                                                _candidateTime(candidate),
                                              ),
                                            ),
                                          ],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              color: excluded
                                                  ? c.textTertiary
                                                  : c.textPrimary,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                      ),
                                    ),
                                    if (adjusted || overlapsPrevious || statusLabel != null) ...[
                                      const SizedBox(width: 4),
                                      Flexible(
                                        flex: 4,
                                        child: CandidateStatusLabels(
                                          candidateId: candidate['id'].toString(),
                                          adjusted: adjusted,
                                          overlapsPrevious: overlapsPrevious,
                                          statusLabel: statusLabel,
                                          statusColor: statusColor,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: _PlayerChip(
                                    key: ValueKey(
                                      'player-chip-${candidate['id']}',
                                    ),
                                    name: candidate['player_name']?.toString(),
                                    color: playerColor,
                                    players: players,
                                    onSelected: onSetPlayer,
                                    onCreate: onCreatePlayer,
                                    onDelete: onDeletePlayer,
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
                      tooltip: context.bheText('保留片段 (C / Enter)'),
                      icon: Icons.check_rounded,
                      active: !excluded,
                      color: c.goal,
                      enabled: !busy,
                      onPressed: onInclude,
                    ),
                    const SizedBox(width: 3),
                    _DecisionButton(
                      tooltip: context.bheText('排除片段 (X / ` / Backspace)'),
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
        : Colors.transparent;
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
              width: 40,
              height: 38,
              child: Icon(icon, size: 19, color: foreground),
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
      message: context.bheText('设置球员标签'),
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
            onManageGroups: () {
              _menuController.close();
              unawaited(
                showDialog<void>(
                  context: context,
                  builder: (_) => const _PlayerGroupsDialog(),
                ),
              );
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
                          ? context.bheText('未标记')
                          : widget.name!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.color,
                        fontSize: 11,
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
    required this.onManageGroups,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> players;
  final ValueChanged<String?> onSelected;
  final VoidCallback onCreate;
  final VoidCallback onManageGroups;
  final Future<void> Function(String, String)? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // 标题、未标记、新建和分组这几行约 156，每个球员一行 34；人多时撑高到窗口的 80%。
    final fitted = 156 + 34.0 * (players.isEmpty ? 1 : players.length);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    final height = fitted.clamp(330.0, maxHeight < 330 ? 330.0 : maxHeight);
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(CsRadius.sm),
      child: SizedBox(
        width: 276,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                child: Text(
                  context.bheText('选择球员'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: c.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _PlayerPickerOption(
                label: context.bheText('未标记'),
                icon: Icons.person_off_outlined,
                color: c.textTertiary,
                shortcut: '0',
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
                            color: _playerColor(c, id, index),
                            shortcut: playerShortcutLabel(index),
                            onTap: id == null ? null : () => onSelected(id),
                            trailing: onDelete == null || id == null
                                ? null
                                : IconButton(
                                    tooltip: '${context.bheText('删除')}$name',
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
                            context.bheText('暂无球员'),
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
                label: context.bheText('新建球员'),
                icon: Icons.add,
                color: c.orange,
                onTap: onCreate,
              ),
              _PlayerPickerOption(
                label: context.bheText('球员分组'),
                icon: Icons.groups_outlined,
                color: c.textSecondary,
                onTap: onManageGroups,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerGroupsDialog extends ConsumerWidget {
  const _PlayerGroupsDialog();

  Future<void> _saveCurrent(BuildContext context, WidgetRef ref) async {
    final players = [
      for (final player in ref.read(projectProvider).players)
        player['name'].toString(),
    ];
    final name = await showDialog<String>(
      context: context,
      builder: (_) => ReviewTextEntryDialog(
        title: context.bheText('存为分组'),
        hintText: context.bheText('例如：周六球队'),
        confirmLabel: context.bheText('保存'),
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await ref.read(playerGroupsProvider.notifier).save(name.trim(), players);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppColors.of(context);
    final groups = ref.watch(playerGroupsProvider);
    final defaultGroup = ref.watch(defaultPlayerGroupProvider);
    final hasPlayers = ref.watch(
      projectProvider.select((state) => state.players.isNotEmpty),
    );
    return AlertDialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: c.borderStrong),
      ),
      title: Text(context.bheText('球员分组')),
      content: SizedBox(
        width: 480,
        child: groups.isEmpty
            ? Text(
                context.bheText('还没有分组。把当前项目的球员存为分组后，其他项目可以一键导入。'),
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final group in groups)
                    ListTile(
                      key: ValueKey('player-group-${group.name}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(group.name),
                      subtitle: Text(
                        group.players.join('、'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textTertiary, fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey('player-group-default-${group.name}'),
                            tooltip: context.bheText(
                              defaultGroup == group.name ? '取消默认' : '设为默认',
                            ),
                            onPressed: () => ref
                                .read(playerGroupsProvider.notifier)
                                .setDefault(
                                  defaultGroup == group.name
                                      ? null
                                      : group.name,
                                ),
                            icon: Icon(
                              defaultGroup == group.name
                                  ? Icons.star
                                  : Icons.star_border,
                              size: 18,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          IconButton(
                            key: ValueKey('player-group-edit-${group.name}'),
                            tooltip: context.bheText('编辑球员分组'),
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => PlayerGroupEditor(group: group),
                            ),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            visualDensity: VisualDensity.compact,
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              unawaited(
                                ref
                                    .read(projectProvider.notifier)
                                    .importPlayers(group.players),
                              );
                            },
                            child: Text(context.bheText('导入')),
                          ),
                          IconButton(
                            tooltip: '${context.bheText('删除')}${group.name}',
                            onPressed: () => unawaited(
                              ref
                                  .read(playerGroupsProvider.notifier)
                                  .delete(group.name),
                            ),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: hasPlayers ? () => _saveCurrent(context, ref) : null,
          child: Text(context.bheText('把当前球员存为分组')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.bheText('完成')),
        ),
      ],
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
    this.shortcut,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;
  final IconData? icon;
  final Widget? trailing;
  final String? shortcut;

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
              if (shortcut != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.of(context).border),
                      borderRadius: BorderRadius.circular(CsRadius.xs),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      child: Text(
                        shortcut!,
                        style: TextStyle(
                          color: AppColors.of(context).textTertiary,
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
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

Color _playerColor(AppColors c, String? playerId, [int fallbackIndex = -1]) {
  if (playerId == null || playerId.isEmpty) return c.textTertiary;
  if (fallbackIndex >= 0) return c.player(fallbackIndex);
  final hash = playerId.codeUnits.fold<int>(
    0,
    (value, unit) => value * 31 + unit,
  );
  return c.player(hash.abs());
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
  const _CandidateCover({
    required this.future,
    required this.excluded,
    required this.durationLabel,
  });

  final Future<String?>? future;
  final bool excluded;
  final String durationLabel;

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
            width: 96,
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CsRadius.sm),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.excluded
                      ? ColorFiltered(
                          colorFilter: const ColorFilter.matrix(<double>[
                            0.2126, 0.7152, 0.0722, 0, 0,
                            0.2126, 0.7152, 0.0722, 0, 0,
                            0.2126, 0.7152, 0.0722, 0, 0,
                            0, 0, 0, 1, 0,
                          ]),
                          child: cover,
                        )
                      : cover,
                  Positioned(
                    right: 4,
                    bottom: 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: c.background.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          widget.durationLabel,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 11,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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

bool _isReviewed(Map<String, dynamic> candidate) {
  final status = candidate['review_status']?.toString() ?? '';
  return status.isNotEmpty && status != 'pending';
}

bool _isAutoExcluded(Map<String, dynamic> candidate) =>
    candidate['review_status']?.toString() == 'excluded' &&
    candidate['review_reason']?.toString() == 'auto_rim_check';

String? _rimCheckStatus(Map<String, dynamic> candidate) {
  final check = _candidateEvidence(candidate)['rim_check'];
  return check is Map ? check['status']?.toString() : null;
}

({String label, Color color})? _rimCheckDisplay(AppColors c, dynamic value) {
  if (value is! Map) return null;
  final reason = value['reason']?.toString();
  return switch (value['status']?.toString()) {
    'made' => (label: '通过：球穿过篮网落下', color: c.success),
    'rejected' => (
      label: const <String, String>{
            'no_crossing': '未通过：没有看到球穿过篮筐',
            'no_entry': '未通过：球不是从篮筐上方落下',
            'off_center': '未通过：球偏离篮筐口',
            'no_exit': '未通过：没有看到球从网底落下',
            'exit_off_center': '未通过：球从篮网侧面出来',
            'rebound': '未通过：球在篮筐附近弹起',
            'not_occluded': '未通过：球从篮筐前方掠过，没有进网',
            'net_still': '未通过：球落下时篮网没有动',
          }[reason] ??
          '未通过',
      color: c.error,
    ),
    'unsure' => (
      label: const <String, String>{
            'no_crossing': '未确认：没看清球是否穿过篮筐，请人工确认',
            'no_entry': '未确认：没看清球是否从篮筐上方落下，请人工确认',
            'no_exit': '未确认：没看清球是否从网底落下，请人工确认',
            'off_center': '未确认：球像是偏离篮筐口，但轨迹不像一颗下落的球，请人工确认',
            'not_occluded': '未确认：球全程可见，这个视频的篮网不一定挡得住球，请人工确认',
          }[reason] ??
          '未确认：请人工确认',
      color: c.warning,
    ),
    'skipped' => (
      label: reason == 'small_rim'
          ? '未复核：篮筐在画面中太小，请人工确认'
          : '未复核：请人工确认',
      color: c.warning,
    ),
    _ => null,
  };
}

bool _isExcluded(Map<String, dynamic> candidate) =>
    candidate['selection_status']?.toString() == 'excluded' ||
    candidate['review_status']?.toString() == 'excluded';

List<Map<String, dynamic>> _filterCandidates(
  List<Map<String, dynamic>> candidates,
  String filter, {
  String playerFilter = 'all',
  String rimFilter = 'all',
  String segmentFilter = 'all',
}) {
  return candidates.where((candidate) {
    if (segmentFilter != 'all' &&
        candidate['video_id']?.toString() != segmentFilter) {
      return false;
    }
    if (filter == 'included' && _isExcluded(candidate)) return false;
    if (filter == 'excluded' && !_isExcluded(candidate)) return false;
    if (rimFilter != 'all' && _rimCheckStatus(candidate) != rimFilter) {
      return false;
    }
    final id = candidate['player_id']?.toString() ?? '';
    return switch (playerFilter) {
      'tagged' => id.isNotEmpty,
      'untagged' => id.isEmpty,
      'all' => true,
      _ => playerFilter == 'player:$id',
    };
  }).toList();
}

int _candidateSegment(Map<String, dynamic> candidate) {
  final value = candidate['segment'];
  return value is num ? value.toInt() : 0;
}

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

bool _hasAdjustedRange(Map<String, dynamic> candidate) {
  return (candidate['default_start_ms'] != null &&
          _clipStart(candidate) != _number(candidate['default_start_ms']).round()) ||
      (candidate['default_end_ms'] != null &&
          _clipEnd(candidate) != _number(candidate['default_end_ms']).round());
}

Set<String> _overlappingCandidateIds(List<Map<String, dynamic>> candidates) {
  final previousByVideo = <Object?, Map<String, dynamic>>{};
  final overlapping = <String>{};
  for (final candidate in candidates) {
    if (_isExcluded(candidate)) continue;
    final source = candidate['video_id'] ?? candidate['source_path'];
    final previous = previousByVideo[source];
    if (previous != null &&
        _clipStart(candidate) < _clipEnd(previous) &&
        _clipEnd(candidate) > _clipStart(previous)) {
      overlapping.add(candidate['id'].toString());
    }
    previousByVideo[source] = candidate;
  }
  return overlapping;
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

int _videoRotation(Map<String, dynamic>? video) =>
    (video?['rotation'] as num?)?.toInt() ?? 0;

Size _videoFrameSize(Map<String, dynamic>? video) {
  final width = _number(video?['width']);
  final height = _number(video?['height']);
  if (width <= 0 || height <= 0) return const Size(16, 9);
  return Size(width, height);
}

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

/// 标签菜单里第 [index] 个球员的快捷键：1–9，然后 Q W E R T Y U I O P。
String? playerShortcutLabel(int index) {
  const letters = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'];
  if (index < 9) return '${index + 1}';
  if (index < 9 + letters.length) return letters[index - 9];
  return null;
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

/// 审核播放源：多段项目用当前段原视频；单段项目优先用引擎返回的审核视频，
/// 缺失时回退原视频。`previewPath` 是导入页的静帧截图，绝不能作为播放源。
String? resolveReviewPlaybackPath({
  required bool multiVideo,
  required String? originalVideoPath,
  required String? reviewVideoPath,
}) {
  if (multiVideo) return originalVideoPath;
  if (reviewVideoPath == null || reviewVideoPath.isEmpty) {
    return originalVideoPath;
  }
  return reviewVideoPath;
}

/// 审核页实际会播放的源。播放器和“候选预览 / 原视频”开关用它判断是否可切换，
/// 不要再用 `previewPath`(导入页静帧，多段项目导入后为 null)。
String? _reviewPlaybackPath(ProjectState state) => resolveReviewPlaybackPath(
  multiVideo: state.multiVideo,
  originalVideoPath: _resolveOriginalVideoPath(state),
  reviewVideoPath: state.reviewVideoPath,
);

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

/// checkpoint 里的推理后端 → 展示名；旧任务没有该字段时返回 null。
String? _inferenceDeviceName(Map<String, dynamic> checkpoint) {
  final raw = checkpoint['inference_device']?.toString().trim().toLowerCase();
  if (raw == null || raw.isEmpty) return null;
  return switch (raw) {
    'dml' => 'DirectML',
    'cuda' => 'CUDA',
    'coreml' => 'CoreML',
    'mps' => 'Metal',
    'cpu' => 'CPU',
    _ => raw.toUpperCase(),
  };
}

/// 这次分析是否真的跑在 GPU 上；后端未知或回落 CPU 都不算。
bool _inferenceAccelerated(Map<String, dynamic> checkpoint) {
  final raw = checkpoint['inference_device']?.toString().trim().toLowerCase();
  return raw == 'dml' || raw == 'cuda' || raw == 'coreml' || raw == 'mps';
}

String _analysisDetailLabel(
  Map<String, dynamic> checkpoint,
  BheLocalizations? l10n,
) {
  final rawTimings = checkpoint['stage_timings_ms'];
  final timings = rawTimings is Map
      ? rawTimings.cast<String, dynamic>()
      : const <String, dynamic>{};
  final parts = <String>[];
  for (final entry in const <String, String>{
    'engine_preflight': '引擎自检',
    'prepare_proxy': '代理',
    'coarse_scan': '粗扫',
    'generate_candidates': '候选',
    'refine_candidates': '精筛',
    'verify_rim_crossing': '篮筐复核',
    'prepare_review_previews': '封面',
    'persist_candidates': '落库',
  }.entries) {
    final value = timings[entry.key];
    if (value is num) {
      parts.add(
        '${l10n?.text(entry.value) ?? entry.value} ${l10n?.text(_formatSeconds(value / 1000)) ?? _formatSeconds(value / 1000)}',
      );
    }
  }
  final deviceName = _inferenceDeviceName(checkpoint);
  if (deviceName != null) {
    parts.add('${l10n?.text('推理') ?? '推理'} $deviceName');
  }
  final cacheHits = checkpoint['cache_hits'];
  if (cacheHits is num) {
    parts.add('缓存命中 ${cacheHits.toInt()}');
  }
  final result = parts.isEmpty ? '' : '分析详情：${parts.join(' · ')}';
  return l10n?.text(result) ?? result;
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
      'engine_preflight': '检查分析引擎',
      'prepare_proxy': '生成预览视频',
      'coarse_scan': '快速扫描候选',
      'generate_candidates': '生成候选',
      'refine_candidates': '精细分析候选',
      'verify_rim_crossing': '篮筐逐帧复核',
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
