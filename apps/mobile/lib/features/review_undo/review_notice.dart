part of '../../mobile_ui.dart';

void _showReviewSaveFailure(
  BuildContext context,
  DiagnosticErrorRecord? failureRecord,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final diagnostic =
      failureRecord ??
      DiagnosticErrorRecord(StateError('保存失败，请重试'), null, 'project');
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('review-save-failure'),
        behavior: SnackBarBehavior.floating,
        // Keep the retry buttons (不选/选中) reachable while the notice shows.
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 84),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        duration: const Duration(seconds: 5),
        content: Text(context.bheText('保存失败，请重试')),
        action: SnackBarAction(
          key: const ValueKey('review-feedback-action'),
          label: context.bheText('反馈'),
          onPressed: () {
            if (context.mounted) {
              unawaited(showMobileDiagnostics(context, error: diagnostic));
            }
          },
        ),
      ),
    );
}
