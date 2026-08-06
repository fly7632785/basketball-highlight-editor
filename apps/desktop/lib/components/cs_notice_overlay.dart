// lib/components/cs_notice_overlay.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/notice_provider.dart';
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
          bottom: Spacing.lg,
          right: Spacing.lg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: notices
                .map(
                  (m) => Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.sm),
                    child: CsNotice(
                      key: ValueKey(m.id),
                      message: m,
                      onDismiss: () =>
                          ref.read(noticeProvider.notifier).dismiss(m.id),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}
