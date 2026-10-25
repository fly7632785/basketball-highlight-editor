// lib/components/cs_notice_overlay.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/feedback/feedback_dialog.dart';
import '../providers/notice_provider.dart';
import '../router/app_router.dart';
import '../theme/tokens.dart';
import 'cs_notice.dart';

class CsNoticeOverlay extends ConsumerWidget {
  const CsNoticeOverlay({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notices = ref.watch(noticeProvider);
    return Stack(
      children: [
        child,
        Positioned(
          top: Spacing.lg,
          left: Spacing.md,
          right: Spacing.md,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: notices
                      .map(
                        (m) => Padding(
                          padding: const EdgeInsets.only(bottom: Spacing.sm),
                          child: CsNotice(
                            key: ValueKey(m.id),
                            message: _withFeedback(ref, m),
                            onDismiss: () =>
                                ref.read(noticeProvider.notifier).dismiss(m.id),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 错误提示加一个「反馈这个问题」，带着错误内容打开反馈窗口。
NoticeMessage _withFeedback(WidgetRef ref, NoticeMessage m) {
  if (m.severity != NoticeSeverity.error || m.action != null) return m;
  return NoticeMessage(
    id: m.id,
    severity: m.severity,
    title: m.title,
    description: m.description,
    duration: m.duration,
    actionLabel: '反馈这个问题',
    action: () {
      final context = ref
          .read(appRouterProvider)
          .routerDelegate
          .navigatorKey
          .currentContext;
      if (context == null) return;
      ref.read(noticeProvider.notifier).dismiss(m.id);
      showFeedbackDialog(
        context,
        error: [m.title, m.description].whereType<String>().join('\n'),
      );
    },
  );
}
