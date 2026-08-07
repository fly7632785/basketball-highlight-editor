import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
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
  final Map<String, Future<String?>> _coverCache = <String, Future<String?>>{};

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
    final id = candidate['id']?.toString();
    if (id != null && id.isNotEmpty) {
      setState(() => _selectedCandidateId = id);
    }
  }

  Future<void> _setCandidateStatus(
    String id,
    String status,
    List<Map<String, dynamic>> candidates,
  ) async {
    final index = candidates.indexWhere((candidate) => candidate['id'] == id);
    await ref
        .read(projectProvider.notifier)
        .reviewCandidate(id, status);
    if (!mounted || status != 'excluded' || candidates.isEmpty) return;
    final nextIndex = (index + 1).clamp(0, candidates.length - 1).toInt();
    final nextId = candidates[nextIndex]['id']?.toString();
    if (nextId != null) setState(() => _selectedCandidateId = nextId);
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
      await ref.read(projectProvider.notifier).startAnalysis();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final candidates = _orderedCandidates(state.candidates);
    final selected = _selectedCandidate(candidates);
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
    final includedCount = candidates
        .where((candidate) => !_isExcluded(candidate))
        .length;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _moveCandidate(candidates, -1),
        SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _moveCandidate(candidates, 1),
        SingleActivator(LogicalKeyboardKey.keyX): () {
          final id = selected?['id']?.toString();
          if (id != null) {
            unawaited(_setCandidateStatus(id, 'excluded', candidates));
          }
        },
        SingleActivator(LogicalKeyboardKey.keyC): () {
          final id = selected?['id']?.toString();
          if (id != null) {
            unawaited(_setCandidateStatus(id, 'included', candidates));
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            Spacing.lg,
          ),
          child: Column(
            children: [
              if (analyzing ||
                  jobState == 'failed' ||
                  jobState == 'cancelled' ||
                  (jobState == 'running' &&
                      recoveryState == 'stale_recoverable'))
                _AnalysisBar(
                  state: jobState,
                  stage: job?['stage']?.toString() ?? '',
                  progress: progress,
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
                _CompletedLine(
                  candidateCount: candidates.length,
                  onReanalyze: state.busy ? null : _confirmReanalyze,
                ),
              const SizedBox(height: Spacing.sm),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final video = _VideoPane(
                      key: ValueKey(playbackPath ?? 'no-video'),
                      videoPath: playbackPath,
                      candidate: selected,
                      hasPrevious: _candidateIndex(candidates, selected) > 0,
                      hasNext:
                          _candidateIndex(candidates, selected) <
                          candidates.length - 1,
                      onPrevious: () => _moveCandidate(candidates, -1),
                      onNext: () => _moveCandidate(candidates, 1),
                    );
                    final queue = _CandidatePanel(
                      candidates: candidates,
                      selectedId: selected?['id']?.toString(),
                      includedCount: includedCount,
                      busy: state.busy,
                      analyzing: analyzing,
                      hasVideo: state.videoPath != null,
                      onSelect: _selectCandidate,
                      onSetStatus: (id, status) =>
                          _setCandidateStatus(id, status, candidates),
                      onLoadCover: state.video == null
                          ? null
                          : (id, timeMs) =>
                                _loadCandidateCover(notifier, id, timeMs),
                      onReanalyze: !analyzing && !state.busy
                          ? _confirmReanalyze
                          : null,
                      onGoImport: () => context.go('/import'),
                      onExport: includedCount == 0
                          ? null
                          : () => context.go('/export'),
                    );
                    if (constraints.maxWidth >= Breakpoints.md) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 7, child: video),
                          const SizedBox(width: Spacing.md),
                          SizedBox(width: 340, child: queue),
                        ],
                      );
                    }
                    return SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: Spacing.lg),
                      child: Column(
                        children: [
                          SizedBox(
                            height: (constraints.maxWidth * 0.62)
                                .clamp(300.0, 520.0)
                                .toDouble(),
                            child: video,
                          ),
                          const SizedBox(height: Spacing.md),
                          SizedBox(height: 520, child: queue),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
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
      () => notifier.loadCandidatePreview(timeMs),
    );
  }
}

class _AnalysisBar extends StatelessWidget {
  const _AnalysisBar({
    required this.state,
    required this.stage,
    required this.progress,
    required this.errorMessage,
    required this.recoverable,
    required this.onCancel,
    required this.onRetry,
    required this.onReanalyze,
  });

  final String state;
  final String stage;
  final double progress;
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
  const _CompletedLine({
    required this.candidateCount,
    required this.onReanalyze,
  });

  final int candidateCount;
  final VoidCallback? onReanalyze;

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
          const Spacer(),
          if (onReanalyze != null)
            TextButton.icon(
              onPressed: onReanalyze,
              icon: const Icon(Icons.replay, size: 15),
              label: const Text('重新分析'),
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
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
  });

  final String? videoPath;
  final Map<String, dynamic>? candidate;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

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
  int _positionMs = 0;
  int? _clipEndMs;
  int _playRequest = 0;

  @override
  void initState() {
    super.initState();
    if (widget.videoPath == null || widget.videoPath!.isEmpty) return;
    try {
      MediaKit.ensureInitialized();
      _player = Player();
      _controller = VideoController(_player!);
    } catch (error) {
      _error = error.toString();
      return;
    }
    _positionSubscription = _player!.stream.position.listen((position) {
      final end = _clipEndMs;
      if (end != null && position.inMilliseconds >= end) {
        unawaited(_player!.pause());
        if (mounted) setState(() => _clipEndMs = null);
      }
      if (mounted) {
        setState(() => _positionMs = position.inMilliseconds);
      }
    });
    unawaited(_open(widget.videoPath));
  }

  @override
  void didUpdateWidget(covariant _VideoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _ready = false;
      unawaited(_open(widget.videoPath));
    } else if (_candidateSignature(oldWidget.candidate) !=
        _candidateSignature(widget.candidate)) {
      unawaited(_playCandidate());
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _open(String? path) async {
    final player = _player;
    if (player == null || path == null || path.isEmpty) return;
    if (mounted) setState(() => _loading = true);
    try {
      await player.open(Media(Uri.file(path).toString()), play: false);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _loading = false;
        _error = null;
      });
      await _playCandidate();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _ready = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _playCandidate() async {
    final player = _player;
    final candidate = widget.candidate;
    if (player == null || !_ready || candidate == null) return;
    final start = _clipStart(candidate);
    final end = _clipEnd(candidate);
    final request = ++_playRequest;
    try {
      await player.seek(Duration(milliseconds: start));
      if (!mounted || request != _playRequest) return;
      setState(() => _clipEndMs = end);
      await player.play();
    } catch (error) {
      if (mounted && request == _playRequest) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _seek(Duration position) async {
    if (_player != null && _ready) {
      await _player!.seek(position);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final player = _player;
    final controller = _controller;
    final hasVideo = widget.videoPath != null && widget.videoPath!.isNotEmpty;

    return CsCard(
      padding: const EdgeInsets.all(Spacing.sm),
      child: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(CsRadius.md),
                border: Border.all(color: c.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: !hasVideo || controller == null || _error != null
                  ? CsEmptyState(
                      icon: _error == null
                          ? Icons.movie_outlined
                          : Icons.error_outline,
                      title: !hasVideo ? '还没有视频' : _error ?? '视频加载失败',
                      description: _error == null && hasVideo
                          ? '分析完成后会在这里播放候选片段'
                          : null,
                      action: null,
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Video(
                              controller: controller,
                              controls: NoVideoControls,
                            ),
                          ),
                        ),
                        if (_loading)
                          const ColoredBox(
                            color: Colors.black26,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          _VideoControls(
            player: player,
            positionMs: _positionMs,
            enabled: _ready && _error == null,
            hasPrevious: widget.hasPrevious,
            hasNext: widget.hasNext,
            onPrevious: widget.onPrevious,
            onNext: widget.onNext,
            onSeek: _seek,
            onReplayCandidate: _playCandidate,
          ),
          if (widget.candidate != null) ...[
            const SizedBox(height: Spacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '候选 ${_formatMs(_candidateTime(widget.candidate!))} · '
                '片段 ${_formatMs(_clipStart(widget.candidate!))} - '
                '${_formatMs(_clipEnd(widget.candidate!))}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({
    required this.player,
    required this.positionMs,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onReplayCandidate,
  });

  final Player? player;
  final int positionMs;
  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onReplayCandidate;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    if (player == null) return const SizedBox(height: 36);
    return StreamBuilder<Duration>(
      stream: player!.stream.duration,
      initialData: player!.state.duration,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final max = duration.inMilliseconds;
        final value = max <= 0 ? 0.0 : positionMs.clamp(0, max).toDouble();
        return Column(
          children: [
            Slider(
              min: 0,
              max: max > 0 ? max.toDouble() : 1,
              value: value,
              onChanged: !enabled || max <= 0
                  ? null
                  : (next) => onSeek(Duration(milliseconds: next.round())),
            ),
            Row(
              children: [
                Text(
                  '${_formatDuration(Duration(milliseconds: positionMs))} / '
                  '${_formatDuration(duration)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '上一个候选',
                  onPressed: enabled && hasPrevious ? onPrevious : null,
                  icon: const Icon(Icons.skip_previous, size: 19),
                  visualDensity: VisualDensity.compact,
                ),
                StreamBuilder<bool>(
                  stream: player!.stream.playing,
                  initialData: false,
                  builder: (context, snapshot) => IconButton(
                    tooltip: snapshot.data == true ? '暂停' : '播放',
                    onPressed: !enabled
                        ? null
                        : () => snapshot.data == true
                              ? player!.pause()
                              : player!.play(),
                    icon: Icon(
                      snapshot.data == true ? Icons.pause : Icons.play_arrow,
                      size: 22,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                IconButton(
                  tooltip: '下一个候选',
                  onPressed: enabled && hasNext ? onNext : null,
                  icon: const Icon(Icons.skip_next, size: 19),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: '重播当前片段',
                  onPressed: enabled
                      ? () => unawaited(onReplayCandidate())
                      : null,
                  icon: const Icon(Icons.replay, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _CandidatePanel extends StatelessWidget {
  const _CandidatePanel({
    required this.candidates,
    required this.selectedId,
    required this.includedCount,
    required this.busy,
    required this.analyzing,
    required this.hasVideo,
    required this.onSelect,
    required this.onSetStatus,
    required this.onLoadCover,
    required this.onReanalyze,
    required this.onGoImport,
    required this.onExport,
  });

  final List<Map<String, dynamic>> candidates;
  final String? selectedId;
  final int includedCount;
  final bool busy;
  final bool analyzing;
  final bool hasVideo;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final Future<void> Function(String, String) onSetStatus;
  final Future<String?> Function(String, int)? onLoadCover;
  final VoidCallback? onReanalyze;
  final VoidCallback onGoImport;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return CsCard(
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.sm,
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
                '$includedCount 保留 / ${candidates.length} 个',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const Spacer(),
              const Icon(Icons.schedule, size: 15),
              const SizedBox(width: 3),
              Text('按时间', style: theme.textTheme.labelSmall),
            ],
          ),
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            Row(
              children: [
                Text('默认保留', style: theme.textTheme.labelSmall),
                Text(
                  ' · 点击封面播放 · 打叉剔除',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.sm),
          Expanded(
            child: candidates.isEmpty
                ? _EmptyCandidates(
                    analyzing: analyzing,
                    hasVideo: hasVideo,
                    onReanalyze: onReanalyze,
                    onGoImport: onGoImport,
                  )
                : ListView.separated(
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.xs),
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      final id = candidate['id']?.toString() ?? '';
                      return _CandidateRow(
                        candidate: candidate,
                        index: index,
                        selected: id == selectedId,
                        excluded: _isExcluded(candidate),
                        busy: busy,
                        onTap: () => onSelect(candidate),
                        onInclude: () => unawaited(onSetStatus(id, 'included')),
                        onExclude: () => unawaited(onSetStatus(id, 'excluded')),
                        onLoadCover: onLoadCover == null
                            ? null
                            : () => onLoadCover!(id, _candidateTime(candidate)),
                      );
                    },
                  ),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Expanded(
                child: CsButton(
                  label: Text('导出 $includedCount 个保留片段'),
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
    required this.hasVideo,
    required this.onReanalyze,
    required this.onGoImport,
  });

  final bool analyzing;
  final bool hasVideo;
  final VoidCallback? onReanalyze;
  final VoidCallback onGoImport;

  @override
  Widget build(BuildContext context) {
    if (analyzing) {
      return const CsEmptyState(
        icon: Icons.hourglass_top,
        title: '正在等待候选片段',
        description: '候选会在分析过程中自动出现。',
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
    required this.onLoadCover,
  });

  final Map<String, dynamic> candidate;
  final int index;
  final bool selected;
  final bool excluded;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onInclude;
  final VoidCallback onExclude;
  final Future<String?> Function()? onLoadCover;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return CsCard(
      tier: selected ? CsCardTier.selected : CsCardTier.defaultTier,
      selectedAccent: selected,
      onTap: onTap,
      padding: const EdgeInsets.all(Spacing.xs),
      child: Row(
        children: [
          _CandidateCover(load: onLoadCover, excluded: excluded),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${index + 1}. ${_formatMs(_candidateTime(candidate))}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: excluded ? c.textTertiary : c.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  excluded ? '已排除' : '保留',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: excluded ? c.textTertiary : c.goal,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '保留片段',
            onPressed: busy ? null : onInclude,
            icon: Icon(
              Icons.check_circle,
              size: 20,
              color: excluded ? c.textTertiary : c.goal,
            ),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: '排除片段',
            onPressed: busy ? null : onExclude,
            icon: Icon(
              Icons.cancel_outlined,
              size: 20,
              color: excluded ? c.error : c.textTertiary,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _CandidateCover extends StatefulWidget {
  const _CandidateCover({required this.load, required this.excluded});

  final Future<String?> Function()? load;
  final bool excluded;

  @override
  State<_CandidateCover> createState() => _CandidateCoverState();
}

class _CandidateCoverState extends State<_CandidateCover> {
  late Future<String?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load == null ? Future.value(null) : widget.load!();
  }

  @override
  void didUpdateWidget(covariant _CandidateCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.load != widget.load) {
      _future = widget.load == null ? Future.value(null) : widget.load!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snapshot) {
        final path = snapshot.data;
        final cover = path != null && File(path).existsSync()
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
      ? <String?>[state.videoPath, state.reviewVideoPath]
      : <String?>[state.reviewVideoPath, state.videoPath];
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
    }[stage] ??
    stage;
