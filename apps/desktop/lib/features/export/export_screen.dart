import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class ExportScreen extends StatelessWidget {
  const ExportScreen({
    required this.candidates,
    required this.busy,
    required this.onExport,
    this.exportHistory = const [],
    required this.onBackToReview,
    super.key,
  });
  final List<Map<String, dynamic>> candidates;
  final bool busy;
  final Future<void> Function(String, {String? outputDir, String? outputPath})
  onExport;
  final VoidCallback onBackToReview;
  final List<Map<String, dynamic>> exportHistory;

  int get _goalCount =>
      candidates.where((item) => item['review_status'] == 'goal').length;

  int get _durationMs => candidates
      .where((item) => item['review_status'] == 'goal')
      .fold<int>(0, (total, item) {
        final start =
            (item['review_start_ms'] as num?)?.toInt() ??
            (item['default_start_ms'] as num?)?.toInt() ??
            0;
        final end =
            (item['review_end_ms'] as num?)?.toInt() ??
            (item['default_end_ms'] as num?)?.toInt() ??
            0;
        return total + (end > start ? end - start : 0);
      });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 30, 32, 42),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('导出集锦', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                '只导出人工确认的进球片段。',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 26),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      _ExportRow(label: '已确认片段', value: '$_goalCount 个'),
                      _ExportRow(label: '合计时长', value: _formatMs(_durationMs)),
                      const _ExportRow(label: '输出编码', value: 'H.264 / AAC'),
                      const _ExportRow(label: '处理方式', value: '硬件编码优先，软件回退'),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _goalCount > 0 && !busy
                              ? () => _chooseMerge(context)
                              : null,
                          icon: busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.merge_type),
                          label: const Text('合并导出'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _goalCount > 0 && !busy
                              ? () => _chooseSeparate(context)
                              : null,
                          icon: const Icon(Icons.file_copy_outlined),
                          label: const Text('分别导出'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '导出前只会使用“已确认”候选；待审核和已排除片段不会进入输出。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: onBackToReview,
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回审核'),
              ),
              if (exportHistory.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text('最近导出', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                for (final item in exportHistory)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ExportHistoryCard(item: item),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _chooseMerge(BuildContext context) async {
    final location = await getSaveLocation(
      suggestedName: 'highlights.mp4',
      acceptedTypeGroups: [
        const XTypeGroup(label: '视频', extensions: ['mp4']),
      ],
    );
    if (location != null) await onExport('merge', outputPath: location.path);
  }

  Future<void> _chooseSeparate(BuildContext context) async {
    final directory = await getDirectoryPath(confirmButtonText: '选择输出目录');
    if (directory != null) await onExport('separate', outputDir: directory);
  }
}

class _ExportHistoryCard extends StatelessWidget {
  const _ExportHistoryCard({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
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
        : '${createdAt.month.toString().padLeft(2, '0')}-${createdAt.day.toString().padLeft(2, '0')} '
              '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.history),
        title: Text('$mode · $count 个片段 · ${_formatMs(duration)}'),
        subtitle: Text(
          '${time.isEmpty ? '' : '$time · '}处理 ${_formatMs(processing)}\n$path',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _ExportRow extends StatelessWidget {
  const _ExportRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Text(label),
        const Spacer(),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
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
