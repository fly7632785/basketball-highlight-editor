import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/cs_button.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_skeleton.dart';
import '../../components/cs_workspace.dart';
import '../../components/media_project_row.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({this.onProjectOpened, super.key});

  final VoidCallback? onProjectOpened;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final busy = state.busy || state.exportRunning || state.analysisRunning;

    Future<void> openProject() async {
      if (await notifier.chooseOpenProject()) onProjectOpened?.call();
    }

    Future<void> startNewProject() async {
      if (await notifier.startNewProject() && context.mounted) {
        context.go('/import');
      }
    }

    Future<void> openRecentProject(String root) async {
      if (await notifier.openProject(root)) onProjectOpened?.call();
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
          content: Text('将删除“$name”的分析记录和导出文件，原始视频不会被删除。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.of(dialogContext).error,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除项目'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await notifier.deleteProject(root);
      await notifier.loadRecentProjects();
    }

    return CsWorkspace(
      title: '项目库',
      subtitle: state.recentLoading ? '正在同步本机项目' : '本机项目',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新最近项目',
          onPressed: state.recentLoading || busy
              ? null
              : () => notifier.loadRecentProjects(),
          icon: const Icon(CupertinoIcons.arrow_clockwise),
        ),
        CsButton(
          label: const Text('打开项目'),
          icon: CupertinoIcons.folder_open,
          variant: CsButtonVariant.secondary,
          onPressed: busy ? null : openProject,
        ),
        CsButton(
          label: const Text('新建项目'),
          icon: CupertinoIcons.add,
          onPressed: busy ? null : startNewProject,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (state.video != null) ...<Widget>[
            _ActiveProjectStrip(state: state),
            const SizedBox(height: Spacing.lg),
          ],
          Row(
            children: <Widget>[
              Text('最近使用', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: Spacing.sm),
              Text(
                '${state.recentProjects.length} 个项目',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.of(context).textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Expanded(
            child: _ProjectLibrary(
              state: state,
              busy: busy,
              onOpen: openRecentProject,
              onDelete: deleteRecentProject,
              onCreate: startNewProject,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveProjectStrip extends StatelessWidget {
  const _ActiveProjectStrip({required this.state});

  final ProjectState state;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final included = state.candidates
        .where(
          (item) =>
              item['selection_status']?.toString() != 'excluded' &&
              item['review_status']?.toString() != 'excluded',
        )
        .length;
    final duration = (state.video?['duration_ms'] as num?)?.toInt() ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 11),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(CupertinoIcons.play_rectangle, color: c.indigo, size: 18),
          const SizedBox(width: Spacing.sm),
          Text('当前项目', style: Theme.of(context).textTheme.labelLarge),
          const Spacer(),
          _StripMetric(label: '时长', value: _formatDuration(duration)),
          const SizedBox(width: Spacing.lg),
          _StripMetric(label: '候选', value: '${state.candidates.length}'),
          const SizedBox(width: Spacing.lg),
          _StripMetric(label: '已保留', value: '$included', color: c.goal),
        ],
      ),
    );
  }
}

class _StripMetric extends StatelessWidget {
  const _StripMetric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Text.rich(
      TextSpan(
        text: '$label  ',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
        children: <InlineSpan>[
          TextSpan(
            text: value,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color ?? c.textPrimary,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectLibrary extends StatelessWidget {
  const _ProjectLibrary({
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
      return const _RecentSkeletonList();
    }
    if (state.recentProjects.isEmpty) {
      return CsEmptyState(
        icon: CupertinoIcons.rectangle_stack_badge_plus,
        title: state.recentError != null ? '加载最近项目失败' : '还没有项目',
        description: state.recentError ?? '新建一个项目后，视频、审核记录和导出历史都会保存在这里。',
        action: CsButton(
          label: const Text('新建项目'),
          icon: CupertinoIcons.add,
          onPressed: busy ? null : onCreate,
        ),
      );
    }
    final c = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: state.recentProjects.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
        itemBuilder: (context, index) {
          final item = state.recentProjects[index];
          final project = _map(item['project']);
          final video = _map(item['video']);
          final statistics = _map(item['statistics']);
          final root = item['project_root']?.toString() ?? '';
          final source = video['source_path']?.toString();
          return MediaProjectRow(
            name: project['name']?.toString() ?? '未命名项目',
            sourceName: source?.split('/').last,
            duration: _formatDuration(_int(video['duration_ms'])),
            candidates: _int(statistics['candidate_count']),
            included: statistics['included_count'] == null
                ? _int(statistics['goal_count'])
                : _int(statistics['included_count']),
            onOpen: busy || root.isEmpty ? null : () => onOpen(root),
            onDelete: busy || root.isEmpty ? null : () => onDelete(item),
          );
        },
      ),
    );
  }
}

class _RecentSkeletonList extends StatelessWidget {
  const _RecentSkeletonList();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(Spacing.md),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(height: Spacing.md),
        itemBuilder: (_, _) => const Row(
          children: <Widget>[
            CsSkeleton(width: 76, height: 48),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  CsSkeleton(width: 156, height: 14),
                  SizedBox(height: 7),
                  CsSkeleton(width: 220, height: 10),
                ],
              ),
            ),
            CsSkeleton(width: 70, height: 24),
          ],
        ),
      ),
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
    return '$hours:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}
