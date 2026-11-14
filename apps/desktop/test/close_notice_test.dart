import 'dart:async';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSession extends ProjectSession {
  _FakeSession() : super(EngineSession(_NeverTransport()));
  final Completer<void> playerGate = Completer<void>();
  int resetCalls = 0;

  @override
  Future<Map<String, dynamic>> createPlayer(String name) async {
    await playerGate.future;
    return <String, dynamic>{
      'player': <String, dynamic>{'id': 'p1', 'name': name},
    };
  }

  @override
  Future<void> reset() async {
    resetCalls++;
  }
}

class _NeverTransport implements EngineTransport {
  @override
  Future<Map<String, dynamic>> request(
    String command,
    Map<String, dynamic> payload,
  ) async {
    throw StateError('unexpected engine call: $command');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('closeProjectSafely 关闭提示时机（L194）', () {
    test('快路径（<600ms）不出现「正在保存修改并关闭项目…」提示', () async {
      final session = _FakeSession();
      final container = ProviderContainer(
        overrides: [projectSessionProvider.overrideWithValue(session)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(projectProvider.notifier);

      expect(await notifier.closeProjectSafely(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        container.read(noticeProvider),
        isNot(
          anyElement(
            predicate<NoticeMessage>(
              (m) => m.title.contains('正在保存修改并关闭项目'),
            ),
          ),
        ),
      );
    });

    test('慢路径（>600ms）出现提示并在完成后撤销', () async {
      final session = _FakeSession();
      final container = ProviderContainer(
        overrides: [projectSessionProvider.overrideWithValue(session)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(projectProvider.notifier);

      // createPlayer 在 gate 放行前不结束，占住 busy。
      final creating = notifier.createPlayer('测试', candidateIds: const []);
      await Future<void>.delayed(Duration.zero);
      final closing = notifier.closeProjectSafely();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(
        container.read(noticeProvider).any(
              (m) => m.title.contains('正在保存修改并关闭项目'),
            ),
        isTrue,
        reason: '慢于 600ms 时应显示关闭提示',
      );
      session.playerGate.complete();
      expect(await creating, isNotNull);
      expect(await closing, isTrue);
      expect(
        container.read(noticeProvider),
        isNot(
          anyElement(
            predicate<NoticeMessage>(
              (m) => m.title.contains('正在保存修改并关闭项目'),
            ),
          ),
        ),
        reason: '关闭完成后提示应撤销',
      );
    });
  });

}
