import 'package:desktop/core/engine_client.dart';
import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:flutter_test/flutter_test.dart';

const _fast = <Duration>[
  Duration.zero,
  Duration.zero,
  Duration.zero,
  Duration.zero,
];

/// 按顺序返回结果或抛 PROJECT_BUSY 的假引擎。
class _ScriptedTransport implements EngineTransport {
  _ScriptedTransport(this.script);

  final List<Object> script;
  final List<String> commands = [];
  int calls = 0;

  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    commands.add(command);
    final step = script[calls < script.length ? calls : script.length - 1];
    calls++;
    if (step is EngineException) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

const _busy = 'PROJECT_BUSY';
EngineException _busyError() =>
    const EngineException(_busy, '项目正在读取，请稍后重试');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('项目忙时静默重试，成功后正常返回', () async {
    var calls = 0;
    final result = await retryWhileProjectBusy('extract_preview', () async {
      calls++;
      if (calls < 3) throw _busyError();
      return <String, dynamic>{'path': '/tmp/cover.jpg'};
    }, delays: _fast);

    expect(result['path'], '/tmp/cover.jpg');
    expect(calls, 3, reason: '忙两次后成功，一共调用三次');
  });

  test('一直忙：重试用完仍把 PROJECT_BUSY 抛给调用方', () async {
    var calls = 0;
    await expectLater(
      retryWhileProjectBusy('extract_preview', () async {
        calls++;
        throw _busyError();
      }, delays: _fast),
      throwsA(
        isA<EngineException>().having((e) => e.code, 'code', _busy),
      ),
    );
    expect(calls, _fast.length + 1, reason: '首次 + 每个延迟各一次');
  });

  test('其它错误不重试', () async {
    var calls = 0;
    await expectLater(
      retryWhileProjectBusy('extract_preview', () async {
        calls++;
        throw const EngineException('VIDEO_NOT_FOUND', '原始视频不存在');
      }, delays: _fast),
      throwsA(
        isA<EngineException>().having((e) => e.code, 'code', 'VIDEO_NOT_FOUND'),
      ),
    );
    expect(calls, 1);
  });

  test('ProjectSession.extractPreview 遇到 PROJECT_BUSY 会自己重试', () async {
    final transport = _ScriptedTransport([
      {'project': {'id': 'p1'}},
      {'video': {'id': 'v1'}},
      _busyError(),
      {'path': '/tmp/cover.jpg'},
    ]);
    final session = ProjectSession(EngineSession(transport));
    await session.createProject(name: 't', rootPath: '/tmp/p1');
    await session.linkVideo('/tmp/game.mp4');

    final preview = await session.extractPreview(timeMs: 1000);

    expect(preview['path'], '/tmp/cover.jpg');
    expect(transport.commands.where((c) => c == 'extract_preview').length, 2);
  });

  test('ProjectSession.startReview 遇到 PROJECT_BUSY 会自己重试', () async {
    final transport = _ScriptedTransport([
      {'project': {'id': 'p1'}},
      {'video': {'id': 'v1'}},
      _busyError(),
      {'review': {'id': 'r1'}},
    ]);
    final session = ProjectSession(EngineSession(transport));
    await session.createProject(name: 't', rootPath: '/tmp/p1');
    await session.linkVideo('/tmp/game.mp4');

    await session.startReview('candidate-1');

    expect(transport.commands.where((c) => c == 'start_review').length, 2);
  });
}
