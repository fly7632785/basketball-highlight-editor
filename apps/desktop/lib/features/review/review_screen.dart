import 'dart:async';
import 'dart:io';

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
import 'batch_review_helpers.dart';
import 'clip_timeline.dart';
import 'review_helpers.dart';
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
  String _sortMode = 'recommended';
  Set<String> _selectedCandidateIds = <String>{};
  bool _batchBusy = false;

  List<MapEntry<int, Map<String, dynamic>>> _visibleEntries(
    List<Map<String, dynamic>> candidates,
  ) {
    return reviewQueueEntries(
      candidates,
      filter: _statusFilter,
      sort: _sortMode,
    );
  }

  void _scheduleStartReview(Map<String, dynamic>? candidate) {
    if (candidate == null ||
        candidate['review_status']?.toString() != 'pending') {
      return;
    }
    final id = candidate['id']?.toString();
    if (id == null || id.isEmpty) return;
    if (candidate['review_duration_ms'] != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(projectProvider.notifier).startReview(id));
    });
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

  Future<void> _reviewAndAdvance(
    String id,
    String status, {
    String? reason,
  }) async {
    final visible = _visibleEntries(ref.read(projectProvider).candidates);
    final current = visible.indexWhere((entry) => entry.key == _selectedIndex);
    final next = current >= 0 && current + 1 < visible.length
        ? visible[current + 1].key
        : null;
    final previous = current > 0 ? visible[current - 1].key : null;
    final succeeded = await ref
        .read(projectProvider.notifier)
        .reviewCandidate(id, status, reason: reason);
    if (!succeeded || !mounted) return;
    if (next != null) {
      setState(() => _selectedIndex = next);
    } else if (_statusFilter == 'pending' && previous != null) {
      setState(() => _selectedIndex = previous);
    }
  }

  Future<void> _reviewWithReason(String id, String status) async {
    final reason = await _selectReviewReason(context, status);
    if (reason == null || !mounted) return;
    await _reviewAndAdvance(id, status, reason: reason);
  }

  Future<void> _showReviewHistory(String candidateId) async {
    try {
      final history = await ref
          .read(projectProvider.notifier)
          .loadReviewHistory(candidateId);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final size = MediaQuery.sizeOf(dialogContext);
          final maxWidth = (size.width - 48).clamp(0.0, 420.0).toDouble();
          final maxHeight = (size.height * 0.6).clamp(180.0, 520.0).toDouble();
          return AlertDialog(
            title: const Text('审核历史'),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
              ),
              child: history.isEmpty
                  ? const Text('暂无审核记录')
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: history.length,
                      separatorBuilder: (_, _) => const Divider(height: 16),
                      itemBuilder: (_, index) {
                        final item = history[index];
                        final status = item['status']?.toString() ?? 'unknown';
                        final reason = item['reason']?.toString();
                        final note = item['note']?.toString();
                        final duration = reviewDurationMs(item);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_reviewStatusLabel(status)}${reason == null ? '' : ' · ${reviewReasonLabels[reason] ?? reason}'}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(
                                dialogContext,
                              ).textTheme.titleSmall,
                            ),
                            if (note != null && note.isNotEmpty)
                              Text(
                                note,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            const SizedBox(height: Spacing.xs),
                            Text(
                              '${formatReviewTimestamp(item['reviewed_at'])} · 耗时 ${formatReviewDuration(duration)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(
                                dialogContext,
                              ).textTheme.labelSmall,
                            ),
                          ],
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('读取审核历史失败：$error')));
    }
  }

  Future<void> _reviewSelected(String status) async {
    if (_batchBusy) return;
    final candidates = ref.read(projectProvider).candidates;
    final ids = visibleSelectedCandidateIds(
      candidates,
      _selectedCandidateIds,
      filter: _statusFilter,
      sort: _sortMode,
    );
    if (ids.isEmpty) return;

    setState(() => _batchBusy = true);
    final failedIds = <String>{};
    var succeededCount = 0;
    try {
      String? reason;
      if (status != 'goal') {
        reason = await _selectReviewReason(context, status);
        if (reason == null || !mounted) return;
      }
      for (final id in ids) {
        try {
          final succeeded = await ref
              .read(projectProvider.notifier)
              .reviewCandidate(id, status, reason: reason);
          if (succeeded) {
            succeededCount++;
          } else {
            failedIds.add(id);
          }
        } catch (_) {
          failedIds.add(id);
        }
      }
      if (!mounted) return;
      final visible = _visibleEntries(ref.read(projectProvider).candidates);
      setState(() {
        _selectedCandidateIds = failedIds;
        if (visible.isNotEmpty &&
            !visible.any((entry) => entry.key == _selectedIndex)) {
          _selectedIndex = visible.first.key;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '批量审核完成：已成功 $succeededCount 个，失败 ${failedIds.length} 个',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
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
    final queueBusy = state.busy || _batchBusy;
    final playbackPath = _resolvePlaybackPath(state, analyzing: analyzing);

    final candidates = state.candidates;
    final visible = _visibleEntries(candidates);
    final reviewStats = buildReviewStats(candidates, state.statistics);
    final visibleSelectedIds = visibleSelectedCandidateIds(
      candidates,
      _selectedCandidateIds,
      filter: _statusFilter,
      sort: _sortMode,
    ).toSet();
    Map<String, dynamic>? selectedCandidate;
    for (final entry in visible) {
      if (entry.key == _selectedIndex) {
        selectedCandidate = entry.value;
        break;
      }
    }
    _scheduleStartReview(selectedCandidate);

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
          if (id != null) unawaited(_reviewWithReason(id, 'excluded'));
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
              if (job != null &&
                  (analyzing ||
                      jobState == 'failed' ||
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
                const SizedBox(height: Spacing.sm),
              ],
              if (jobState == 'completed') ...[
                _CompletedStatusBar(
                  onReanalyze: !state.busy
                      ? () => _confirmReanalyze(context)
                      : null,
                ),
                const SizedBox(height: Spacing.xs),
              ],
              _ReviewStatsCard(stats: reviewStats),
              const SizedBox(height: Spacing.xs),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= Breakpoints.md;
                    final preview = _PreviewPanel(
                      videoPath: playbackPath,
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
                      recoverable: job?['recoverable'] == true && !analyzing,
                      onRetry: state.busy
                          ? null
                          : () => notifier.retryAnalysis(),
                      onUpdateRange: (id, start, end) =>
                          notifier.updateClipRange(id, start, end),
                    );
                    final queue = _QueuePanel(
                      candidates: visible.map((entry) => entry.value).toList(),
                      candidateIndexes: visible
                          .map((entry) => entry.key)
                          .toList(),
                      selectedIndex: _selectedIndex,
                      busy: queueBusy,
                      selectedCandidateIds: visibleSelectedIds,
                      onSelected: (index) =>
                          setState(() => _selectedIndex = index),
                      onToggleSelection: (id) {
                        setState(() {
                          _selectedCandidateIds = toggleReviewSelection(
                            _selectedCandidateIds,
                            id,
                          );
                        });
                      },
                      filter: _statusFilter,
                      onFilterChanged: (value) {
                        setState(() {
                          _statusFilter = value;
                          _selectedCandidateIds = <String>{};
                          final next = _visibleEntries(
                            ref.read(projectProvider).candidates,
                          );
                          _selectedIndex = next.isEmpty ? 0 : next.first.key;
                        });
                      },
                      onReview: (id, status) => status == 'goal'
                          ? _reviewAndAdvance(id, status)
                          : _reviewWithReason(id, status),
                      onShowHistory: _showReviewHistory,
                      onUpdateNote: notifier.updateCandidateNote,
                      onUndo: notifier.undoReview,
                      onUpdateRange: (id, start, end) =>
                          notifier.updateClipRange(id, start, end),
                      hasVideo: state.videoPath != null,
                      onGoImport: () => context.go('/import'),
                      onReanalyze: !analyzing && !state.busy
                          ? () => _confirmReanalyze(context)
                          : null,
                      onExport: () => context.go('/export'),
                      analyzing: analyzing,
                      onBatchReview: _reviewSelected,
                      batchBusy: _batchBusy,
                      sort: _sortMode,
                      onSortChanged: (value) {
                        setState(() {
                          _sortMode = value;
                          _selectedCandidateIds = <String>{};
                          final next = _visibleEntries(
                            ref.read(projectProvider).candidates,
                          );
                          _selectedIndex = next.isEmpty ? 0 : next.first.key;
                        });
                      },
                    );
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: preview),
                          const SizedBox(width: Spacing.md),
                          SizedBox(width: 300, child: queue),
                        ],
                      );
                    }
                    final previewHeight = (constraints.maxWidth * 0.68 + 240)
                        .clamp(480.0, 680.0)
                        .toDouble();
                    final queueHeight = candidates.isEmpty ? 500.0 : 640.0;
                    return SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: Spacing.lg),
                      child: Column(
                        children: [
                          SizedBox(height: previewHeight, child: preview),
                          const SizedBox(height: Spacing.md),
                          SizedBox(height: queueHeight, child: queue),
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
}

/// 紧凑分析状态条:把阶段和进度压在一行，避免挤占审核视频高度。
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
    final active = state == 'queued' || state == 'running';
    final title = failed
        ? '分析失败'
        : state == 'cancelled'
        ? '分析已取消'
        : '正在分析视频';
    final detail = failed
        ? (errorMessage ?? '请检查视频、ROI 和本地运行时后重试')
        : state == 'cancelled'
        ? '可以保留现有候选，或重新分析当前视频'
        : '${_stageLabel(stage)} · ${(value * 100).round()}%';

    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(CsRadius.lg),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              failed ? LucideIcons.circleAlert : LucideIcons.sparkles,
              color: accent,
              size: 18,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(title, style: theme.textTheme.labelLarge),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: c.textSecondary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (active) ...[
                    const SizedBox(height: Spacing.xs),
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

class _CompletedStatusBar extends StatelessWidget {
  const _CompletedStatusBar({required this.onReanalyze});

  final VoidCallback? onReanalyze;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.circleCheck, size: 16, color: c.goal),
          const SizedBox(width: Spacing.xs),
          Text(
            '分析完成',
            style: theme.textTheme.labelMedium?.copyWith(
              color: c.textSecondary,
            ),
          ),
          const Spacer(),
          if (onReanalyze != null)
            IconButton(
              tooltip: '重新分析当前视频',
              visualDensity: VisualDensity.compact,
              onPressed: onReanalyze,
              icon: Icon(
                LucideIcons.rotateCcw,
                size: 16,
                color: c.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

class _ReviewStatsCard extends StatelessWidget {
  const _ReviewStatsCard({required this.stats});

  final ReviewStats stats;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return CsCard(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: Spacing.xs),
          visualDensity: VisualDensity.compact,
          title: Row(
            children: [
              Text('审核', style: theme.textTheme.labelMedium),
              const SizedBox(width: Spacing.md),
              _InlineReviewMetric(
                label: '候选',
                value: '${stats.candidateCount}',
              ),
              _InlineReviewMetric(label: '待审', value: '${stats.pendingCount}'),
              _InlineReviewMetric(
                label: '确认',
                value: '${stats.goalCount}',
                color: c.goal,
              ),
              _InlineReviewMetric(
                label: '排除',
                value: '${stats.excludedCount}',
                color: c.textSecondary,
              ),
            ],
          ),
          children: [
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              children: [
                _ReviewStatTile(
                  width: 150,
                  icon: Icons.task_alt,
                  label: '确认率',
                  value: stats.confirmationRate == null
                      ? '—'
                      : '${(stats.confirmationRate! * 100).round()}%',
                ),
                _ReviewStatTile(
                  width: 150,
                  icon: Icons.warning_amber,
                  label: '证据冲突',
                  value: '${stats.conflictCount}',
                ),
                _ReviewStatTile(
                  width: 150,
                  icon: Icons.timer_outlined,
                  label: '平均审核耗时',
                  value: formatReviewDuration(stats.averageReviewDurationMs),
                ),
                if (stats.reasonDistribution.isNotEmpty)
                  ...stats.reasonDistribution.entries.map((entry) {
                    final label = reviewReasonLabels[entry.key] ?? entry.key;
                    return Chip(
                      label: Text('$label ${entry.value}'),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    );
                  }),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineReviewMetric extends StatelessWidget {
  const _InlineReviewMetric({
    required this.label,
    required this.value,
    this.color,
  });

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: Spacing.md),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.labelSmall?.copyWith(color: c.textSecondary),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: TextStyle(
                color: color ?? c.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewStatTile extends StatelessWidget {
  const _ReviewStatTile({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(CsRadius.md),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: c.textTertiary),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
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
    required this.onUpdateRange,
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
  final Future<void> Function(String, int, int) onUpdateRange;

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
  bool _loopClip = false;
  int _positionMs = 0;
  ClipRange? _draftRange;
  Future<void>? _rangeSaveFuture;
  String? _pendingRangeCandidateId;
  ClipRange? _pendingRange;
  bool _loadingVideo = false;
  bool _videoReady = false;
  int _loadRequest = 0;
  int _seekRequest = 0;
  int _clipRequest = 0;
  Future<void> _seekQueue = Future<void>.value();

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
      _videoReady = false;
      _draftRange = null;
      _loopClip = false;
      _resetClipPlayback();
      _initializePlayer();
      unawaited(_loadVideo(widget.videoPath));
    } else if (_candidateSignature(oldWidget.candidate) !=
        _candidateSignature(widget.candidate)) {
      _draftRange = null;
      _loopClip = false;
      _resetClipPlayback();
      _seekToCandidate(widget.candidate);
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
          if (_loopClip && widget.candidate != null) {
            final range =
                _draftRange ??
                ClipRange(
                  _clipStart(widget.candidate!),
                  _clipEndFor(widget.candidate!),
                );
            unawaited(player.seek(Duration(milliseconds: range.startMs)));
            unawaited(player.play());
          } else {
            unawaited(player.pause());
            if (mounted) {
              setState(() {
                _clipEnd = null;
                _clipPlaying = false;
              });
            }
          }
        }
        if (mounted) setState(() => _positionMs = position.inMilliseconds);
      });
    } catch (error) {
      _playerError = error.toString();
    }
  }

  Future<void> _loadVideo(String? path) async {
    final request = ++_loadRequest;
    final player = _player;
    if (path == null || path.isEmpty || player == null) return;
    if (mounted) {
      setState(() {
        _loadingVideo = true;
        _videoReady = false;
        _playerError = null;
      });
    }
    try {
      await player.open(Media(Uri.file(path).toString()), play: false);
      if (!mounted || request != _loadRequest) return;
      _videoReady = true;
      _seekToCandidate(widget.candidate);
      if (mounted) {
        setState(() {
          _loadingVideo = false;
          _playerError = null;
        });
      }
    } catch (error) {
      if (mounted && request == _loadRequest) {
        setState(() {
          _loadingVideo = false;
          _videoReady = false;
          _playerError = error.toString();
        });
      }
    }
  }

  void _seekToCandidate(Map<String, dynamic>? candidate) {
    final request = ++_seekRequest;
    // 选中候选时先从片段开头开始看，进球检测点由时间轴上的橙色标记表示。
    final timeMs = candidate == null ? null : _clipStart(candidate);
    if (timeMs == null || _player == null || !_videoReady) return;
    final previous = _seekQueue;
    _seekQueue = () async {
      try {
        await previous;
      } catch (_) {
        // A failed seek must not block a later candidate selection.
      }
      if (!mounted || request != _seekRequest || !_videoReady) return;
      final player = _player;
      if (player == null) return;
      try {
        await player.seek(Duration(milliseconds: timeMs));
      } catch (_) {
        // The native player may be transitioning between media states.
      }
    }();
  }

  void _resetClipPlayback() {
    _clipRequest++;
    _clipEnd = null;
    _clipPlaying = false;
    unawaited(_player?.pause());
  }

  Future<void> _togglePlayback(bool playing) async {
    final player = _player;
    if (player == null || !_videoReady) return;
    try {
      if (playing) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (_) {
      // Ignore a click while the native player is opening the media.
    }
  }

  Future<void> _playClip() async {
    final candidate = widget.candidate;
    if (candidate == null) return;
    final range = _currentRange(candidate);
    final start = range.startMs;
    final end = range.endMs;
    final player = _player;
    if (player == null || !_videoReady || end <= start) return;
    final request = ++_clipRequest;
    try {
      await player.seek(Duration(milliseconds: start));
    } catch (_) {
      return;
    }
    if (!mounted || request != _clipRequest) return;
    setState(() {
      _clipEnd = Duration(milliseconds: end);
      _clipPlaying = true;
    });
    try {
      await player.play();
    } catch (_) {
      if (mounted && request == _clipRequest) {
        setState(() {
          _clipEnd = null;
          _clipPlaying = false;
        });
      }
    }
  }

  Future<void> _toggleClipPlayback() async {
    if (_clipPlaying) {
      _resetClipPlayback();
      if (mounted) setState(() {});
      return;
    }
    await _playClip();
  }

  Future<void> _seek(Duration position) async {
    final player = _player;
    if (player != null && _videoReady) {
      try {
        await player.seek(position);
      } catch (_) {
        // Ignore a seek issued while the native player is transitioning.
      }
    }
  }

  ClipRange _currentRange(Map<String, dynamic> candidate) =>
      _draftRange ?? ClipRange(_clipStart(candidate), _clipEndFor(candidate));

  void _onRangeChanged(ClipRange range) {
    if (mounted) setState(() => _draftRange = range);
  }

  void _onRangeChangeEnd(ClipRange range) {
    final candidate = widget.candidate;
    if (candidate == null) return;
    final next = _draftRange ?? range;
    _queueRangeSave(candidate['id']?.toString(), next);
  }

  void _nudge(ClipBoundary boundary, int deltaMs) {
    final candidate = widget.candidate;
    final player = _player;
    if (candidate == null || player == null) return;
    final next = adjustClipBoundary(
      _currentRange(candidate),
      boundary,
      deltaMs,
      player.state.duration.inMilliseconds,
    );
    setState(() => _draftRange = next);
    _queueRangeSave(candidate['id']?.toString(), next);
  }

  void _queueRangeSave(String? candidateId, ClipRange range) {
    if (candidateId == null || candidateId.isEmpty) return;
    _pendingRangeCandidateId = candidateId;
    _pendingRange = range;
    _rangeSaveFuture ??= _drainRangeSaves();
  }

  Future<void> _drainRangeSaves() async {
    while (_pendingRangeCandidateId != null && _pendingRange != null) {
      final candidateId = _pendingRangeCandidateId!;
      final range = _pendingRange!;
      _pendingRangeCandidateId = null;
      _pendingRange = null;
      try {
        await widget.onUpdateRange(candidateId, range.startMs, range.endMs);
      } catch (error) {
        if (mounted) {
          setState(() => _playerError = '保存片段范围失败：$error');
        }
      }
    }
    _rangeSaveFuture = null;
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
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.md,
        Spacing.sm,
      ),
      child: Column(
        children: [
          // 仅在分析停止后显示恢复提示；分析中由顶部状态条统一反馈进度。
          if (widget.recoverable) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
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
            const SizedBox(height: Spacing.xs),
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
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        ExcludeSemantics(
                          child: Video(
                            controller: controller,
                            controls: NoVideoControls,
                          ),
                        ),
                        if (_loadingVideo)
                          ColoredBox(
                            color: Colors.black26,
                            child: Center(
                              child: CircularProgressIndicator(color: c.indigo),
                            ),
                          ),
                      ],
                    )
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
            enabled:
                hasVideo &&
                player != null &&
                _playerError == null &&
                _videoReady,
            hasPrevious: widget.hasPrevious,
            hasNext: widget.hasNext,
            onPrevious: widget.onPrevious,
            onNext: widget.onNext,
            onSeek: _seek,
            onTogglePlayback: _togglePlayback,
            onPlayClip: widget.candidate == null ? null : _toggleClipPlayback,
            clipPlaying: _clipPlaying,
          ),

          if (widget.candidate != null) ...[
            const SizedBox(height: Spacing.sm),
            StreamBuilder<Duration>(
              stream: player?.stream.duration,
              initialData: player?.state.duration ?? Duration.zero,
              builder: (context, durationSnapshot) {
                final candidate = widget.candidate!;
                return ClipTimeline(
                  durationMs: durationSnapshot.data?.inMilliseconds ?? 0,
                  range: _currentRange(candidate),
                  eventMs: _candidateTime(candidate) ?? 0,
                  positionMs: _positionMs,
                  onRangeChanged: _onRangeChanged,
                  onRangeChangeEnd: _onRangeChangeEnd,
                  onNudge: _nudge,
                  looping: _loopClip,
                  onToggleLoop: () {
                    setState(() => _loopClip = !_loopClip);
                    if (_loopClip && !_clipPlaying) unawaited(_playClip());
                  },
                );
              },
            ),
          ],

          // 候选信息行
          if (widget.candidate != null) ...[
            const SizedBox(height: Spacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '候选 ${_formatMs(_candidateTime(widget.candidate) ?? 0)} · '
                '片段 ${_formatMs(_currentRange(widget.candidate!).startMs)} - '
                '${_formatMs(_currentRange(widget.candidate!).endMs)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: Material(
                color: c.surface,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(
                    '模型证据',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                  children: [_EvidenceSummary(candidate: widget.candidate!)],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EvidenceSummary extends StatelessWidget {
  const _EvidenceSummary({required this.candidate});

  final Map<String, dynamic> candidate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final lines = evidenceSummaryLines(candidate);
    if (lines.isEmpty) {
      return Text(
        '暂无可解析的模型证据',
        style: theme.textTheme.labelSmall?.copyWith(color: c.textTertiary),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: Spacing.xs,
        runSpacing: Spacing.xs,
        children: lines
            .map(
              (line) => Chip(
                label: Text(line),
                visualDensity: VisualDensity.compact,
                labelStyle: theme.textTheme.labelSmall,
                padding: EdgeInsets.zero,
              ),
            )
            .toList(),
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
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_formatDuration(Duration.zero), style: timeStyle),
              Text(' / ', style: timeStyle),
              Text(_formatDuration(Duration.zero), style: timeStyle),
              const SizedBox(width: Spacing.xs),
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
              CsButton(
                label: const Text('播放候选区间'),
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
                Wrap(
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(_formatDuration(position), style: timeStyle),
                    Text(' / ', style: timeStyle),
                    Text(_formatDuration(duration), style: timeStyle),
                    const SizedBox(width: Spacing.xs),
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
                    CsButton(
                      label: Text(clipPlaying ? '播放中' : '播放候选区间'),
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
    required this.selectedCandidateIds,
    required this.busy,
    required this.onSelected,
    required this.onToggleSelection,
    required this.filter,
    required this.onFilterChanged,
    required this.onReview,
    required this.onShowHistory,
    required this.onUpdateNote,
    required this.onUndo,
    required this.onUpdateRange,
    required this.hasVideo,
    required this.onGoImport,
    required this.onReanalyze,
    required this.onExport,
    required this.analyzing,
    required this.onBatchReview,
    required this.batchBusy,
    required this.sort,
    required this.onSortChanged,
  });

  final List<Map<String, dynamic>> candidates;
  final List<int> candidateIndexes;
  final int selectedIndex;
  final Set<String> selectedCandidateIds;
  final bool busy;
  final ValueChanged<int> onSelected;
  final ValueChanged<String> onToggleSelection;
  final String filter;
  final ValueChanged<String> onFilterChanged;
  final Future<void> Function(String, String) onReview;
  final Future<void> Function(String) onShowHistory;
  final Future<void> Function(String, String) onUpdateNote;
  final Future<void> Function() onUndo;
  final Future<void> Function(String, int, int) onUpdateRange;
  final bool hasVideo;
  final VoidCallback onGoImport;
  final VoidCallback? onReanalyze;
  final VoidCallback onExport;
  final bool analyzing;
  final Future<void> Function(String) onBatchReview;
  final bool batchBusy;
  final String sort;
  final ValueChanged<String> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final pending = candidates
        .where((item) => item['review_status'] == 'pending')
        .length;
    final hasGoal = candidates.any((item) => item['review_status'] == 'goal');
    final noAnalysis = !analyzing && !hasVideo;

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
                  DropdownMenuItem(value: 'deferred', child: Text('暂缓')),
                  DropdownMenuItem(
                    value: 'low_confidence',
                    child: Text('低置信度'),
                  ),
                  DropdownMenuItem(
                    value: 'evidence_conflict',
                    child: Text('证据冲突'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) onFilterChanged(value);
                },
              ),
              DropdownButton<String>(
                value: sort,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'recommended', child: Text('推荐优先')),
                  DropdownMenuItem(
                    value: 'low_confidence',
                    child: Text('低置信度优先'),
                  ),
                  DropdownMenuItem(value: 'conflict', child: Text('证据冲突优先')),
                  DropdownMenuItem(value: 'time', child: Text('时间顺序')),
                ],
                onChanged: (value) {
                  if (value != null) onSortChanged(value);
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
              IconButton(
                tooltip: '撤销上一步',
                onPressed: busy ? null : onUndo,
                icon: const Icon(Icons.undo, size: 16),
                visualDensity: VisualDensity.compact,
              ),
              if (selectedCandidateIds.isNotEmpty) ...[
                Text(
                  '${selectedCandidateIds.length} 项已选',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '批量操作',
                  enabled: !busy,
                  onSelected: onBatchReview,
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'goal', child: Text('批量确认进球')),
                    PopupMenuItem(value: 'excluded', child: Text('批量排除')),
                    PopupMenuItem(value: 'deferred', child: Text('批量暂缓')),
                  ],
                  child: const Icon(LucideIcons.ellipsis, size: 18),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.md),
          Expanded(
            child: candidates.isEmpty
                ? CsEmptyState(
                    icon: LucideIcons.inbox,
                    title: analyzing
                        ? '正在等待候选片段'
                        : noAnalysis
                        ? '还没有分析结果'
                        : '暂未找到候选片段',
                    description: analyzing
                        ? '分析进行中，候选片段会自动出现在这里。'
                        : noAnalysis
                        ? '先导入视频并框选篮筐区域，再开始分析。'
                        : '这不代表一定没有进球。建议先检查篮筐区域，再重新分析当前视频。',
                    action: analyzing
                        ? null
                        : Wrap(
                            alignment: WrapAlignment.center,
                            spacing: Spacing.xs,
                            runSpacing: Spacing.xs,
                            children: [
                              if (hasVideo)
                                CsButton(
                                  label: const Text('重新分析当前视频'),
                                  icon: LucideIcons.rotateCcw,
                                  onPressed: onReanalyze,
                                ),
                              CsButton(
                                label: Text(hasVideo ? '调整篮筐区域' : '去导入视频'),
                                icon: hasVideo
                                    ? LucideIcons.crop
                                    : LucideIcons.upload,
                                variant: CsButtonVariant.secondary,
                                onPressed: onGoImport,
                              ),
                            ],
                          ),
                  )
                : ListView.separated(
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.xs),
                    itemBuilder: (context, index) {
                      final item = candidates[index];
                      final actualIndex = candidateIndexes[index];
                      final status =
                          item['review_status']?.toString() ?? 'pending';
                      final id = item['id']?.toString() ?? '';
                      final selected = actualIndex == selectedIndex;
                      final time =
                          (item['event_time_ms'] as num?)?.toInt() ?? 0;
                      return _CandidateTile(
                        index: index,
                        time: time,
                        status: status,
                        reason: item['review_reason']?.toString(),
                        selected: selected,
                        checked: selectedCandidateIds.contains(id),
                        busy: busy,
                        onTap: () => onSelected(actualIndex),
                        onToggleSelection: () => onToggleSelection(id),
                        onReview: (s) => onReview(id, s),
                        onShowHistory: () => onShowHistory(id),
                        onEditRange: () =>
                            _editRange(context, item, onUpdateRange),
                        onEditNote: () =>
                            _editNote(context, item, onUpdateNote),
                      );
                    },
                  ),
          ),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: CsButton(
                  label: const Text('导出'),
                  icon: LucideIcons.arrowUpRight,
                  onPressed: hasGoal ? onExport : null,
                ),
              ),
              if (onReanalyze != null && candidates.isNotEmpty) ...[
                const SizedBox(width: Spacing.xs),
                IconButton(
                  tooltip: '重新分析当前视频',
                  onPressed: onReanalyze,
                  icon: const Icon(LucideIcons.rotateCcw, size: 17),
                ),
              ],
            ],
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
    required this.reason,
    required this.selected,
    required this.checked,
    required this.busy,
    required this.onTap,
    required this.onToggleSelection,
    required this.onReview,
    required this.onShowHistory,
    required this.onEditRange,
    required this.onEditNote,
  });

  final int index;
  final int time;
  final String status;
  final String? reason;
  final bool selected;
  final bool checked;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onToggleSelection;
  final Future<void> Function(String) onReview;
  final Future<void> Function() onShowHistory;
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
    return CsCard(
      tier: selected ? CsCardTier.selected : CsCardTier.defaultTier,
      selectedAccent: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
      child: Row(
        children: [
          Checkbox(
            value: checked,
            onChanged: busy ? null : (_) => onToggleSelection(),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Expanded(
            child: Text(
              '#${index + 1}  ${_formatMs(time)}${reason != null && reviewReasonLabels[reason] != null ? ' · ${reviewReasonLabels[reason]}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: c.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (status == 'deferred')
            Text(
              '暂缓',
              style: theme.textTheme.labelSmall?.copyWith(color: c.warning),
            )
          else
            CsStatusChip(status: _reviewStatus, compact: true),
          IconButton(
            tooltip: '确认进球',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: busy ? null : () => onReview('goal'),
            icon: Icon(LucideIcons.check, size: 17, color: c.goal),
          ),
          IconButton(
            tooltip: '排除候选',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: busy ? null : () => onReview('excluded'),
            icon: Icon(LucideIcons.ban, size: 16, color: c.textSecondary),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            enabled: !busy,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onSelected: (value) {
              switch (value) {
                case 'deferred':
                  unawaited(onReview('deferred'));
                case 'range':
                  onEditRange();
                case 'note':
                  onEditNote();
                case 'history':
                  unawaited(onShowHistory());
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'deferred', child: Text('暂缓审核')),
              PopupMenuItem(value: 'range', child: Text('编辑片段')),
              PopupMenuItem(value: 'note', child: Text('添加备注')),
              PopupMenuItem(value: 'history', child: Text('审核历史')),
            ],
            icon: const Icon(LucideIcons.ellipsis, size: 17),
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
  final start = TextEditingController(text: _formatMs(_clipStart(item)));
  final end = TextEditingController(text: _formatMs(_clipEndFor(item)));
  final result = await showDialog<List<int>>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('编辑片段范围'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: start,
            keyboardType: TextInputType.datetime,
            decoration: const InputDecoration(
              labelText: '开始时间',
              hintText: '例如 00:06',
            ),
          ),
          TextField(
            controller: end,
            keyboardType: TextInputType.datetime,
            decoration: const InputDecoration(
              labelText: '结束时间',
              hintText: '例如 00:15',
            ),
          ),
          const SizedBox(height: Spacing.xs),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('使用 mm:ss；保存后立即应用到导出片段。'),
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
            final s = _parseTimecode(start.text);
            final e = _parseTimecode(end.text);
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

Future<String?> _selectReviewReason(BuildContext context, String status) async {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(status == 'deferred' ? '选择暂缓原因' : '选择排除原因'),
      children: reviewReasons
          .map(
            (reason) => SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, reason),
              child: Text(reviewReasonLabels[reason] ?? reason),
            ),
          )
          .toList(),
    ),
  );
}

int? _parseTimecode(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length != 2 && parts.length != 3) return null;
  final numbers = parts.map(int.tryParse).toList();
  if (numbers.any((value) => value == null)) return null;
  if (parts.length == 2) {
    final minutes = numbers[0]!;
    final seconds = numbers[1]!;
    if (minutes < 0 || seconds < 0 || seconds >= 60) return null;
    return (minutes * 60 + seconds) * 1000;
  }
  final hours = numbers[0]!;
  final minutes = numbers[1]!;
  final seconds = numbers[2]!;
  if (hours < 0 ||
      minutes < 0 ||
      seconds < 0 ||
      minutes >= 60 ||
      seconds >= 60) {
    return null;
  }
  return (hours * 3600 + minutes * 60 + seconds) * 1000;
}

int? _candidateTime(Map<String, dynamic>? candidate) {
  final value = candidate?['event_time_ms'];
  return value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
}

String? _resolvePlaybackPath(ProjectState state, {required bool analyzing}) {
  final preferred = analyzing
      ? <String?>[state.videoPath, state.reviewVideoPath]
      : <String?>[state.reviewVideoPath, state.videoPath];
  for (final path in preferred) {
    if (path != null && path.isNotEmpty && File(path).existsSync()) return path;
  }
  return preferred.firstWhere(
    (path) => path != null && path.isNotEmpty,
    orElse: () => null,
  );
}

String _candidateSignature(Map<String, dynamic>? candidate) {
  if (candidate == null) return '';
  return '${candidate['id']?.toString() ?? ''}|${_clipStart(candidate)}|${_clipEndFor(candidate)}';
}

String _reviewStatusLabel(String status) => switch (status) {
  'goal' => '已确认进球',
  'excluded' => '已排除',
  'deferred' => '已暂缓审核',
  'second_review' => '待二次复核',
  'pending' => '待审核',
  _ => status,
};

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
