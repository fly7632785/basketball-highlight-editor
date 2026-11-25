part of '../../mobile_ui.dart';

/// 只提醒这次会导出的未标记片段。主动选择未标记或按标签合成时无需提醒。
int _untaggedReminderCount(
  MobileAppState state,
  ExportScope scope,
  MobileOutputMode mode,
  List<Candidate> selected,
) {
  if (scope.active || mode == MobileOutputMode.labels) return 0;
  final usesLabels =
      state.project.players.isNotEmpty ||
      state.project.candidates.any(
        (candidate) => exportLabels(candidate).isNotEmpty,
      );
  if (!usesLabels) return 0;
  return selected.where((candidate) => exportLabels(candidate).isEmpty).length;
}

enum _UntaggedChoice { backToReview, exportAnyway }

Future<_UntaggedChoice?> _showUntaggedReminder(
  BuildContext context,
  int count,
) => showModalBottomSheet<_UntaggedChoice>(
  context: context,
  isScrollControlled: true,
  builder: (context) => _SheetFrame(
    title: context.bheText('还有 $count 个片段未标标签'),
    child: Column(
      key: const ValueKey('untagged-reminder'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.bheText('本次导出会包含这些片段。')),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, _UntaggedChoice.backToReview),
          child: Text(context.bheText('返回审核')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _UntaggedChoice.exportAnyway),
          child: Text(context.bheText('仍然导出')),
        ),
      ],
    ),
  ),
);
