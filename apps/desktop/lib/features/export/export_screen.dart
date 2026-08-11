import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/cs_button.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_workspace.dart';
import '../../components/export_summary.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

class ExportScreen extends ConsumerWidget {
  const ExportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final included = state.candidates.where(_included).toList();
    final includedCount = included.length;
    final durationMs = included.fold<int>(0, _clipDuration);
    final running = state.exportRunning;
    final recoverable = state.exportJob?['recoverable'] == true && !running;
    final progress = ((state.exportJob?['progress'] as num?)?.toDouble() ?? 0)
        .clamp(0.0, 1.0);
    final busy =
        state.busy || running || state.analysisRunning || state.hydrating;
    final summary = ExportSummary(
      includedCount: includedCount,
      duration: _formatMs(durationMs),
      running: running,
      recoverable: recoverable,
      busy: busy,
      progress: progress,
      stageLabel: _exportStageLabel(
        state.exportJob?['stage']?.toString() ?? '',
      ),
      onMerge: includedCount > 0 && !busy
          ? () => _chooseMerge(context, notifier)
          : null,
      onSeparate: includedCount > 0 && !busy
          ? () => _chooseSeparate(context, notifier)
          : null,
      onCancel: state.busy ? null : () => notifier.cancelExport(),
      onRetry: state.busy ? null : () => notifier.retryExport(),
    );
    final history = _ExportHistory(state: state);
    return CsWorkspace(
      title: '导出集锦',
      subtitle: '$includedCount 个片段 · ${_formatMs(durationMs)}',
      actions: <Widget>[
        CsButton(
          label: const Text('返回审核'),
          icon: CupertinoIcons.chevron_left,
          variant: CsButtonVariant.secondary,
          size: CsButtonSize.sm,
          onPressed: () => context.go('/review'),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= Breakpoints.lg) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: summary),
                const SizedBox(width: Spacing.md),
                SizedBox(width: 340, child: history),
              ],
            );
          }
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                summary,
                const SizedBox(height: Spacing.lg),
                history,
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _chooseMerge(
    BuildContext context,
    ProjectNotifier notifier,
  ) async {
    final location = await getSaveLocation(
      suggestedName: 'highlights.mp4',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: '视频', extensions: <String>['mp4']),
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

class _ExportHistory extends StatelessWidget {
  const _ExportHistory({required this.state});

  final ProjectState state;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (state.exportHistory.isEmpty) {
      return const CsEmptyState(
        icon: CupertinoIcons.clock,
        title: '还没有导出记录',
        description: '完成一次导出后，最近输出会显示在这里。',
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              Spacing.sm,
            ),
            child: Row(
              children: <Widget>[
                Text('最近导出', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text(
                  '${state.exportHistory.length} 条',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          for (
            var index = 0;
            index < state.exportHistory.length;
            index++
          ) ...<Widget>[
            _ExportHistoryRow(item: state.exportHistory[index]),
            if (index < state.exportHistory.length - 1)
              Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }
}

class _ExportHistoryRow extends StatelessWidget {
  const _ExportHistoryRow({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final mode = item['mode'] == 'merge' ? '合并导出' : '分别导出';
    final count = (item['candidate_count'] as num?)?.toInt() ?? 0;
    final duration = (item['duration_ms'] as num?)?.toInt() ?? 0;
    final path = item['output_path']?.toString() ?? '';
    final directory = _exportDirectoryPath(item);
    return Padding(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.indigo.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(CsRadius.sm),
            ),
            child: Icon(CupertinoIcons.film, size: 16, color: c.indigo),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$mode · $count 个片段 · ${_formatMs(duration)}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 3),
                Text(
                  path.isEmpty ? '输出文件不可用' : path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '打开目录',
            onPressed: directory == null
                ? null
                : () => _openDirectory(context, directory),
            icon: const Icon(CupertinoIcons.folder_open),
          ),
        ],
      ),
    );
  }
}

bool _included(Map<String, dynamic> item) =>
    item['selection_status']?.toString() != 'excluded' &&
    item['review_status']?.toString() != 'excluded';

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

Future<void> _openDirectory(BuildContext context, String directory) async {
  try {
    final ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('open', <String>[directory]);
    } else if (Platform.isWindows) {
      result = await Process.run('explorer.exe', <String>[directory]);
    } else if (Platform.isLinux) {
      result = await Process.run('xdg-open', <String>[directory]);
    } else {
      throw UnsupportedError('当前平台不支持打开文件目录');
    }
    if (result.exitCode != 0) throw StateError(result.stderr.toString().trim());
  } catch (error) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法打开目录'),
        content: Text('$directory\n\n$error'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
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
    '准备导出';
