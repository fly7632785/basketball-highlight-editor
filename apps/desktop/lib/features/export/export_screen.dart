import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_metric_tile.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// Export 屏:汇总已确认片段 + 合并/分别导出 CTA + 历史。
///
/// 数据来自 [projectProvider];导出走 `ProjectNotifier.export(mode:)`,
/// 返回审核用 `context.go('/review')`。
class ExportScreen extends ConsumerWidget {
  const ExportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final theme = Theme.of(context);
    final c = AppColors.of(context);

    final goalCount = state.candidates
        .where((item) => item['review_status'] == 'goal')
        .length;
    final durationMs = state.candidates
        .where((item) => item['review_status'] == 'goal')
        .fold<int>(0, _clipDuration);
    final busy = state.busy;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('导出集锦', style: theme.textTheme.displayMedium),
              const SizedBox(height: Spacing.sm),
              Text(
                '只导出人工确认的进球片段。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.xxl),

              CsCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CsMetricTile(
                      label: '已确认片段',
                      value: '$goalCount 个',
                      icon: LucideIcons.check,
                    ),
                    CsMetricTile(
                      label: '合计时长',
                      value: _formatMs(durationMs),
                      icon: LucideIcons.clock,
                    ),
                    const CsMetricTile(
                      label: '输出编码',
                      value: 'H.264 / AAC',
                      icon: LucideIcons.fileVideo,
                    ),
                    const CsMetricTile(
                      label: '处理方式',
                      value: '硬件编码优先，软件回退',
                      icon: LucideIcons.cpu,
                    ),
                    const SizedBox(height: Spacing.sm),
                    CsButton(
                      label: const Text('合并导出'),
                      icon: LucideIcons.merge,
                      isLoading: busy,
                      onPressed: goalCount > 0 && !busy
                          ? () => _chooseMerge(context, notifier)
                          : null,
                    ),
                    const SizedBox(height: Spacing.sm),
                    CsButton(
                      label: const Text('分别导出'),
                      icon: LucideIcons.files,
                      variant: CsButtonVariant.secondary,
                      isLoading: busy,
                      onPressed: goalCount > 0 && !busy
                          ? () => _chooseSeparate(context, notifier)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.md),
              Text(
                '导出前只会使用"已确认"候选；待审核和已排除片段不会进入输出。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.md),
              CsButton(
                label: const Text('返回审核'),
                icon: LucideIcons.arrowLeft,
                variant: CsButtonVariant.ghost,
                onPressed: () => context.go('/review'),
              ),

              // ── 历史 ──
              if (state.exportHistory.isNotEmpty) ...[
                const SizedBox(height: Spacing.xxl),
                Text('最近导出', style: theme.textTheme.titleLarge),
                const SizedBox(height: Spacing.md),
                for (final item in state.exportHistory)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.sm),
                    child: _ExportHistoryCard(item: item),
                  ),
              ] else ...[
                const SizedBox(height: Spacing.xxl),
                const CsEmptyState(
                  icon: LucideIcons.history,
                  title: '还没有导出记录',
                  description: '完成一次导出后，历史记录会出现在这里。',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _chooseMerge(
    BuildContext context,
    ProjectNotifier notifier,
  ) async {
    final location = await getSaveLocation(
      suggestedName: 'highlights.mp4',
      acceptedTypeGroups: const [
        XTypeGroup(label: '视频', extensions: ['mp4']),
      ],
    );
    if (location != null) {
      await notifier.export('merge', outputPath: location.path);
    }
  }

  Future<void> _chooseSeparate(
    BuildContext context,
    ProjectNotifier notifier,
  ) async {
    final directory = await getDirectoryPath(confirmButtonText: '选择输出目录');
    if (directory != null) {
      await notifier.export('separate', outputDir: directory);
    }
  }
}

class _ExportHistoryCard extends StatelessWidget {
  const _ExportHistoryCard({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final mode = item['mode'] == 'merge' ? '合并导出' : '分别导出';
    final count = (item['candidate_count'] as num?)?.toInt() ?? 0;
    final duration = (item['duration_ms'] as num?)?.toInt() ?? 0;
    final processing = (item['processing_ms'] as num?)?.toInt() ?? 0;
    final path = item['output_path']?.toString() ?? '';
    final createdAt = DateTime.tryParse(
      item['created_at']?.toString() ?? '',
    )?.toLocal();
    final time = createdAt == null
        ? ''
        : '${createdAt.month.toString().padLeft(2, '0')}-'
            '${createdAt.day.toString().padLeft(2, '0')} '
            '${createdAt.hour.toString().padLeft(2, '0')}:'
            '${createdAt.minute.toString().padLeft(2, '0')}';

    return CsCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.history, size: 18, color: c.textTertiary),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$mode · $count 个片段 · ${_formatMs(duration)}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: Spacing.xs),
                SelectableText(
                  path,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textSecondary,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  '${time.isEmpty ? '' : '$time · '}处理 ${_formatMs(processing)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

int _clipDuration(int total, Map<String, dynamic> item) {
  final start = (item['review_start_ms'] as num?)?.toInt() ??
      (item['default_start_ms'] as num?)?.toInt() ??
      0;
  final end = (item['review_end_ms'] as num?)?.toInt() ??
      (item['default_end_ms'] as num?)?.toInt() ??
      0;
  return total + (end > start ? end - start : 0);
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
