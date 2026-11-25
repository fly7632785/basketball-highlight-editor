part of '../../mobile_ui.dart';

String _historyDate(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  final time = material.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return '${material.formatShortDate(local)} · $time';
}

class _ExportHistoryPage extends StatelessWidget {
  const _ExportHistoryPage({required this.state});
  final MobileAppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final entries = state.project.exportHistory;
      final warning = state.exportHistoryWarning;
      final l10n = _exportL10n(context);
      return Scaffold(
        key: const ValueKey('export-history-page'),
        appBar: AppBar(title: Text(context.bheText('导出历史'))),
        body: SafeArea(
          child: _ExportLayout(
            body: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: entries.isEmpty ? 1 : entries.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (warning != null)
                        _ExportFailureNotice(
                          failure: (
                            message: warning,
                            diagnostic: state.exportHistoryDiagnostic,
                          ),
                        ),
                      if (entries.isEmpty) Text(context.bheText('暂无导出记录')),
                    ],
                  );
                }
                final entry = entries[index - 1];
                final mode = switch (entry.mode) {
                  'merged' => MobileOutputMode.merged,
                  'labels' => MobileOutputMode.labels,
                  _ => MobileOutputMode.clips,
                };
                final status = context.bheText(
                  entry.isPartial
                      ? '部分完成 ${entry.files.length}/${entry.plannedCount}'
                      : '全部完成 ${entry.files.length}',
                );
                return Card(
                  child: ListTile(
                    key: ValueKey('history-entry-${entry.id}'),
                    leading: Icon(
                      entry.isPartial
                          ? LucideIcons.circleAlert
                          : LucideIcons.circleCheck,
                      color: entry.isPartial
                          ? BhePalette.gold
                          : BhePalette.green,
                      size: 22,
                    ),
                    title: Text(_exportModeLabel(l10n, mode)),
                    subtitle: Text(
                      '${_historyDate(context, entry.createdAt)}\n$status',
                    ),
                    trailing: const Icon(LucideIcons.chevronRight, size: 18),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            _ExportResultPage(state: state, history: entry),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );
}
