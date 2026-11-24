part of '../../mobile_ui.dart';

class _ReviewActionBar extends StatelessWidget {
  const _ReviewActionBar({
    required this.candidate,
    required this.canUndo,
    required this.onUndo,
    required this.controller,
    required this.annotations,
    required this.autoReplay,
    required this.clipOnly,
    required this.speed,
    required this.onToggle,
    required this.onReplay,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeekTo,
    required this.onToggleAnnotations,
    required this.onToggleAutoReplay,
    required this.onToggleSource,
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
  final bool canUndo;
  final VoidCallback onUndo;
  final VideoPlayerController? controller;
  final bool annotations;
  final bool autoReplay;
  final bool clipOnly;
  final double speed;
  final VoidCallback onToggle;
  final VoidCallback onReplay;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final ValueChanged<int> onSeekTo;
  final VoidCallback onToggleAnnotations;
  final VoidCallback onToggleAutoReplay;
  final VoidCallback onToggleSource;
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
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final value = controller?.value;
    final fullDuration = value?.duration.inMilliseconds.toDouble() ?? 1;
    final minPosition = clipOnly ? candidate.startMs.toDouble() : 0.0;
    final duration = clipOnly ? candidate.endMs.toDouble() : fullDuration;
    final position = (value?.position.inMilliseconds.toDouble() ?? minPosition)
        .clamp(minPosition, duration)
        .toDouble();
    return Material(
      color: Theme.of(context).cardTheme.color,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Slider(
              min: minPosition,
              value: position,
              max: duration,
              onChanged: controller == null
                  ? null
                  : (value) => onSeekTo(value.round()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    l10n?.currentTime(_formatMs(position.round())) ??
                        '当前 ${_formatMs(position.round())}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Builder(
                    builder: (context) {
                      // 旧版本项目数据可能遗留 startMs > endMs，显示时统一按先小后大。
                      final startMs = candidate.startMs < candidate.endMs
                          ? candidate.startMs
                          : candidate.endMs;
                      final endMs = candidate.startMs < candidate.endMs
                          ? candidate.endMs
                          : candidate.startMs;
                      return Text(
                        clipOnly
                            ? (l10n?.clipTime(
                                    _formatMs(startMs),
                                    _formatMs(endMs),
                                  ) ??
                                  '片段 ${_formatMs(startMs)} — ${_formatMs(endMs)}')
                            : (l10n?.fullVideoTime(
                                    _formatMs(fullDuration.round()),
                                  ) ??
                                  '全片 ${_formatMs(fullDuration.round())}'),
                        style: Theme.of(context).textTheme.bodySmall,
                      );
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IntrinsicWidth(
                    child: SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(l10n?.reviewMode ?? '审核'),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text(l10n?.originalVideo ?? '原视频'),
                        ),
                      ],
                      selected: {clipOnly},
                      onSelectionChanged: (selection) {
                        if (selection.single != clipOnly) onToggleSource();
                      },
                      showSelectedIcon: false,
                      style: ButtonStyle(
                        side: const WidgetStatePropertyAll(BorderSide.none),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                        backgroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: .12)
                              : Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: .04),
                        ),
                        foregroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        textStyle: const WidgetStatePropertyAll(
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
                        ),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: onToggleAnnotations,
                    isSelected: annotations,
                    icon: const Icon(LucideIcons.scanLine, size: 19),
                    tooltip: annotations
                        ? (l10n?.hideTrajectory ?? '隐藏轨迹')
                        : (l10n?.showTrajectory ?? '显示轨迹'),
                    style: IconButton.styleFrom(
                      foregroundColor: annotations
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      backgroundColor: annotations
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: .10)
                          : Colors.transparent,
                      minimumSize: const Size(48, 48),
                      padding: EdgeInsets.zero,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.primary.withValues(
                          alpha: annotations ? .35 : .18,
                        ),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onShortcuts,
                    icon: const Icon(LucideIcons.info, size: 19),
                    tooltip: l10n?.shortcuts ?? '操作提示',
                    style: IconButton.styleFrom(
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: .04),
                      minimumSize: const Size(48, 48),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 48,
                    child: PopupMenuButton<String>(
                      tooltip: l10n?.moreReviewActions ?? '更多审核操作',
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
                          value: 'range',
                          child: Text(l10n?.editClipRange ?? '调整片段范围'),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'evidence',
                          child: Text(l10n?.viewEvidence ?? '查看判断依据'),
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
                            child: Row(
                              children: [
                                Icon(
                                  LucideIcons.download,
                                  size: 17,
                                  color: BhePalette.orange,
                                ),
                                SizedBox(width: 9),
                                Text(l10n?.exportIncluded ?? '导出保留片段'),
                              ],
                            ),
                          ),
                        ),
                      ],
                      icon: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: .04),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(LucideIcons.ellipsis, size: 19),
                        ),
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    onPressed: onReplay,
                    icon: const Icon(LucideIcons.refreshCw, size: 19),
                    tooltip: l10n?.replay ?? '重播',
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onToggleAutoReplay,
                    icon: Icon(
                      autoReplay ? LucideIcons.repeat2 : LucideIcons.repeatOff,
                      size: 19,
                      color: autoReplay
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    tooltip: autoReplay
                        ? (l10n?.closeAutoReplay ?? '关闭自动重播')
                        : (l10n?.openAutoReplay ?? '打开自动重播'),
                  ),
                  PopupMenuButton<double>(
                    tooltip: l10n?.playbackSpeed ?? '播放速度',
                    initialValue: speed,
                    onSelected: onSpeed,
                    itemBuilder: (_) => [
                      for (final rate in [.5, .75, 1.0, 1.5, 2.0])
                        CheckedPopupMenuItem(
                          value: rate,
                          checked: rate == speed,
                          child: Text(_formatSpeed(rate)),
                        ),
                    ],
                    child: SizedBox(
                      width: 58,
                      height: 48,
                      child: Center(child: Text(_formatSpeed(speed))),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    onPressed: onSeekBack,
                    icon: const Icon(LucideIcons.rotateCcw, size: 19),
                    tooltip:
                        '${context.bheText('后退')} 1.5 ${context.bheText('秒')}',
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: onToggle,
                    icon: Icon(
                      value?.isPlaying == true
                          ? LucideIcons.pause
                          : LucideIcons.play,
                      size: 20,
                    ),
                    tooltip: context.bheText(
                      value?.isPlaying == true ? '暂停' : '播放',
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onSeekForward,
                    icon: const Icon(LucideIcons.rotateCw, size: 19),
                    tooltip:
                        '${context.bheText('前进')} 1.5 ${context.bheText('秒')}',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  _ReviewUndoButton(onPressed: canUndo ? onUndo : null),
                  IconButton(
                    onPressed: onPlayer,
                    tooltip: context.bheText(
                      candidate.player == null
                          ? '球员标签'
                          : '球员：${candidate.player}',
                    ),
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
                      label: Text(context.bheText('不选')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onInclude,
                      icon: const Icon(LucideIcons.check, size: 18),
                      label: Text(context.bheText('选中')),
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
      case 'range':
        onEditRange();
      case 'evidence':
        onDetails();
      case 'export':
        onExport();
    }
  }
}

class _ReviewProgressHeader extends StatelessWidget {
  const _ReviewProgressHeader({
    required this.candidates,
    required this.total,
    required this.reviewed,
    required this.filtering,
    required this.onBatchRange,
    required this.onAdd,
    required this.onClearFilters,
  });
  final List<Candidate> candidates;
  final int total;
  final int reviewed;
  final bool filtering;
  final VoidCallback onBatchRange;
  final VoidCallback onAdd;
  final VoidCallback onClearFilters;
  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          return Row(
            children: [
              Flexible(
                flex: 2,
                child: Text(
                  filtering
                      ? '${context.bheText('显示 ${candidates.length} / $total')} · ${context.bheText('已审核 $reviewed / $total')}'
                      : context.bheText('已审核 $reviewed / $total'),
                  key: const Key('review-progress'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : reviewed / total,
                    minHeight: 3,
                    color: BhePalette.green,
                    backgroundColor: BhePalette.border,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (filtering) IconButton(key: const Key('review-clear-filters'), onPressed: onClearFilters, tooltip: context.bheText('清除筛选'), icon: const Icon(LucideIcons.filterX, size: 16)),
              if (compact) ...[
                IconButton(
                  onPressed: onBatchRange,
                  tooltip: l10n?.clipDuration ?? '时长',
                  icon: const Icon(LucideIcons.clock3, size: 16),
                ),
                IconButton(
                  onPressed: onAdd,
                  tooltip: l10n?.addManualCandidate ?? '补漏',
                  icon: const Icon(LucideIcons.plus, size: 16),
                ),
              ] else ...[
                TextButton.icon(
                  onPressed: onBatchRange,
                  icon: const Icon(LucideIcons.clock3, size: 16),
                  label: Text(l10n?.clipDuration ?? '时长'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                ),
                TextButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(LucideIcons.plus, size: 16),
                  label: Text(l10n?.addManualCandidate ?? '补漏'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ReviewUndoButton extends StatelessWidget {
  const _ReviewUndoButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('review-undo-bottom'),
    onPressed: onPressed,
    tooltip: context.bheText('撤销上一步'),
    icon: const Icon(LucideIcons.rotateCcw, size: 19),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 40, height: 48),
  );
}
