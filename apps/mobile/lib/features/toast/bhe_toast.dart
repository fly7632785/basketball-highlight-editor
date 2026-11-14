part of '../../mobile_ui.dart';

/// 全应用统一的轻提示：floating、左右 16、圆角、约 2.5 秒，可选一个操作按钮。
ScaffoldMessengerState? bheToastMessengerOf(BuildContext context) => ScaffoldMessenger.maybeOf(context);

void showBheToast(
  BuildContext context,
  String text, {
  SnackBarAction? action,
  Key? key,
  Duration duration = const Duration(seconds: 2),
  EdgeInsets? margin,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: key,
        content: Text(text),
        action: action,
        behavior: SnackBarBehavior.floating,
        margin: margin ?? const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        duration: duration,
      ),
    );
}
