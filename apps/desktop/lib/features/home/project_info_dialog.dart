import 'dart:io';

import 'package:flutter/material.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';
import 'project_name_dialog.dart';

/// 项目信息面板：一眼看清这个项目是什么、有多大、存在哪。
///
/// 数据全部来自已有的 `statistics`，不额外请求引擎。
class ProjectInfoDialog extends StatelessWidget {
  const ProjectInfoDialog({
    super.key,
    required this.name,
    required this.statistics,
    required this.videos,
    required this.candidates,
    required this.onRename,
  });

  final String name;
  final Map<String, dynamic> statistics;
  final List<Map<String, dynamic>> videos;
  final List<Map<String, dynamic>> candidates;
  final Future<bool> Function(String name) onRename;

  static Future<void> show(
    BuildContext context, {
    required String name,
    required Map<String, dynamic> statistics,
    required List<Map<String, dynamic>> videos,
    required List<Map<String, dynamic>> candidates,
    required Future<bool> Function(String name) onRename,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => ProjectInfoDialog(
        name: name,
        statistics: statistics,
        videos: videos,
        candidates: candidates,
        onRename: onRename,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final project = _map(statistics['project']);
    final root = project['root_path']?.toString() ?? '';
    final createdAt = DateTime.tryParse(
      project['created_at']?.toString() ?? '',
    )?.toLocal();
    final candidateCount = candidates.isEmpty
        ? _int(statistics['candidate_count'])
        : candidates.length;
    final goalCount = _int(statistics['goal_count']);
    final includedCount = _int(statistics['included_count']);
    final totalDurationMs = videos.fold<int>(
      0,
      (sum, video) => sum + _int(video['duration_ms']),
    );

    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(l10n?.projectInfo ?? '项目信息')),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: l10n?.renameProject ?? '重命名项目',
            onPressed: () async {
              final renamed = await showProjectNameDialog(
                context,
                initialName: name,
                onSubmit: onRename,
              );
              if (renamed != null && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row(label: l10n?.projectName ?? '项目名称', value: name),
            _Row(
              label: l10n?.projectCreatedAt ?? '创建时间',
              value: createdAt == null ? '—' : _formatDateTime(createdAt),
            ),
            _Row(
              label: l10n?.projectVideoCount ?? '视频段数',
              value: videos.isEmpty
                  ? '—'
                  : '${videos.length} ${l10n?.projectSegmentsUnit ?? '段'}'
                        ' · ${_formatDuration(totalDurationMs)}',
            ),
            _Row(
              label: l10n?.homeCandidates ?? '候选',
              value: '$candidateCount',
            ),
            _Row(
              label: l10n?.projectGoalsConfirmed ?? '已确认进球',
              value: '$goalCount',
              color: goalCount > 0 ? c.goal : null,
            ),
            _Row(
              label: l10n?.homeKept ?? '保留',
              value: '$includedCount',
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              l10n?.projectStorageLocation ?? '存储位置',
              style: theme.textTheme.labelSmall?.copyWith(
                color: c.textTertiary,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    root.isEmpty ? '—' : root,
                    maxLines: 2,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                ),
                if (root.isNotEmpty)
                  TextButton(
                    onPressed: () => _revealInExplorer(root),
                    child: Text(l10n?.openFolder ?? '打开文件夹'),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n?.close ?? '关闭'),
        ),
      ],
    );
  }

  static Future<void> _revealInExplorer(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {
      // 打不开文件管理器不影响面板本身。
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

int _int(Object? value) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '') ?? 0;

String _formatDateTime(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _formatDuration(int milliseconds) {
  if (milliseconds <= 0) return '0:00';
  final total = milliseconds ~/ 1000;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
}
