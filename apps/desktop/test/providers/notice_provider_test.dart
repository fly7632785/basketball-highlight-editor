// test/providers/notice_provider_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/providers/notice_provider.dart';

void main() {
  test('push appends and dismiss removes', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(noticeProvider), isEmpty);
    final notifier = container.read(noticeProvider.notifier);
    notifier.push(const NoticeMessage(id: '1', severity: NoticeSeverity.success, title: 'ok'));
    expect(container.read(noticeProvider).length, 1);
    notifier.dismiss('1');
    expect(container.read(noticeProvider), isEmpty);
  });

  test('queue capped at 4', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(noticeProvider.notifier);
    for (var i = 0; i < 6; i++) {
      notifier.push(NoticeMessage(id: '$i', severity: NoticeSeverity.info, title: '$i'));
    }
    expect(container.read(noticeProvider).length, 4);
  });
}
