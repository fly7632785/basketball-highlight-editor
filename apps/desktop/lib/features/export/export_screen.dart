import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_progress_track.dart';
import '../../providers/project_state.dart';
import '../../providers/playback_coordinator.dart';
import '../../providers/export_output_picker.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';
import 'game_stats.dart';

/// Export 屏:汇总当前保留片段 + 合并/分别导出 CTA + 历史。
///
/// 数据来自 [projectProvider];导出走 `ProjectNotifier.export(mode:)`,
/// 返回审核用 `context.go('/review')`。
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  final Set<String> _selectedPlayerIds = <String>{};
  bool _includeUnassigned = true;
  bool _playerFilterActive = false;
  (String?, String?)? _playerFilterScope;
  bool _showFastRisk = true;
  bool _choosingOutput = false;
  String _mode = 'merge';
  String _effect = 'none';

  static const _effectKey = 'export_goal_effect';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString(_effectKey);
      if (mounted && saved != null && saved != _effect && _kEffects.contains(saved)) {
        setState(() => _effect = saved);
      }
    });
  }

  void _setEffect(String value) {
    setState(() => _effect = value);
    SharedPreferences.getInstance().then((prefs) => prefs.setString(_effectKey, value));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    _syncPlayerFilter(state);
    final notifier = ref.read(projectProvider.notifier);
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);

    // 标签全删了以后，「按标签导出」的卡片不再显示，回到合并导出。
    final mode = state.players.isEmpty && _mode == 'merge_by_player'
        ? 'merge'
        : _mode;
    final includedCandidates = _filteredCandidates(state);
    final includedCount = includedCandidates.length;
    final durationMs = includedCandidates.fold<int>(
      0,
      (total, item) => _effectDuration(total, item, _effect),
    );
    final exportRunning = state.exportRunning;
    final exportRecoverable =
        state.exportJob?['recoverable'] == true && !exportRunning;
    final busy =
        _choosingOutput ||
        state.busy ||
        exportRunning ||
        state.analysisRunning ||
        state.hydrating;

    final settings = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n?.exportHighlights ?? '导出集锦',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    l10n?.exportDescription ?? '分析结果默认保留，导出时只排除你打叉的片段。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            CsButton(
              label: Text(l10n?.text('返回审核') ?? '返回审核'),
              icon: LucideIcons.arrowLeft,
              variant: CsButtonVariant.ghost,
              size: CsButtonSize.sm,
              onPressed: () => context.go('/review'),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        if (state.players.isNotEmpty || _playerFilterActive) ...[
          _ExportSection(
            title: l10n?.exportScope ?? '导出范围',
            hint: l10n?.exportScopeHint ?? '可多选球员',
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                _ScopeChip(
                  label: l10n?.allPlayers ?? '全部球员',
                  count: state.candidates.where(_isIncluded).length,
                  selected: !_playerFilterActive,
                  onSelected: (_) => setState(_resetPlayerFilter),
                ),
                for (var index = 0; index < state.players.length; index++)
                  _ScopeChip(
                    label: state.players[index]['name']?.toString() ?? '',
                    count: _playerCount(
                      state,
                      state.players[index]['id']?.toString(),
                    ),
                    dot: c.player(index),
                    selected: _selectedPlayerIds.contains(
                      state.players[index]['id']?.toString(),
                    ),
                    onSelected: (value) => setState(() {
                      final id = state.players[index]['id']?.toString();
                      if (id == null) return;
                      if (!_playerFilterActive) {
                        _includeUnassigned = false;
                      }
                      _playerFilterActive = true;
                      if (value) {
                        _selectedPlayerIds.add(id);
                      } else {
                        _selectedPlayerIds.remove(id);
                      }
                    }),
                  ),
                _ScopeChip(
                  label: l10n?.unassigned ?? '未标记',
                  count: _playerCount(state, null),
                  dashed: true,
                  selected: _playerFilterActive && _includeUnassigned,
                  onSelected: (value) => setState(() {
                    _playerFilterActive = true;
                    _includeUnassigned = value;
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
        ],
        Text(
          l10n?.exportOutputMode ?? '输出方式',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            Expanded(
              child: _ModeCard(
                key: const Key('export-mode-merge'),
                title: l10n?.exportMergeTitle ?? '合并成一个视频',
                description:
                    l10n?.exportMergeDescription ?? '按时间顺序拼接为一个 MP4，适合直接分享。',
                selected: mode == 'merge',
                onTap: () => setState(() => _mode = 'merge'),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: _ModeCard(
                key: const Key('export-mode-separate'),
                title: l10n?.exportSeparateTitle ?? '每个片段单独导出',
                description:
                    l10n?.exportSeparateDescription ??
                    '每段一个文件，放进同一个文件夹，适合二次剪辑。',
                selected: mode == 'separate',
                onTap: () => setState(() => _mode = 'separate'),
              ),
            ),
            if (state.players.isNotEmpty) ...[
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: _ModeCard(
                  key: const Key('export-mode-by-player'),
                  title: context.bheText('每个标签各合成一个视频'),
                  description: context.bheText(
                    '只导出选中的标签，每个标签一个 MP4，文件名就是标签名，放进同一个文件夹。',
                  ),
                  selected: mode == 'merge_by_player',
                  onTap: () => setState(() => _mode = 'merge_by_player'),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: Spacing.md),
        _ExportSection(
          title: context.bheText('进球效果'),
          hint: context.bheText('可选，导出时作用于每个进球片段'),
          child: Column(
            key: const Key('export-goal-effect'),
            children: [
              for (final option in _effectOptions(context))
                _EffectOption(
                  key: Key('export-effect-${option.value}'),
                  title: option.title,
                  description: option.description,
                  selected: _effect == option.value,
                  onTap: busy ? null : () => _setEffect(option.value),
                ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        CsCard(
          child: Row(
            children: [
              Expanded(
                child: _ExportStat(
                  label: l10n?.exportClipCount ?? '片段',
                  value: l10n?.text('$includedCount 个') ?? '$includedCount 个',
                ),
              ),
              Expanded(
                child: _ExportStat(
                  label: l10n?.totalDuration ?? '合计时长',
                  value: _formatMs(durationMs),
                ),
              ),
              Expanded(
                child: _ExportStat(
                  label: l10n?.outputCodec ?? '输出编码',
                  value: 'H.264 / AAC',
                ),
              ),
              Expanded(
                flex: 2,
                child: _ExportStat(
                  label: l10n?.processingMethod ?? '处理方式',
                  value: l10n?.processingValue ?? '硬件编码优先，软件回退',
                ),
              ),
            ],
          ),
        ),
        if (state.analysisRunning) ...[
          const SizedBox(height: Spacing.sm),
          _ExportNotice(
            color: c.warning,
            text:
                l10n?.analysisStillRunning ?? '视频仍在分析，分析完成后才能导出新的候选结果。',
          ),
        ],
        if (state.analysisMode == 'fast' && _showFastRisk) ...[
          const SizedBox(height: Spacing.sm),
          _ExportNotice(
            key: const Key('fast-analysis-export-risk'),
            color: c.warning,
            text:
                l10n?.fastAnalysisRisk ??
                '当前结果来自快速分析，可能漏检；如需更完整结果，建议先用标准模式重新分析。',
            action: IconButton(
              tooltip: l10n?.dismissHint ?? '关闭提示',
              onPressed: () => setState(() => _showFastRisk = false),
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
        if (exportRecoverable) ...[
          const SizedBox(height: Spacing.sm),
          _ExportNotice(
            color: c.warning,
            text: l10n?.exportInterrupted ?? '上次导出已中断，可以从原设置重新导出。',
            action: CsButton(
              label: Text(l10n?.text('重试导出') ?? '重试导出'),
              icon: LucideIcons.refreshCw,
              size: CsButtonSize.sm,
              onPressed: busy ? null : () => notifier.retryExport(),
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            CsButton(
              key: const Key('export-start'),
              label: Text(
                l10n?.exportStartButton(includedCount) ??
                    '导出 $includedCount 个片段',
              ),
              icon: LucideIcons.download,
              size: CsButtonSize.lg,
              isLoading: busy,
              onPressed: includedCount > 0 && !busy
                  ? () => _chooseOutput(notifier, mode: mode)
                  : null,
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                _choosingOutput
                    ? context.bheText('正在准备输出位置…')
                    : exportRunning
                    ? l10n?.text('导出任务在后台运行，返回审核后仍可继续修改候选。') ??
                          '导出任务在后台运行，返回审核后仍可继续修改候选。'
                    : l10n?.exportStartHint ?? '下一步选择保存位置，已排除的片段不会进入输出。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (state.candidates.isNotEmpty) ...[
          const SizedBox(height: Spacing.xl),
          _GameStatsSection(
            stats: computeGameStats(state.candidates, state.players),
          ),
        ],
      ],
    );

    final history = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n?.exportRecent ?? '最近导出',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Text(
              '${state.exportHistory.length}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: c.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        if (exportRunning) ...[
          _RunningExportCard(
            job: state.exportJob,
            onCancel: state.busy ? null : () => notifier.cancelExport(),
          ),
          const SizedBox(height: Spacing.sm),
        ],
        if (state.exportHistory.isNotEmpty)
          for (final item in state.exportHistory)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: _ExportHistoryCard(item: item),
            )
        else if (!exportRunning)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xl),
            child: CsEmptyState(
              icon: LucideIcons.history,
              title: l10n?.text('还没有导出记录') ?? '还没有导出记录',
              description:
                  l10n?.text('完成一次导出后，历史记录会出现在这里。') ??
                  '完成一次导出后，历史记录会出现在这里。',
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1240),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: settings),
                        const SizedBox(width: Spacing.xl),
                        Expanded(flex: 5, child: history),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        settings,
                        const SizedBox(height: Spacing.xxl),
                        history,
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  int _playerCount(ProjectState state, String? playerId) => state.candidates
      .where(_isIncluded)
      .where((item) {
        final id = item['player_id']?.toString();
        return playerId == null ? id == null || id.isEmpty : id == playerId;
      })
      .length;

  void _resetPlayerFilter() {
    _playerFilterActive = false;
    _selectedPlayerIds.clear();
    _includeUnassigned = true;
  }

  void _syncPlayerFilter(ProjectState state) {
    final scope = (state.video?['id']?.toString(), state.videoPath);
    if (_playerFilterScope != scope) {
      _playerFilterScope = scope;
      _resetPlayerFilter();
    }
    // The player list can be incomplete while the project is loading.
    if (state.hydrating) return;
    final playerIds = state.players
        .map((player) => player['id']?.toString())
        .whereType<String>()
        .toSet();
    _selectedPlayerIds.removeWhere((id) => !playerIds.contains(id));
  }

  List<Map<String, dynamic>> _filteredCandidates(ProjectState state) {
    return state.candidates.where(_isIncluded).where((item) {
      if (!_playerFilterActive) return true;
      final playerId = item['player_id']?.toString();
      return _selectedPlayerIds.contains(playerId) ||
          (_includeUnassigned && (playerId == null || playerId.isEmpty));
    }).toList();
  }

  Future<void> _chooseOutput(
    ProjectNotifier notifier, {
    required String mode,
  }) async {
    final merge = mode == 'merge';
    if (_choosingOutput) return;
    setState(() => _choosingOutput = true);
    final videoId = ref.read(projectProvider).video?['id'];
    final playerIds = _playerFilterActive ? _selectedPlayerIds.toList() : null;
    final includeUnassigned = _playerFilterActive ? _includeUnassigned : null;
    try {
      final picker = ref.read(exportOutputPickerProvider);
      final path = await ref
          .read(playbackCoordinatorProvider)
          .withPausedPlayback(() async {
            // Let the paused, offstage previews finish their last Flutter frame
            // before Windows enters the native modal message loop.
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted || !TickerMode.valuesOf(context).enabled) return null;
            return merge
                ? picker.mergedPath(typeLabel: context.bheText('视频'))
                : picker.directory(confirmLabel: context.bheText('选择输出目录'));
          });
      if (!mounted ||
          path == null ||
          ref.read(projectProvider).video?['id'] != videoId) {
        return;
      }
      await notifier.export(
        mode,
        effect: _effect,
        outputPath: merge ? path : null,
        outputDir: merge ? null : path,
        playerIds: playerIds,
        includeUnassigned: includeUnassigned,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.bheText('选择输出位置失败：$error'))),
        );
      }
    } finally {
      if (mounted) setState(() => _choosingOutput = false);
    }
  }
}

bool _isIncluded(Map<String, dynamic> item) =>
    item['selection_status']?.toString() != 'excluded' &&
    item['review_status']?.toString() != 'excluded';

class _ExportSection extends StatelessWidget {
  const _ExportSection({
    required this.title,
    required this.hint,
    required this.child,
  });

  final String title;
  final String hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return CsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(width: Spacing.sm),
              Flexible(
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          child,
        ],
      ),
    );
  }
}

class _GameStatsSection extends StatelessWidget {
  const _GameStatsSection({required this.stats});

  final GameStats stats;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final hitRate = stats.estimatedHitRate;
    final playerRows = [
      for (final item in stats.playerCounts)
        (label: item.name, count: item.count, color: c.player(item.index)),
      if (stats.unassignedCount > 0)
        (
          label: context.bheText('未标记'),
          count: stats.unassignedCount,
          color: c.textTertiary,
        ),
    ];
    final timeRows = [
      for (final bucket in stats.timeBuckets)
        (
          label: context.bheText(
            bucket.segment == null
                ? '${bucket.startMinute}–${bucket.endMinute} 分钟'
                : '第 ${bucket.segment} 段 ${bucket.startMinute}–${bucket.endMinute} 分钟',
          ),
          count: bucket.count,
          color: c.orange,
        ),
    ];
    return _ExportSection(
      title: context.bheText('比赛数据'),
      hint: context.bheText('按当前审核结果统计'),
      child: Column(
        key: const Key('export-game-stats'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _ExportStat(
                  label: context.bheText('候选'),
                  value: '${stats.candidateCount}',
                ),
              ),
              Expanded(
                child: _ExportStat(
                  label: context.bheText('进球（保留）'),
                  value: '${stats.madeCount}',
                ),
              ),
              Expanded(
                child: _ExportStat(
                  label: context.bheText('其中未审核'),
                  value: '${stats.unreviewedCount}',
                ),
              ),
              Expanded(
                child: _ExportStat(
                  label: context.bheText('你排除的'),
                  value: '${stats.manuallyExcludedCount}',
                ),
              ),
              Expanded(
                child: _ExportStat(
                  label: context.bheText('复核判定没进'),
                  value: '${stats.rimRejectedCount}',
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          _ExportStat(
            label: context.bheText('命中率（估算）'),
            value: hitRate == null
                ? '—'
                : '${(hitRate * 100).round()}%  ·  ${stats.madeCount} / ${stats.candidateCount}',
          ),
          const SizedBox(height: 4),
          Text(
            context.bheText('保留的进球 ÷ 全部疑似片段。疑似片段里也有不是投篮的，没碰到篮筐的投篮也不在里面，只是粗略估算。'),
            style: theme.textTheme.labelSmall?.copyWith(color: c.textTertiary),
          ),
          if (playerRows.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            Text(context.bheText('每人进球'), style: theme.textTheme.labelMedium),
            const SizedBox(height: Spacing.xs),
            _CountBars(rows: playerRows),
          ],
          if (timeRows.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            Text(context.bheText('进球时间分布'), style: theme.textTheme.labelMedium),
            const SizedBox(height: Spacing.xs),
            _CountBars(rows: timeRows),
          ],
        ],
      ),
    );
  }
}

class _CountBars extends StatelessWidget {
  const _CountBars({required this.rows});

  final List<({String label, int count, Color color})> rows;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final most = rows.fold<int>(1, (value, row) => row.count > value ? row.count : value);
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 140,
                  child: Text(
                    row.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: row.count / most,
                      child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          color: row.color.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(CsRadius.full),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${row.count}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onSelected,
    this.dot,
    this.dashed = false,
  });

  final String label;
  final int count;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final Color? dot;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return FilterChip(
      showCheckmark: false,
      selected: selected,
      onSelected: onSelected,
      backgroundColor: Colors.transparent,
      selectedColor: c.surface3,
      side: BorderSide(
        color: selected
            ? c.borderStrong
            : dashed
            ? c.borderStrong.withValues(alpha: 0.6)
            : c.border,
      ),
      shape: const StadiumBorder(),
      visualDensity: VisualDensity.compact,
      avatar: dot == null
          ? null
          : Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? c.textPrimary : c.textSecondary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              color: c.textTertiary,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? c.orange.withValues(alpha: 0.08) : c.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.md),
          side: BorderSide(
            color: selected ? c.orange : c.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(CsRadius.md),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: selected ? c.orange : c.textTertiary,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textSecondary,
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

class _ExportStat extends StatelessWidget {
  const _ExportStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ExportNotice extends StatelessWidget {
  const _ExportNotice({
    required this.color,
    required this.text,
    this.action,
    super.key,
  });

  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: color),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(width: Spacing.sm), action!],
        ],
      ),
    );
  }
}

class _RunningExportCard extends StatelessWidget {
  const _RunningExportCard({required this.job, required this.onCancel});

  final Map<String, dynamic>? job;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final progress = ((job?['progress'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      1.0,
    );
    final stage = _exportStageLabel(job?['stage']?.toString() ?? '');
    return Container(
      key: const Key('export-running'),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.orange.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.orange,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  '${l10n?.exportRunningTitle ?? '正在导出'} · '
                  '${l10n?.text(stage) ?? stage} · ${(progress * 100).round()}%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              CsButton(
                label: Text(l10n?.cancelExport ?? '取消导出'),
                icon: LucideIcons.circleStop,
                variant: CsButtonVariant.secondary,
                size: CsButtonSize.sm,
                onPressed: onCancel,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          CsProgressTrack(value: progress),
          const SizedBox(height: Spacing.sm),
          Text(
            l10n?.text('本次输出使用启动导出时的片段列表，之后的审核修改用于下一次导出。') ??
                '本次输出使用启动导出时的片段列表，之后的审核修改用于下一次导出。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportHistoryCard extends StatelessWidget {
  const _ExportHistoryCard({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final mode = switch (item['mode']) {
      'merge' => '合并导出',
      'merge_by_player' => '按标签导出',
      _ => '分别导出',
    };
    final count = (item['candidate_count'] as num?)?.toInt() ?? 0;
    final duration = (item['duration_ms'] as num?)?.toInt() ?? 0;
    final processing = (item['processing_ms'] as num?)?.toInt() ?? 0;
    final fileSize = (item['file_size_bytes'] as num?)?.toInt() ?? 0;
    final width = (item['width'] as num?)?.toInt();
    final height = (item['height'] as num?)?.toInt();
    final videoCodec = item['video_codec']?.toString();
    final audioCodec = item['audio_codec']?.toString();
    final path = item['output_path']?.toString() ?? '';
    final directory = _exportDirectoryPath(item);
    final createdAt = DateTime.tryParse(
      item['created_at']?.toString() ?? '',
    )?.toLocal();
    final time = createdAt == null
        ? ''
        : '${createdAt.month.toString().padLeft(2, '0')}-'
              '${createdAt.day.toString().padLeft(2, '0')} '
              '${createdAt.hour.toString().padLeft(2, '0')}:'
              '${createdAt.minute.toString().padLeft(2, '0')}';

    final meta = [
      _formatMs(duration),
      _formatBytes(fileSize),
      if (width != null && height != null) '$width×$height',
      if (videoCodec != null && videoCodec.isNotEmpty) videoCodec,
      if (audioCodec != null && audioCodec.isNotEmpty) audioCodec,
    ].join(' · ');
    return CsCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_rounded, size: 16, color: c.goal),
                    const SizedBox(width: Spacing.xs),
                    Flexible(
                      child: Text(
                        l10n?.text('$mode · $count 个片段') ??
                            '$mode · $count 个片段',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (time.isNotEmpty) ...[
                      const SizedBox(width: Spacing.sm),
                      Text(
                        time,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.textTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  path,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textTertiary,
                  ),
                ),
                Text(
                  l10n?.text('处理 ${_formatMs(processing)}') ??
                      '处理 ${_formatMs(processing)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.md),
          CsButton(
            label: Text(l10n?.text('打开目录') ?? '打开目录'),
            icon: LucideIcons.folderOpen,
            variant: CsButtonVariant.secondary,
            size: CsButtonSize.sm,
            onPressed: directory == null
                ? null
                : () => _openDirectory(context, directory, targetPath: path),
          ),
        ],
      ),
    );
  }
}

String? _exportDirectoryPath(Map<String, dynamic> item) {
  final metadata = item['metadata'];
  if (metadata is Map) {
    final files = metadata['files'];
    if (files is List) {
      for (final file in files) {
        final filePath = file?.toString().trim() ?? '';
        if (filePath.isNotEmpty) return File(filePath).parent.path;
      }
    }
  }

  final outputPath = item['output_path']?.toString().trim() ?? '';
  if (outputPath.isEmpty) return null;
  if (FileSystemEntity.typeSync(outputPath, followLinks: true) ==
      FileSystemEntityType.directory) {
    return outputPath;
  }
  return File(outputPath).parent.path;
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

Future<void> _openDirectory(
  BuildContext context,
  String directory, {
  String? targetPath,
}) async {
  final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
  try {
    final String? target = targetPath == null || !File(targetPath).existsSync()
        ? null
        : targetPath;
    if (Platform.isMacOS) {
      await Process.start(
        'open',
        target == null ? <String>[directory] : <String>['-R', target],
        mode: ProcessStartMode.detached,
      );
    } else if (Platform.isWindows) {
      await Process.start(
        'explorer.exe',
        target == null ? <String>[directory] : <String>['/select,$target'],
        mode: ProcessStartMode.detached,
      );
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', <String>[
        directory,
      ], mode: ProcessStartMode.detached);
    } else {
      throw UnsupportedError('当前平台不支持打开文件目录');
    }
  } catch (error) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n?.text('无法打开目录') ?? '无法打开目录'),
        content: Text('$directory\n\n${context.bheText(error.toString())}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n?.text('知道了') ?? '知道了'),
          ),
        ],
      ),
    );
  }
}

int _clipDuration(int total, Map<String, dynamic> item) {
  final start =
      (item['review_start_ms'] as num?)?.toInt() ??
      (item['default_start_ms'] as num?)?.toInt() ??
      0;
  final end =
      (item['review_end_ms'] as num?)?.toInt() ??
      (item['default_end_ms'] as num?)?.toInt() ??
      0;
  return total + (end > start ? end - start : 0);
}

const _kEffects = ['none', 'approach', 'replay'];

class _EffectChoice {
  const _EffectChoice(this.value, this.title, this.description);

  final String value;
  final String title;
  final String description;
}

List<_EffectChoice> _effectOptions(BuildContext context) => [
  _EffectChoice(
    'none',
    context.bheText('不加效果'),
    context.bheText('每个片段原样导出。'),
  ),
  _EffectChoice(
    'approach',
    context.bheText('临门慢动作'),
    context.bheText('进球前 1 秒放慢到一半速度，球进框后正常速度。人和球都在原画面里，像电影里的慢镜头。每个进球多约 1.3 秒。'),
  ),
  _EffectChoice(
    'replay',
    context.bheText('慢放特写回放'),
    context.bheText('片段播完后，重播入框前后约 0.8 秒的画面：放慢一倍，取景框住篮筐和球的飞行路线，方便看清球进没进。每个进球多约 1.6 秒。'),
  ),
];

/// 导出总时长，和引擎一致：手动片段不加效果；取不到的片段按原样计。
int _effectDuration(int total, Map<String, dynamic> item, String effect) {
  if (effect == 'none') return _clipDuration(total, item);
  final base = _clipDuration(total, item);
  if (item['detector_version']?.toString().startsWith('manual') == true) return base;
  final event = (item['event_time_ms'] as num?)?.toInt();
  if (event == null) return base;
  final start =
      (item['review_start_ms'] as num?)?.toInt() ??
      (item['default_start_ms'] as num?)?.toInt() ??
      0;
  final end =
      (item['review_end_ms'] as num?)?.toInt() ??
      (item['default_end_ms'] as num?)?.toInt() ??
      0;
  if (effect == 'approach') {
    final window =
        (end < event + 300 ? end : event + 300) -
        (start > event - 1000 ? start : event - 1000);
    return window >= 300 ? base + window : base;
  }
  final window =
      (end < event + 300 ? end : event + 300) -
      (start > event - 500 ? start : event - 500);
  return window >= 300 ? base + window * 2 : base;
}

class _EffectOption extends StatelessWidget {
  const _EffectOption({
    super.key,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String description;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(CsRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? c.orange : c.textTertiary,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      height: 1.4,
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
}

String _formatMs(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}'
      : '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}

String _exportStageLabel(String stage) =>
    const <String, String>{
      'validate_input': '准备导出',
      'export_clips': '生成片段',
      'merge_clips': '合并片段',
      'persist_export': '保存导出记录',
    }[stage] ??
    '正在导出';
