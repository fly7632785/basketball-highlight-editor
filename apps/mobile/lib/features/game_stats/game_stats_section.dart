part of '../../mobile_ui.dart';

class _GameStatsBody extends StatelessWidget {
  const _GameStatsBody({required this.stats});
  final GameStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = stats.estimatedHitRate;
    final players = [
      for (final player in stats.playerCounts)
        (name: player.name, count: player.count),
      if (stats.unassignedCount > 0)
        (name: context.bheText('未标记'), count: stats.unassignedCount),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _GameStatsMetric(
                label: context.bheText('候选'),
                value: '${stats.candidateCount}',
              ),
            ),
            Expanded(
              child: _GameStatsMetric(
                label: context.bheText('保留'),
                value: '${stats.keptCount}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _GameStatsMetric(
                label: context.bheText('未审核'),
                value: '${stats.unreviewedCount}',
              ),
            ),
            Expanded(
              child: _GameStatsMetric(
                label: context.bheText('已排除'),
                value: '${stats.excludedCount}',
                note: stats.excludedCount == 0
                    ? null
                    : context.bheText(
                        '手动 ${stats.manuallyExcludedCount} · 复核 ${stats.rimRejectedCount}',
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              context.bheText('命中率（估算）'),
              style: theme.textTheme.bodySmall,
            ),
            Text(
              rate == null ? '—' : '${(rate * 100).round()}%',
              key: const ValueKey('game-stats-rate'),
              style: theme.textTheme.titleLarge?.copyWith(
                color: BhePalette.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          context.bheText('保留 ÷ 候选，粗略估算，非真实命中率'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: BhePalette.textSecondary,
          ),
        ),
        if (players.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(context.bheText('每人进球'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            context.bheText('多标签片段分别计入各标签'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final player in players)
            _GameStatsBar(
              label: player.name,
              count: player.count,
              max: players.first.count,
            ),
        ],
        if (stats.timeBuckets.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            context.bheText('进球时间分布'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            context.bheText('从视频开头算起'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: BhePalette.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          for (final bucket in stats.timeBuckets)
            _GameStatsBar(
              label: context.bheText(
                '${bucket.startMinute}–${bucket.endMinute} 分钟',
              ),
              count: bucket.count,
              max: stats.timeBuckets
                  .map((item) => item.count)
                  .reduce((a, b) => a > b ? a : b),
            ),
        ],
      ],
    );
  }
}

class _GameStatsMetric extends StatelessWidget {
  const _GameStatsMetric({required this.label, required this.value, this.note});
  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, style: theme.textTheme.titleMedium),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              note!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: BhePalette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GameStatsBar extends StatelessWidget {
  const _GameStatsBar({
    required this.label,
    required this.count,
    required this.max,
  });
  final String label;
  final int count;
  final int max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = max <= 0 ? 0.0 : (count / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: [
                  Container(height: 8, color: BhePalette.surface3),
                  FractionallySizedBox(
                    widthFactor: fraction,
                    child: Container(height: 8, color: BhePalette.orange),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 28,
            child: Text(
              '$count',
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
