import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_metric_tile.dart';
import '../../components/cs_skeleton.dart';
import '../../components/cs_status_chip.dart';
import '../../components/cs_step_indicator.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// Home 屏:Hero slogan + 主 CTA / 当前项目 metrics / 最近项目网格 / 工作流指示。
///
/// 所有数据来自 [projectProvider];导航用 `context.go`,打开项目走
/// `ProjectNotifier.chooseOpenProject` / `openProject`(目录选择器在 notifier 内)。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({this.onProjectOpened, super.key});

  final VoidCallback? onProjectOpened;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final c = AppColors.of(context);
    final theme = Theme.of(context);

    final included = state.candidates
        .where((it) => it['selection_status']?.toString() != 'excluded' &&
            it['review_status']?.toString() != 'excluded')
        .length;
    final excluded = state.candidates
        .where((it) => it['selection_status']?.toString() == 'excluded' ||
            it['review_status']?.toString() == 'excluded')
        .length;
    final durationMs = (state.video?['duration_ms'] as num?)?.toInt() ?? 0;
    final busy = state.busy;

    Future<void> openProject() async {
      if (await notifier.chooseOpenProject()) onProjectOpened?.call();
    }

    Future<void> openRecentProject(String root) async {
      await notifier.openProject(root);
      if (ref.read(projectProvider).videoPath != null) {
        onProjectOpened?.call();
      }
    }

    Future<void> deleteRecentProject(Map<String, dynamic> item) async {
      final root = item['project_root']?.toString() ?? '';
      if (root.isEmpty) return;
      final project = _map(item['project']);
      final name = project['name']?.toString() ?? '未命名项目';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除项目？'),
          content: Text('将删除“$name”的项目数据库、分析缓存和导出文件，原始视频不会被删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除项目'),
            ),
          ],
        ),
      );
      if (confirmed == true) await notifier.deleteProject(root);
    }

    final steps = <CsStep>[
      (
        index: '01',
        title: '导入视频',
        icon: LucideIcons.upload,
        completed: state.video != null,
      ),
      (
        index: '02',
        title: '框选 ROI',
        icon: LucideIcons.crop,
        completed: state.roiSource != null,
      ),
      (
        index: '03',
        title: '分析扫描',
        icon: LucideIcons.scanLine,
        completed: state.job?['state'] == 'completed',
      ),
      (
        index: '04',
        title: '审核候选',
        icon: LucideIcons.checkCheck,
        completed: state.candidates.isNotEmpty,
      ),
      (
        index: '05',
        title: '导出集锦',
        icon: LucideIcons.share,
        completed: state.exportHistory.isNotEmpty,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Hero ──
              Text('把整场比赛，变成你的高光。', style: theme.textTheme.displayLarge),
              const SizedBox(height: Spacing.sm),
              Text(
                '导入固定机位视频，本地分析候选进球，剔除误检后导出集锦。'
                '所有处理在本机完成，原始视频不会被复制或上传。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.xxl),

              // ── 主 CTA + 当前项目 metrics ──
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= Breakpoints.md;
                  final ctaCard = CsCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              LucideIcons.sparkles,
                              size: 20,
                              color: c.indigo,
                            ),
                            const SizedBox(width: Spacing.sm),
                            Text('从视频开始', style: theme.textTheme.titleLarge),
                          ],
                        ),
                        const SizedBox(height: Spacing.sm),
                        Text(
                          '选择一段固定机位录像，系统会优先自动定位篮筐，'
                          '随后生成候选进球片段供你审核与导出。',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                        const SizedBox(height: Spacing.lg),
                        Wrap(
                          spacing: Spacing.sm,
                          runSpacing: Spacing.sm,
                          children: [
                            CsButton(
                              label: const Text('新建项目'),
                              icon: LucideIcons.plus,
                              onPressed: busy
                                  ? null
                                  : () => context.go('/import'),
                            ),
                            CsButton(
                              label: const Text('打开项目'),
                              icon: LucideIcons.folderOpen,
                              variant: CsButtonVariant.secondary,
                              onPressed: busy ? null : openProject,
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                  final metricsCard = CsCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('当前项目', style: theme.textTheme.titleMedium),
                        const SizedBox(height: Spacing.md),
                        CsMetricTile(
                          label: '当前保留',
                          value: '$included',
                          icon: LucideIcons.check,
                        ),
                        CsMetricTile(
                          label: '已排除',
                          value: '$excluded',
                          icon: LucideIcons.x,
                        ),
                        CsMetricTile(
                          label: '视频时长',
                          value: _formatDuration(durationMs),
                          icon: LucideIcons.clock,
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          '本地 SQLite · 原始视频不复制',
                          style: TextStyle(color: c.textTertiary, fontSize: 11),
                        ),
                      ],
                    ),
                  );
                  if (wide) {
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 3, child: ctaCard),
                          const SizedBox(width: Spacing.md),
                          Expanded(flex: 2, child: metricsCard),
                        ],
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ctaCard,
                      const SizedBox(height: Spacing.md),
                      metricsCard,
                    ],
                  );
                },
              ),
              const SizedBox(height: Spacing.xxl),

              // ── 最近项目 ──
              Row(
                children: [
                  Expanded(
                    child: Text('最近项目', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '刷新最近项目',
                    onPressed: state.recentLoading || busy
                        ? null
                        : () => notifier.loadRecentProjects(),
                    icon: const Icon(LucideIcons.refreshCw, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              _RecentProjects(
                state: state,
                busy: busy,
                onOpen: openRecentProject,
                onDelete: deleteRecentProject,
                onCreate: () => context.go('/import'),
              ),
              const SizedBox(height: Spacing.xxl),

              // ── 工作流 ──
              Text('工作流', style: theme.textTheme.titleMedium),
              const SizedBox(height: Spacing.md),
              CsStepIndicator(steps: steps),
              const SizedBox(height: Spacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最近项目区域:加载(CsSkeleton) / 空(CsEmptyState) / 错(CsEmptyState) / 网格。
class _RecentProjects extends StatelessWidget {
  const _RecentProjects({
    required this.state,
    required this.busy,
    required this.onOpen,
    required this.onDelete,
    required this.onCreate,
  });

  final ProjectState state;
  final bool busy;
  final Future<void> Function(String root) onOpen;
  final Future<void> Function(Map<String, dynamic> item) onDelete;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    if (state.recentLoading && state.recentProjects.isEmpty) {
      return const _RecentSkeletonGrid();
    }
    if (state.recentProjects.isEmpty) {
      return CsEmptyState(
        icon: LucideIcons.folderOpen,
        title: state.recentError != null ? '加载最近项目失败' : '还没有项目',
        description: state.recentError ?? '新建一个项目后，分析记录和导出历史会显示在这里。',
        action: CsButton(label: const Text('新建项目'), onPressed: onCreate),
      );
    }
    return _RecentGrid(
      projects: state.recentProjects,
      onOpen: busy ? null : onOpen,
      onDelete: busy ? null : onDelete,
    );
  }
}

class _RecentGrid extends StatelessWidget {
  const _RecentGrid({
    required this.projects,
    required this.onOpen,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> projects;
  final Future<void> Function(String root)? onOpen;
  final Future<void> Function(Map<String, dynamic> item)? onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 900
            ? 3
            : (constraints.maxWidth >= 560 ? 2 : 1);
        final rows = <Widget>[];
        for (var i = 0; i < projects.length; i += cols) {
          final cells = <Widget>[];
          for (var j = 0; j < cols; j++) {
            final index = i + j;
            if (index < projects.length) {
              cells.add(
                Expanded(
                  child: _ProjectCard(
                    item: projects[index],
                    onOpen: onOpen,
                    onDelete: onDelete,
                  ),
                ),
              );
            } else {
              cells.add(const Expanded(child: SizedBox.shrink()));
            }
          }
          rows.add(
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
          );
          if (i + cols < projects.length) {
            rows.add(const SizedBox(height: Spacing.md));
          }
        }
        return Column(children: rows);
      },
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.item,
    required this.onOpen,
    required this.onDelete,
  });

  final Map<String, dynamic> item;
  final Future<void> Function(String root)? onOpen;
  final Future<void> Function(Map<String, dynamic> item)? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final project = _map(item['project']);
    final video = _map(item['video']);
    final statistics = _map(item['statistics']);
    final root = item['project_root']?.toString() ?? '';
    final name = project['name']?.toString() ?? '未命名项目';
    final goals = statistics['included_count'] == null
        ? _int(statistics['goal_count'])
        : _int(statistics['included_count']);
    final candidates = _int(statistics['candidate_count']);
    final duration = _int(video['duration_ms']);
    final source = video['source_path']?.toString();
    final videoName = (source == null || source.isEmpty)
        ? null
        : source.split('/').last;

    return CsCard(
      onTap: (onOpen == null || root.isEmpty) ? null : () => onOpen!(root),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.folder, size: 16, color: c.textTertiary),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onDelete != null && root.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: '项目操作',
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'delete') onDelete!(item);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem<String>(value: 'delete', child: Text('删除项目')),
                  ],
                  icon: const Icon(LucideIcons.moreVertical, size: 18),
                ),
              if (goals > 0)
                const CsStatusChip(status: ReviewStatus.goal, compact: true),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          if (videoName != null)
            Text(
              videoName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: Spacing.xs),
          Text(
            '$goals 保留 · $candidates 候选 · ${_formatDuration(duration)}',
            style: theme.textTheme.bodySmall?.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _RecentSkeletonGrid extends StatelessWidget {
  const _RecentSkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 900
            ? 3
            : (constraints.maxWidth >= 560 ? 2 : 1);
        final cells = <Widget>[];
        for (var i = 0; i < cols; i++) {
          cells.add(
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    CsSkeleton(width: 120, height: 16),
                    SizedBox(height: Spacing.md),
                    CsSkeleton(width: double.infinity, height: 12),
                    SizedBox(height: Spacing.xs),
                    CsSkeleton(width: 180, height: 12),
                  ],
                ),
              ),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: cells,
        );
      },
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

String _formatDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remaining.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remaining.toString().padLeft(2, '0')}';
}
