import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_progress_track.dart';
import '../../components/cs_status_chip.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// Review 屏:分析状态 + 视频预览(媒体播放)+ 候选审核队列。
///
/// 数据来自 [projectProvider];审核走 `ProjectNotifier.reviewCandidate`,
/// 取消/重试走 `cancelAnalysis`/`retryAnalysis`,导出跳转 `context.go('/export')`。
/// 媒体播放(Player/VideoController/位置订阅)逻辑迁移自 3700bbc,样式换 Cs* 系列。
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  int _selectedIndex = 0;
  String _statusFilter = 'all';

  List<MapEntry<int, Map<String, dynamic>>> _visibleEntries(
    List<Map<String, dynamic>> candidates,
  ) {
    return candidates.asMap().entries.where((entry) {
      return _statusFilter == 'all' ||
          entry.value['review_status']?.toString() == _statusFilter;
    }).toList();
  }

  void _moveSelection(
    List<MapEntry<int, Map<String, dynamic>>> visible,
    int delta,
  ) {
    if (visible.isEmpty) return;
    final current = visible.indexWhere((entry) => entry.key == _selectedIndex);
    final base = current < 0 ? 0 : current;
    final next = (base + delta).clamp(0, visible.length - 1).toInt();
    if (current < 0 || next != base) {
      setState(() => _selectedIndex = visible[next].key);
    }
  }

  Future<void> _reviewAndAdvance(String id, String status) async {
    final visible = _visibleEntries(ref.read(projectProvider).candidates);
    final current = visible.indexWhere((entry) => entry.key == _selectedIndex);
    final next = current >= 0 && current + 1 < visible.length
        ? visible[current + 1].key
        : null;
    await ref.read(projectProvider.notifier).reviewCandidate(id, status);
    if (!mounted || next == null) return;
    setState(() => _selectedIndex = next);
  }

  Future<void> _confirmReanalyze(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新分析当前视频？'),
        content: const Text('新的分析完成后会替换当前候选列表，已有审核结果不会带入新候选。'),
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
    if (confirmed == true) {
      await ref.read(projectProvider.notifier).startAnalysis();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final job = state.job;
    final jobState = job?['state']?.toString() ?? '';
    final progress = (job?['progress'] as num?)?.toDouble() ?? 0;
    final stage = job?['stage']?.toString() ?? '';
    final analyzing = jobState == 'queued' || jobState == 'running';

    final candidates = state.candidates;
    final visible = _visibleEntries(candidates);
    final selectedCandidate =
        (candidates.isEmpty || _selectedIndex >= candidates.length)
        ? null
        : candidates[_selectedIndex];

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _moveSelection(visible, -1),
        SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _moveSelection(visible, 1),
        SingleActivator(LogicalKeyboardKey.enter): () {
          final id = selectedCandidate?['id']?.toString();
          if (id != null) unawaited(_reviewAndAdvance(id, 'goal'));
        },
        SingleActivator(LogicalKeyboardKey.backspace): () {
          final id = selectedCandidate?['id']?.toString();
          if (id != null) unawaited(_reviewAndAdvance(id, 'excluded'));
        },
      },
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            children: [
              if (job != null &&
                  (analyzing ||
                      jobState == 'failed' ||
                      jobState == 'completed' ||
                      jobState == 'cancelled')) ...[
                _AnalysisStatusCard(
                  state: jobState,
                  stage: stage,
                  progress: progress,
                  errorMessage: job['error_message']?.toString(),
                  onCancel: analyzing ? () => notifier.cancelAnalysis() : null,
                  onRetry: jobState == 'failed' && !state.busy
                      ? () => notifier.retryAnalysis()
                      : null,
                  onReanalyze: !analyzing && !state.busy
                      ? () => _confirmReanalyze(context)
                      : null,
                ),
                const SizedBox(height: Spacing.md),
              ],
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= Breakpoints.md;
                    final preview = _PreviewPanel(
                      videoPath: state.reviewVideoPath ?? state.videoPath,
                      jobState: jobState,
                      progress: progress,
                      candidate: selectedCandidate,
                      hasPrevious:
                          visible.indexWhere(
                            (entry) => entry.key == _selectedIndex,
                          ) >
                          0,
                      hasNext:
                          visible.indexWhere(
                                (entry) => entry.key == _selectedIndex,
                              ) >=
                              0 &&
                          visible.indexWhere(
                                (entry) => entry.key == _selectedIndex,
                              ) <
                              visible.length - 1,
                      onPrevious: () => _moveSelection(visible, -1),
                      onNext: () => _moveSelection(visible, 1),
                      onCancel: () => notifier.cancelAnalysis(),
                      recoverable: job?['recoverable'] == true,
                      onRetry: state.busy
                          ? null
                          : () => notifier.retryAnalysis(),
                    );
                    final queue = _QueuePanel(
                      candidates: visible.map((entry) => entry.value).toList(),
                      candidateIndexes: visible
                          .map((entry) => entry.key)
                          .toList(),
                      selectedIndex: _selectedIndex,
                      busy: state.busy,
                      onSelected: (index) =>
                          setState(() => _selectedIndex = index),
                      filter: _statusFilter,
                      onFilterChanged: (value) {
                        setState(() {
                          _statusFilter = value;
                          final next = _visibleEntries(
                            ref.read(projectProvider).candidates,
                          );
                          _selectedIndex = next.isEmpty ? 0 : next.first.key;
                        });
                      },
                      onReview: _reviewAndAdvance,
                      onUpdateNote: notifier.updateCandidateNote,
                      onUndo: notifier.undoReview,
                      onUpdateRange: (id, start, end) =>
                          notifier.updateClipRange(id, start, end),
                      onExport: () => context.go('/export'),
                      analyzing: analyzing,
                    );
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: preview),
                          const SizedBox(width: Spacing.md),
                          SizedBox(width: 390, child: queue),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Expanded(child: preview),
                        const SizedBox(height: Spacing.md),
                        SizedBox(height: 380, child: queue),
                      ],
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
}

/// 分析状态条:sparkles/circleAlert + 标题 + 阶段+% + CsProgressTrack + 取消/重试。
class _AnalysisStatusCard extends StatelessWidget {
  const _AnalysisStatusCard({
    required this.state,
    required this.stage,
    required this.progress,
    required this.errorMessage,
    required this.onCancel,
    required this.onRetry,
    required this.onReanalyze,
  });

  final String state;
  final String stage;
  final double progress;
  final String? errorMessage;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onReanalyze;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final failed = state == 'failed';
    final value = progress.clamp(0.0, 1.0).toDouble();
    final accent = failed ? c.error : c.indigo;

    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(CsRadius.lg),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.md,
          Spacing.md,
          Spacing.sm,
          Spacing.md,
        ),
        child: Row(
          children: [
            Icon(
              failed ? LucideIcons.circleAlert : LucideIcons.sparkles,
              color: accent,
              size: 22,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    failed
                        ? '分析失败'
                        : state == 'completed'
                        ? '分析已完成'
                        : state == 'cancelled'
                        ? '分析已取消'
                        : '正在分析视频',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    failed
                        ? (errorMessage ?? '请检查视频、ROI 和本地运行时后重试')
                        : state == 'completed'
                        ? '候选片段已生成，可继续审核或重新分析'
                        : state == 'cancelled'
                        ? '可以保留现有候选，或重新分析当前视频'
                        : '${_stageLabel(stage)} · ${(value * 100).round()}%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (!failed &&
                      state != 'completed' &&
                      state != 'cancelled') ...[
                    const SizedBox(height: Spacing.sm),
                    CsProgressTrack(value: value),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Wrap(
              spacing: Spacing.xs,
              children: [
                if (onCancel != null)
                  CsButton(
                    label: const Text('取消'),
                    icon: LucideIcons.circleStop,
                    variant: CsButtonVariant.secondary,
                    size: CsButtonSize.sm,
                    onPressed: onCancel,
                  ),
                if (onRetry != null)
                  CsButton(
                    label: const Text('重试'),
                    icon: LucideIcons.refreshCw,
                    size: CsButtonSize.sm,
                    onPressed: onRetry,
                  ),
                if (onReanalyze != null)
                  CsButton(
                    label: const Text('重新分析'),
                    icon: LucideIcons.rotateCcw,
                    variant: CsButtonVariant.secondary,
                    size: CsButtonSize.sm,
                    onPressed: onReanalyze,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 预览面板:视频容器 + 播放控制 + 候选信息。
/// 媒体播放逻辑(Player/Controller/订阅/_playClip/_seekToCandidate)迁移自 3700bbc,原样不动。
class _PreviewPanel extends StatefulWidget {
  const _PreviewPanel({
    required this.videoPath,
    required this.jobState,
    required this.progress,
    required this.candidate,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onCancel,
    required this.recoverable,
    required this.onRetry,
  });

  final String? videoPath;
  final String jobState;
  final double progress;
  final Map<String, dynamic>? candidate;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onCancel;
  final bool recoverable;
  final VoidCallback? onRetry;

  @override
  State<_PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<_PreviewPanel> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  Duration? _clipEnd;
  String? _playerError;
  bool _clipPlaying = false;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
    unawaited(_loadVideo(widget.videoPath));
  }

  @override
  void didUpdateWidget(covariant _PreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _initializePlayer();
      unawaited(_loadVideo(widget.videoPath));
    } else if (_candidateTime(oldWidget.candidate) !=
        _candidateTime(widget.candidate)) {
      unawaited(_seekToCandidate(widget.candidate));
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  void _initializePlayer() {
    if (widget.videoPath == null ||
        widget.videoPath!.isEmpty ||
        _player != null) {
      return;
    }
    try {
      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      _controller = VideoController(player);
      _positionSubscription = player.stream.position.listen((position) {
        final clipEnd = _clipEnd;
        if (clipEnd != null && position >= clipEnd) {
          unawaited(player.pause());
          if (mounted) {
            setState(() {
              _clipEnd = null;
              _clipPlaying = false;
            });
          }
        }
      });
    } catch (error) {
      _playerError = error.toString();
    }
  }

  Future<void> _loadVideo(String? path) async {
    final player = _player;
    if (path == null || path.isEmpty || player == null) return;
    try {
      await player.open(Media(Uri.file(path).toString()), play: false);
      await _seekToCandidate(widget.candidate);
      if (mounted) setState(() => _playerError = null);
    } catch (error) {
      if (mounted) setState(() => _playerError = error.toString());
    }
  }

  Future<void> _seekToCandidate(Map<String, dynamic>? candidate) async {
    final player = _player;
    final timeMs = _candidateTime(candidate);
    if (timeMs == null || player == null) return;
    await player.seek(Duration(milliseconds: timeMs));
  }

  Future<void> _togglePlayback(bool playing) async {
    final player = _player;
    if (player == null) return;
    if (playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _playClip() async {
    final candidate = widget.candidate;
    if (candidate == null) return;
    final start = _clipStart(candidate);
    final end = _clipEndFor(candidate);
    final player = _player;
    if (player == null) return;
    await player.seek(Duration(milliseconds: start));
    setState(() {
      _clipEnd = Duration(milliseconds: end);
      _clipPlaying = true;
    });
    await player.play();
  }

  Future<void> _seek(Duration position) async {
    final player = _player;
    if (player != null) await player.seek(position);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final analyzing =
        widget.jobState == 'queued' || widget.jobState == 'running';
    final hasVideo = widget.videoPath != null && widget.videoPath!.isNotEmpty;
    final player = _player;
    final controller = _controller;

    return CsCard(
      tier: CsCardTier.defaultTier,
      child: Column(
        children: [
          // 恢复提示条
          if (widget.recoverable) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
              decoration: BoxDecoration(
                color: c.warning.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(CsRadius.md),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.triangleAlert, size: 18, color: c.warning),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      '上次分析没有完成，可以从头重试。已有候选和审核记录会保留。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  if (widget.onRetry != null)
                    CsButton(
                      label: const Text('重试分析'),
                      icon: LucideIcons.refreshCw,
                      variant: CsButtonVariant.ghost,
                      size: CsButtonSize.sm,
                      onPressed: widget.onRetry,
                    ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.sm),
          ],

          // 视频容器 / 空态
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF080B0E),
                borderRadius: BorderRadius.circular(CsRadius.lg),
                border: Border.all(color: c.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasVideo && controller != null && _playerError == null
                  ? ExcludeSemantics(child: Video(controller: controller))
                  : CsEmptyState(
                      icon: _playerError != null
                          ? LucideIcons.circleAlert
                          : LucideIcons.film,
                      title: widget.videoPath == null
                          ? '尚未导入视频'
                          : analyzing
                          ? '正在分析视频'
                          : '视频加载失败',
                      description:
                          _playerError ?? (analyzing ? '分析完成后可在此预览候选片段' : null),
                      action: analyzing
                          ? CsButton(
                              label: const Text('取消分析'),
                              icon: LucideIcons.circleStop,
                              variant: CsButtonVariant.secondary,
                              size: CsButtonSize.sm,
                              onPressed: widget.onCancel,
                            )
                          : null,
                    ),
            ),
          ),
          const SizedBox(height: Spacing.sm),

          // 播放控制
          _PlayerControls(
            player: player,
            enabled: hasVideo && player != null && _playerError == null,
            hasPrevious: widget.hasPrevious,
            hasNext: widget.hasNext,
            onPrevious: widget.onPrevious,
            onNext: widget.onNext,
            onSeek: _seek,
            onTogglePlayback: _togglePlayback,
            onPlayClip: widget.candidate == null ? null : _playClip,
            clipPlaying: _clipPlaying,
          ),

          // 候选信息行
          if (widget.candidate != null) ...[
            const SizedBox(height: Spacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '候选 ${_formatMs(_candidateTime(widget.candidate) ?? 0)} · '
                '片段 ${_formatMs(_clipStart(widget.candidate!))} - '
                '${_formatMs(_clipEndFor(widget.candidate!))}',
                style: theme.textTheme.labelSmall?.copyWith(
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

/// 三段播放控制:Slider + Row[时间码, 上一/播放/下一, Spacer, 片段操作]。
class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.player,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onTogglePlayback,
    required this.onPlayClip,
    required this.clipPlaying,
  });

  final Player? player;
  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function(bool) onTogglePlayback;
  final Future<void> Function()? onPlayClip;
  final bool clipPlaying;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final timeStyle = theme.textTheme.labelLarge?.copyWith(
      color: c.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    if (player == null) {
      return Column(
        children: [
          Slider(min: 0, max: 1, value: 0, onChanged: null),
          Row(
            children: [
              Text(_formatDuration(Duration.zero), style: timeStyle),
              Text(' / ', style: timeStyle),
              Text(_formatDuration(Duration.zero), style: timeStyle),
              const SizedBox(width: Spacing.sm),
              _NavButton(
                icon: LucideIcons.skipBack,
                tooltip: '上一候选',
                onPressed: null,
              ),
              _NavButton(
                icon: LucideIcons.play,
                tooltip: '播放',
                onPressed: null,
              ),
              _NavButton(
                icon: LucideIcons.skipForward,
                tooltip: '下一候选',
                onPressed: null,
              ),
              const Spacer(),
              CsButton(
                label: const Text('播放候选片段'),
                icon: LucideIcons.film,
                variant: CsButtonVariant.secondary,
                size: CsButtonSize.sm,
                onPressed: null,
              ),
            ],
          ),
        ],
      );
    }

    return StreamBuilder<Duration>(
      stream: player!.stream.duration,
      initialData: Duration.zero,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player!.stream.position,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final value = maxMs <= 0
                ? 0.0
                : position.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble();
            return Column(
              children: [
                Slider(
                  min: 0,
                  max: maxMs > 0 ? maxMs : 1,
                  value: value,
                  onChanged: !enabled || maxMs <= 0
                      ? null
                      : (v) => onSeek(Duration(milliseconds: v.round())),
                ),
                Row(
                  children: [
                    Text(_formatDuration(position), style: timeStyle),
                    Text(' / ', style: timeStyle),
                    Text(_formatDuration(duration), style: timeStyle),
                    const SizedBox(width: Spacing.sm),
                    _NavButton(
                      icon: LucideIcons.skipBack,
                      tooltip: '上一候选',
                      onPressed: enabled && hasPrevious ? onPrevious : null,
                    ),
                    StreamBuilder<bool>(
                      stream: player!.stream.playing,
                      initialData: false,
                      builder: (context, playingSnapshot) {
                        final playing = playingSnapshot.data ?? false;
                        return _NavButton(
                          icon: playing ? LucideIcons.pause : LucideIcons.play,
                          tooltip: playing ? '暂停' : '播放',
                          onPressed: enabled
                              ? () => onTogglePlayback(playing)
                              : null,
                        );
                      },
                    ),
                    _NavButton(
                      icon: LucideIcons.skipForward,
                      tooltip: '下一候选',
                      onPressed: enabled && hasNext ? onNext : null,
                    ),
                    const Spacer(),
                    CsButton(
                      label: Text(clipPlaying ? '播放中' : '播放候选片段'),
                      icon: clipPlaying ? LucideIcons.square : LucideIcons.film,
                      variant: CsButtonVariant.secondary,
                      size: CsButtonSize.sm,
                      onPressed: enabled && onPlayClip != null
                          ? () => unawaited(onPlayClip!())
                          : null,
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 36×36 导航按钮(上一/播放/下一)。
class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 20,
              color: enabled ? c.textPrimary : c.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 候选审核队列。
class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.candidates,
    required this.candidateIndexes,
    required this.selectedIndex,
    required this.busy,
    required this.onSelected,
    required this.filter,
    required this.onFilterChanged,
    required this.onReview,
    required this.onUpdateNote,
    required this.onUndo,
    required this.onUpdateRange,
    required this.onExport,
    required this.analyzing,
  });

  final List<Map<String, dynamic>> candidates;
  final List<int> candidateIndexes;
  final int selectedIndex;
  final bool busy;
  final ValueChanged<int> onSelected;
  final String filter;
  final ValueChanged<String> onFilterChanged;
  final Future<void> Function(String, String) onReview;
  final Future<void> Function(String, String) onUpdateNote;
  final Future<void> Function() onUndo;
  final Future<void> Function(String, int, int) onUpdateRange;
  final VoidCallback onExport;
  final bool analyzing;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final pending = candidates
        .where((item) => item['review_status'] == 'pending')
        .length;
    final hasGoal = candidates.any((item) => item['review_status'] == 'goal');

    return CsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              Text('候选审核', style: theme.textTheme.titleLarge),
              DropdownButton<String>(
                value: filter,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('全部')),
                  DropdownMenuItem(value: 'pending', child: Text('待审核')),
                  DropdownMenuItem(value: 'goal', child: Text('已确认')),
                  DropdownMenuItem(value: 'excluded', child: Text('已排除')),
                ],
                onChanged: (value) {
                  if (value != null) onFilterChanged(value);
                },
              ),
              CsStatusChip(status: ReviewStatus.pending, compact: true),
              Text(
                '$pending 待审核',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              TextButton.icon(
                onPressed: busy ? null : onUndo,
                icon: const Icon(Icons.undo, size: 16),
                label: const Text('撤销上一步'),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Expanded(
            child: candidates.isEmpty
                ? CsEmptyState(
                    icon: LucideIcons.inbox,
                    title: '没有候选片段',
                    description: analyzing
                        ? '分析进行中，候选片段会自动出现在这里。'
                        : '分析完成后，疑似进球会出现在这里。',
                  )
                : ListView.separated(
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.xs),
                    itemBuilder: (context, index) {
                      final item = candidates[index];
                      final actualIndex = candidateIndexes[index];
                      final selected = actualIndex == selectedIndex;
                      final status =
                          item['review_status']?.toString() ?? 'pending';
                      final id = item['id']?.toString() ?? '';
                      final time =
                          (item['event_time_ms'] as num?)?.toInt() ?? 0;
                      return _CandidateTile(
                        index: index,
                        time: time,
                        status: status,
                        selected: selected,
                        busy: busy,
                        onTap: () => onSelected(actualIndex),
                        onReview: (s) => onReview(id, s),
                        onEditRange: () =>
                            _editRange(context, item, onUpdateRange),
                        onEditNote: () =>
                            _editNote(context, item, onUpdateNote),
                      );
                    },
                  ),
          ),
          const SizedBox(height: Spacing.md),
          SizedBox(
            width: double.infinity,
            child: CsButton(
              label: const Text('去导出'),
              icon: LucideIcons.arrowUpRight,
              onPressed: hasGoal ? onExport : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 候选项 tile:#N + 时间 + 状态 chip + 进球/排除按钮 + 调整范围。
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.index,
    required this.time,
    required this.status,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onReview,
    required this.onEditRange,
    required this.onEditNote,
  });

  final int index;
  final int time;
  final String status;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final Future<void> Function(String) onReview;
  final VoidCallback onEditRange;
  final VoidCallback onEditNote;

  ReviewStatus get _reviewStatus => switch (status) {
    'goal' => ReviewStatus.goal,
    'excluded' => ReviewStatus.excluded,
    _ => ReviewStatus.pending,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final tnum = theme.textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return CsCard(
      tier: selected ? CsCardTier.selected : CsCardTier.defaultTier,
      selectedAccent: selected,
      onTap: onTap,
      padding: const EdgeInsets.all(Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#${index + 1}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                _formatMs(time),
                style: tnum?.copyWith(color: c.textSecondary),
              ),
              const Spacer(),
              CsStatusChip(status: _reviewStatus, compact: true),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Expanded(
                child: CsButton(
                  label: const Text('进球'),
                  icon: LucideIcons.check,
                  size: CsButtonSize.sm,
                  onPressed: busy ? null : () => onReview('goal'),
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: CsButton(
                  label: const Text('排除'),
                  icon: LucideIcons.ban,
                  variant: CsButtonVariant.secondary,
                  size: CsButtonSize.sm,
                  onPressed: busy ? null : () => onReview('excluded'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Expanded(
                child: CsButton(
                  label: const Text('编辑片段'),
                  icon: LucideIcons.slidersHorizontal,
                  variant: CsButtonVariant.ghost,
                  size: CsButtonSize.sm,
                  onPressed: busy ? null : onEditRange,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: CsButton(
                  label: const Text('备注'),
                  icon: LucideIcons.notebookPen,
                  variant: CsButtonVariant.ghost,
                  size: CsButtonSize.sm,
                  onPressed: busy ? null : onEditNote,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 调整片段范围对话框(保留校验 e > s)。
Future<void> _editRange(
  BuildContext context,
  Map<String, dynamic> item,
  Future<void> Function(String, int, int) save,
) async {
  final start = TextEditingController(
    text: '${item['review_start_ms'] ?? item['default_start_ms'] ?? 0}',
  );
  final end = TextEditingController(
    text: '${item['review_end_ms'] ?? item['default_end_ms'] ?? 0}',
  );
  final result = await showDialog<List<int>>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('调整片段范围（毫秒）'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: start,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '开始'),
          ),
          TextField(
            controller: end,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '结束'),
          ),
        ],
      ),
      actions: [
        CsButton(
          label: const Text('取消'),
          variant: CsButtonVariant.ghost,
          size: CsButtonSize.sm,
          onPressed: () => Navigator.pop(context),
        ),
        CsButton(
          label: const Text('保存'),
          size: CsButtonSize.sm,
          onPressed: () {
            final s = int.tryParse(start.text);
            final e = int.tryParse(end.text);
            if (s != null && e != null && e > s) {
              Navigator.pop(context, [s, e]);
            }
          },
        ),
      ],
    ),
  );
  if (result != null) {
    await save(item['id'].toString(), result[0], result[1]);
  }
}

Future<void> _editNote(
  BuildContext context,
  Map<String, dynamic> item,
  Future<void> Function(String, String) save,
) async {
  final note = TextEditingController(text: item['note']?.toString() ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('添加审核备注'),
      content: TextField(
        controller: note,
        autofocus: true,
        maxLines: 4,
        decoration: const InputDecoration(
          hintText: '例如：补篮进球、网明显下坠',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        CsButton(
          label: const Text('取消'),
          variant: CsButtonVariant.ghost,
          size: CsButtonSize.sm,
          onPressed: () => Navigator.pop(context),
        ),
        CsButton(
          label: const Text('保存备注'),
          size: CsButtonSize.sm,
          onPressed: () => Navigator.pop(context, note.text.trim()),
        ),
      ],
    ),
  );
  if (result != null) await save(item['id'].toString(), result);
}

int? _candidateTime(Map<String, dynamic>? candidate) {
  final value = candidate?['event_time_ms'];
  return value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
}

int _clipStart(Map<String, dynamic> candidate) {
  final value = candidate['review_start_ms'] ?? candidate['default_start_ms'];
  return value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;
}

int _clipEndFor(Map<String, dynamic> candidate) {
  final value = candidate['review_end_ms'] ?? candidate['default_end_ms'];
  return value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ??
            ((_candidateTime(candidate) ?? 0) + 3000);
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String _formatMs(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final minutes = seconds ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _stageLabel(String stage) {
  const labels = <String, String>{
    'validate_input': '检查视频输入',
    'prepare_proxy': '生成低清代理',
    'coarse_scan': '快速扫描候选',
    'refine_candidates': '精细分析候选',
    'persist_candidates': '整理审核片段',
    'analysis': '分析视频',
  };
  return labels[stage] ?? (stage.isEmpty ? '准备中' : stage);
}
