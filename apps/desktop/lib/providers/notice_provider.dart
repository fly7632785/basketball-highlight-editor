// lib/providers/notice_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum NoticeSeverity { success, error, warning, info }

class NoticeMessage {
  final String id;
  final NoticeSeverity severity;
  final String title;
  final String? description;
  final void Function()? action;
  final String? actionLabel;
  final Duration duration;
  const NoticeMessage({
    required this.id,
    required this.severity,
    required this.title,
    this.description,
    this.action,
    this.actionLabel,
    this.duration = const Duration(seconds: 4),
  });
}

class NoticeNotifier extends Notifier<List<NoticeMessage>> {
  @override
  List<NoticeMessage> build() => const [];

  void push(NoticeMessage msg) {
    var next = state
        .where(
          (item) =>
              item.severity != msg.severity ||
              item.title != msg.title ||
              item.description != msg.description,
        )
        .toList();
    next.add(msg);
    if (next.length > 4) next = next.sublist(next.length - 4);
    state = next;
  }

  void dismiss(String id) {
    state = state.where((m) => m.id != id).toList();
  }
}

final noticeProvider = NotifierProvider<NoticeNotifier, List<NoticeMessage>>(
  NoticeNotifier.new,
);
