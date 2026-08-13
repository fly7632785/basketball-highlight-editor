import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_metric_tile.dart';
import '../../components/cs_progress_track.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

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
  bool _showFastRisk = true;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final theme = Theme.of(context);
    final c = AppColors.of(context);

    final includedCandidates = _filteredCandidates(state);
    final includedCount = includedCandidates.length;
    final durationMs = includedCandidates.fold<int>(0, _clipDuration);
    final exportRunning = state.exportRunning;
    final exportRecoverable =
        state.exportJob?['recoverable'] == true && !exportRunning;
    final exportProgress =
        ((state.exportJob?['progress'] as num?)?.toDouble() ?? 0).clamp(
          0.0,
          1.0,
        );
    final exportStage = state.exportJob?['stage']?.toString() ?? '';
    final busy =
        state.busy || exportRunning || state.analysisRunning || state.hydrating;

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
                '分析结果默认保留，导出时只排除你打叉的片段。',
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
                      label: '当前保留',
                      value: '$includedCount 个',
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
                    if (state.players.isNotEmpty) ...[
                      const SizedBox(height: Spacing.md),
                      Text('导出范围', style: theme.textTheme.titleSmall),
                      const SizedBox(height: Spacing.xs),
                      Wrap(
                        spacing: Spacing.xs,
                        runSpacing: Spacing.xs,
                        children: [
                          FilterChip(
                            label: const Text('全部球员'),
                            selected: !_playerFilterActive,
                            onSelected: (_) => setState(() {
                              _playerFilterActive = false;
                              _selectedPlayerIds.clear();
                              _includeUnassigned = true;
                            }),
                          ),
                          for (final player in state.players)
                            FilterChip(
                              label: Text(player['name']?.toString() ?? ''),
                              selected: _selectedPlayerIds.contains(
                                player['id']?.toString(),
                              ),
                              onSelected: (value) => setState(() {
                                _playerFilterActive = true;
                                final id = player['id']?.toString();
                                if (id == null) return;
                                if (value) {
                                  _selectedPlayerIds.add(id);
                                  _includeUnassigned = false;
                                } else {
                                  _selectedPlayerIds.remove(id);
                                }
                              }),
                            ),
                          FilterChip(
                            label: const Text('未标记'),
                            selected: _playerFilterActive && _includeUnassigned,
                            onSelected: (value) => setState(() {
                              _playerFilterActive = true;
                              _includeUnassigned = value;
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        '当前筛选：$includedCount 个 · ${_formatMs(durationMs)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                    if (exportRunning) ...[
                      const SizedBox(height: Spacing.sm),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(Spacing.sm),
                        decoration: BoxDecoration(
                          color: c.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(CsRadius.md),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${_exportStageLabel(exportStage)} · '
                                    '${(exportProgress * 100).round()}%\n'
                                    '本次输出使用启动导出时的片段列表，之后的审核修改用于下一次导出。',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: c.textSecondary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: Spacing.sm),
                                CsButton(
                                  label: const Text('取消导出'),
                                  icon: LucideIcons.circleStop,
                                  variant: CsButtonVariant.secondary,
                                  size: CsButtonSize.sm,
                                  onPressed: state.busy
                                      ? null
                                      : () => notifier.cancelExport(),
                                ),
                              ],
                            ),
                            const SizedBox(height: Spacing.sm),
                            CsProgressTrack(value: exportProgress),
                          ],
                        ),
                      ),
                    ],
                    if (state.analysisRunning) ...[
                      const SizedBox(height: Spacing.sm),
                      Text(
                        '视频仍在分析，分析完成后才能导出新的候选结果。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: c.warning,
                        ),
                      ),
                    ],
                    if (state.analysisMode == 'fast' && _showFastRisk) ...[
                      const SizedBox(height: Spacing.sm),
                      Container(
                        key: const Key('fast-analysis-export-risk'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(Spacing.sm),
                        decoration: BoxDecoration(
                          color: c.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(CsRadius.md),
                          border: Border.all(
                            color: c.warning.withValues(alpha: 0.28),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 17,
                              color: c.warning,
                            ),
                            const SizedBox(width: Spacing.sm),
                            Expanded(
                              child: Text(
                                '当前结果来自快速分析，可能漏检；如需更完整结果，建议先用标准模式重新分析。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: c.textSecondary,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭提示',
                              onPressed: () =>
                                  setState(() => _showFastRisk = false),
                              icon: const Icon(Icons.close, size: 16),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (exportRecoverable) ...[
                      const SizedBox(height: Spacing.sm),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(Spacing.sm),
                        decoration: BoxDecoration(
                          color: c.warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(CsRadius.md),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '上次导出已中断，可以从原设置重新导出。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: c.textSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(width: Spacing.sm),
                            CsButton(
                              label: const Text('重试导出'),
                              icon: LucideIcons.refreshCw,
                              size: CsButtonSize.sm,
                              onPressed: busy
                                  ? null
                                  : () => notifier.retryExport(),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: Spacing.sm),
                    CsButton(
                      label: const Text('合并导出'),
                      icon: LucideIcons.merge,
                      isLoading: busy,
                      onPressed: includedCount > 0 && !busy
                          ? () => _chooseMerge(context, notifier)
                          : null,
                    ),
                    const SizedBox(height: Spacing.sm),
                    CsButton(
                      label: const Text('分别导出'),
                      icon: LucideIcons.files,
                      variant: CsButtonVariant.secondary,
                      isLoading: busy,
                      onPressed: includedCount > 0 && !busy
                          ? () => _chooseSeparate(context, notifier)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.md),
              Text(
                exportRunning
                    ? '导出任务在后台运行，返回审核后仍可继续修改候选。'
                    : '导出会包含所有当前保留的候选；已排除片段不会进入输出。',
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
      await notifier.export(
        'merge',
        outputPath: location.path,
        playerIds: _playerFilterActive ? _selectedPlayerIds.toList() : null,
        includeUnassigned: _playerFilterActive ? _includeUnassigned : null,
      );
    }
  }

  List<Map<String, dynamic>> _filteredCandidates(ProjectState state) {
    return state.candidates.where(_isIncluded).where((item) {
      if (!_playerFilterActive) return true;
      final playerId = item['player_id']?.toString();
      return _selectedPlayerIds.contains(playerId) ||
          (_includeUnassigned && (playerId == null || playerId.isEmpty));
    }).toList();
  }

  Future<void> _chooseSeparate(
    BuildContext context,
    ProjectNotifier notifier,
  ) async {
    final directory = await getDirectoryPath(confirmButtonText: '选择输出目录');
    if (directory != null) {
      await notifier.export(
        'separate',
        outputDir: directory,
        playerIds: _playerFilterActive ? _selectedPlayerIds.toList() : null,
        includeUnassigned: _playerFilterActive ? _includeUnassigned : null,
      );
    }
  }
}

bool _isIncluded(Map<String, dynamic> item) =>
    item['selection_status']?.toString() != 'excluded' &&
    item['review_status']?.toString() != 'excluded';

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
                const SizedBox(height: Spacing.xs),
                Text(
                  [
                    _formatBytes(fileSize),
                    if (width != null && height != null) '$width×$height',
                    if (videoCodec != null && videoCodec.isNotEmpty) videoCodec,
                    if (audioCodec != null && audioCodec.isNotEmpty) audioCodec,
                  ].join(' · '),
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
            label: const Text('打开目录'),
            icon: LucideIcons.folderOpen,
            variant: CsButtonVariant.secondary,
            size: CsButtonSize.sm,
            onPressed: directory == null
                ? null
                : () => _openDirectory(context, directory),
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

    if (result.exitCode != 0) {
      throw StateError(result.stderr.toString().trim());
    }
  } catch (error) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法打开目录'),
        content: Text('$directory\n\n$error'),
        actions: [
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
    '正在导出';
