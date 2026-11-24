part of '../../mobile_ui.dart';

bool _matchesReviewFilters(
  Candidate candidate, {
  required String rim,
  required String player,
}) {
  if (rim != 'all' && candidate.rimCheckStatus != rim) return false;
  final labels = candidate.effectivePlayers;
  return switch (player) {
    'all' => true,
    'tagged' => labels.isNotEmpty,
    'untagged' => labels.isEmpty,
    _ => labels.contains(player.substring('player:'.length)),
  };
}

Color _tierColor(MobileTier tier) => switch (tier) {
  MobileTier.goal => BhePalette.green,
  MobileTier.uncertain => BhePalette.warning,
  MobileTier.excluded => BhePalette.textTertiary,
};

class _CandidateRail extends StatelessWidget {
  const _CandidateRail({
    required this.controller,
    required this.itemKeys,
    required this.candidates,
    required this.allCandidates,
    required this.tierCandidates,
    required this.players,
    required this.statusFilter,
    required this.rimFilter,
    required this.playerFilter,
    required this.onTier,
    required this.onFilters,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAdd,
    required this.onBatchRange,
    required this.onExportGoals,
    required this.landscape,
    required this.foldedCount,
    required this.foldedExpanded,
    required this.onToggleFold,
    required this.onMarkFolded,
    required this.batchNoticeCount,
  });

  final ScrollController? controller;
  final List<GlobalKey> itemKeys;
  final List<Candidate> candidates, allCandidates, tierCandidates;
  final List<String> players;
  final String statusFilter, rimFilter, playerFilter;
  final ValueChanged<String> onTier;
  final void Function(String rim, String player) onFilters;
  final int selectedIndex, foldedCount, batchNoticeCount;
  final bool landscape, foldedExpanded;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd,
      onBatchRange,
      onToggleFold,
      onMarkFolded,
      onExportGoals;

  bool get filtering => rimFilter != 'all' || playerFilter != 'all';

  @override
  Widget build(BuildContext context) {
    final counts = {for (final tier in MobileTier.values) tier: 0};
    final numbers = <String, int>{};
    var reviewed = 0;
    for (var index = 0; index < allCandidates.length; index++) {
      final candidate = allCandidates[index];
      final tier = mobileTier(candidate);
      counts[tier] = counts[tier]! + 1;
      numbers[candidate.id] = index + 1;
      if (candidate.reviewed) reviewed++;
    }
    final uncertain = counts[MobileTier.uncertain]! - foldedCount;
    final goals = counts[MobileTier.goal]!;
    final progress = uncertain == 0
        ? context.bheText('疑似审完了')
        : context.bheText('疑似剩 $uncertain · 已审 $reviewed');
    return ColoredBox(
      color: Theme.of(context).cardTheme.color ?? BhePalette.surface,
      child: Column(
        children: [
          if (!landscape)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      progress,
                      key: const Key('review-progress'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: uncertain == 0
                          ? 1
                          : reviewed / (reviewed + uncertain),
                      minHeight: 3,
                      color: BhePalette.green,
                      backgroundColor: BhePalette.border,
                    ),
                  ),
                  _ReviewHeaderButton(
                    icon: LucideIcons.clock3,
                    label: '时长',
                    onPressed: onBatchRange,
                  ),
                  _ReviewHeaderButton(
                    icon: LucideIcons.plus,
                    label: '补漏',
                    onPressed: onAdd,
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: _ReviewTierTabs(
                    status: statusFilter,
                    goals: goals,
                    uncertain: uncertain,
                    excluded: counts[MobileTier.excluded]!,
                    total: allCandidates.length,
                    onTier: onTier,
                    landscape: landscape,
                  ),
                ),
                if (!landscape) ...[
                  const SizedBox(width: 4),
                  Badge(
                    key: filtering ? const Key('review-filters-active') : null,
                    isLabelVisible: filtering,
                    label: Text(
                      '${(rimFilter == 'all' ? 0 : 1) + (playerFilter == 'all' ? 0 : 1)}',
                    ),
                    child: IconButton(
                      key: const Key('review-player-filter'),
                      tooltip: context.bheText('筛选'),
                      icon: const Icon(LucideIcons.listFilter, size: 19),
                      onPressed: () async {
                        final choice = await _showReviewFilterSheet(
                          context,
                          candidates: tierCandidates,
                          players: players,
                          rim: rimFilter,
                          player: playerFilter,
                        );
                        if (context.mounted && choice != null) {
                          onFilters(choice.rim, choice.player);
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: candidates.isEmpty
                ? _empty(context, uncertain: uncertain, goals: goals)
                : ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 5),
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      return _ReviewTierCandidateTile(
                        key: landscape
                            ? ValueKey(candidate.id)
                            : itemKeys[index],
                        candidate: candidate,
                        number: numbers[candidate.id]!,
                        active: index == selectedIndex,
                        compact: landscape,
                        onTap: () => onSelect(index),
                      );
                    },
                  ),
          ),
          if (statusFilter == 'uncertain' &&
              foldedCount > 0 &&
              (landscape || batchNoticeCount == 0))
            _ReviewFoldBar(
              count: foldedCount,
              expanded: foldedExpanded,
              offerToReview: candidates.isEmpty && !filtering,
              landscape: landscape,
              onToggle: onToggleFold,
              onMark: filtering ? null : onMarkFolded,
            ),
          if (!landscape && batchNoticeCount > 0)
            _ReviewBatchNotice(count: batchNoticeCount),
        ],
      ),
    );
  }

  Widget _empty(
    BuildContext context, {
    required int uncertain,
    required int goals,
  }) {
    final (title, detail) = switch (statusFilter) {
      _ when filtering => ('没有符合筛选的片段', null),
      'included' => ('还没有进球', '这台手机的分析还不能自动确认进球。你在「疑似」里点「选中」的会出现在这里。'),
      'uncertain' => ('疑似审完了', null),
      _ => ('没有片段', null),
    };
    final actions = <Widget>[
      if (filtering)
        TextButton(
          key: const Key('review-clear-filters'),
          onPressed: () => onFilters('all', 'all'),
          child: Text(context.bheText('清除')),
        )
      else if (statusFilter == 'uncertain') ...[
        if (goals > 0)
          FilledButton(
            onPressed: onExportGoals,
            child: Text(context.bheText('导出 $goals 段进球')),
          ),
      ] else if (statusFilter == 'included' && uncertain + foldedCount > 0)
        FilledButton(
          onPressed: () => onTier('uncertain'),
          child: Text(context.bheText('去审 $uncertain 段疑似')),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Text(context.bheText(title), textAlign: TextAlign.center),
                    if (detail != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          context.bheText(detail),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(alignment: WrapAlignment.center, children: actions),
            ),
        ],
      ),
    );
  }
}

class _ReviewHeaderButton extends StatelessWidget {
  const _ReviewHeaderButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
    padding: EdgeInsets.zero,
    tooltip: context.bheText(label),
    icon: Icon(icon, size: 16),
    onPressed: onPressed,
  );
}

class _ReviewTierTabs extends StatelessWidget {
  const _ReviewTierTabs({
    required this.status,
    required this.goals,
    required this.uncertain,
    required this.excluded,
    required this.total,
    required this.onTier,
    required this.landscape,
  });

  final String status;
  final int goals, uncertain, excluded, total;
  final ValueChanged<String> onTier;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final english = Localizations.localeOf(context).languageCode == 'en';
    final options = [
      ('included', '进球', goals, MobileTier.goal),
      ('uncertain', '疑似', uncertain, MobileTier.uncertain),
      ('excluded', '排除', excluded, MobileTier.excluded),
      ('all', '全部', total, null),
    ];
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(10),
      child: Row(
        children: [
          for (final (value, label, count, tier) in options)
            Expanded(
              flex: english && value == 'uncertain' ? 12 : 10,
              child: InkWell(
                key: Key('review-filter-$value'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => onTier(value),
                child: Container(
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: value == status
                        ? Theme.of(context).colorScheme.surfaceContainerHighest
                        : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${context.bheText(label)}${english || landscape ? '\n' : ' '}$count',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: value != status && tier != null
                                  ? _tierColor(tier)
                                  : null,
                              fontWeight: value == status
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReviewTierCandidateTile extends StatelessWidget {
  const _ReviewTierCandidateTile({
    super.key,
    required this.candidate,
    required this.number,
    required this.active,
    required this.compact,
    required this.onTap,
  });

  final Candidate candidate;
  final int number;
  final bool active, compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tier = mobileTier(candidate);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: active ? BhePalette.orange.withValues(alpha: .13) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? BhePalette.orange : BhePalette.border,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.circle, color: _tierColor(tier), size: 7),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '#$number  ${candidate.displayTime}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    _formatMs(candidate.duration.inMilliseconds),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (tier == MobileTier.excluded)
              Flexible(
                child: Text(
                  context.bheText(
                    candidate.reviewed
                        ? '你排除的'
                        : candidate.rimCheckStatus == 'rejected'
                        ? '自动排除'
                        : '已排除',
                  ),
                  maxLines: compact ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              )
            else if (!compact) ...[
              _RimCheckTag(candidate: candidate),
              if (candidate.player case final name?)
                Flexible(child: _PlayerTagChip(player: name)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewFoldBar extends StatelessWidget {
  const _ReviewFoldBar({
    required this.count,
    required this.expanded,
    required this.offerToReview,
    required this.landscape,
    required this.onToggle,
    required this.onMark,
  });

  final int count;
  final bool expanded, landscape, offerToReview;
  final VoidCallback onToggle;
  final VoidCallback? onMark;

  @override
  Widget build(BuildContext context) {
    final toggle = TextButton.icon(
      key: const Key('review-fold-toggle'),
      onPressed: onToggle,
      icon: Icon(
        expanded ? LucideIcons.chevronUp : LucideIcons.chevronRight,
        size: 16,
      ),
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          context.bheText(offerToReview ? '看折叠的 $count' : '很可能没进 $count'),
        ),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
    final mark = TextButton(
      key: const Key('review-fold-mark-all'),
      onPressed: onMark,
      style: TextButton.styleFrom(
        foregroundColor: BhePalette.error,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(context.bheText('全部标为没进')),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        child: landscape
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [toggle, if (expanded && onMark != null) mark],
              )
            : Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: toggle,
                    ),
                  ),
                  if (onMark != null) Expanded(child: mark),
                ],
              ),
      ),
    );
  }
}

class _ReviewBatchNotice extends StatelessWidget {
  const _ReviewBatchNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('review-fold-notice'),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(context.bheText('$count 段已标为没进，点左下角可撤销')),
    ),
  );
}

Future<bool?> _confirmFoldedMisses(
  BuildContext context,
  int count, {
  required bool landscape,
}) {
  Widget description(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(context.bheText('只处理你还没判过的片段，标完进「排除」，点左下角撤销可以一次全部恢复。')),
      const SizedBox(height: 8),
      Text(
        context.bheText('折叠区约 5–15% 仍可能是真进球，建议先扫一眼。'),
        style: const TextStyle(color: BhePalette.warning),
      ),
    ],
  );
  Widget takeLook(BuildContext context) => FilledButton(
    onPressed: () => Navigator.pop(context, false),
    child: Text(context.bheText('先扫一眼')),
  );
  Widget mark(BuildContext context) => FilledButton(
    key: const Key('review-fold-confirm'),
    style: FilledButton.styleFrom(
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
    onPressed: () => Navigator.pop(context, true),
    child: Text(context.bheText('全部标为没进')),
  );
  Widget cancel(BuildContext context) => TextButton(
    onPressed: () => Navigator.pop(context),
    child: Text(context.bheText('取消')),
  );
  final title = context.bheText('把 $count 段标为没进？');
  if (landscape) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: description(context)),
        actions: [cancel(context), mark(context), takeLook(context)],
      ),
    );
  }
  return showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => _SheetFrame(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          description(context),
          const SizedBox(height: 10),
          takeLook(context),
          mark(context),
          cancel(context),
        ],
      ),
    ),
  );
}

Future<({String rim, String player})?> _showReviewFilterSheet(
  BuildContext context, {
  required List<Candidate> candidates,
  required List<String> players,
  required String rim,
  required String player,
}) {
  var selectedRim = rim;
  var selectedPlayer = player;
  final labels = {
    ...players,
    for (final candidate in candidates) ...candidate.effectivePlayers,
    if (player.startsWith('player:')) player.substring('player:'.length),
  };
  return showModalBottomSheet<({String rim, String player})>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        final visible = candidates
            .where(
              (c) => _matchesReviewFilters(
                c,
                rim: selectedRim,
                player: selectedPlayer,
              ),
            )
            .length;
        return _SheetFrame(
          title: context.bheText('筛选'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.bheText('篮筐复核')),
              Wrap(
                spacing: 6,
                children: [
                  for (final (value, label) in [
                    ('all', '全部'),
                    ('made', '通过'),
                    ('unsure', '未确认'),
                    ('rejected', '未通过'),
                  ])
                    ChoiceChip(
                      key: Key('review-rim-filter-$value'),
                      label: Text(
                        '${context.bheText(label)} ${candidates.where((c) => _matchesReviewFilters(c, rim: value, player: 'all')).length}',
                      ),
                      selected: selectedRim == value,
                      onSelected: (_) =>
                          setSheetState(() => selectedRim = value),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(context.bheText('球员标签')),
              Wrap(
                spacing: 6,
                children: [
                  for (final (value, label) in [
                    ('all', context.bheText('不限')),
                    ('tagged', context.bheText('已标注')),
                    ('untagged', context.bheText('未标记')),
                    for (final name in labels) ('player:$name', name),
                  ])
                    ChoiceChip(
                      key: Key('review-player-option-$value'),
                      label: Text(
                        '${label} ${candidates.where((c) => _matchesReviewFilters(c, rim: 'all', player: value)).length}',
                      ),
                      selected: selectedPlayer == value,
                      onSelected: (_) =>
                          setSheetState(() => selectedPlayer = value),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, (rim: 'all', player: 'all')),
                      child: Text(context.bheText('清除')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      key: const Key('review-apply-filters'),
                      onPressed: () => Navigator.pop(context, (
                        rim: selectedRim,
                        player: selectedPlayer,
                      )),
                      child: Text(context.bheText('看 $visible 段')),
                    ),
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
