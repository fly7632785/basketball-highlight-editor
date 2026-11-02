// test/providers/missing_segment_test.dart
import 'dart:io';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/session_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubEngineBootstrap extends EngineBootstrapNotifier {
  @override
  AsyncValue<bool> build() => const AsyncData<bool>(true);

  @override
  Future<void> ensure({
    String? runtimeRootOverride,
    String? pythonExecutableOverride,
  }) async {}
}

class _NeverTransport implements EngineTransport {
  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    throw StateError('unexpected engine call: $command');
  }
}

/// openProject 返回三段视频，段 2 的源视频缺失（source_exists=false）。
class _ThreeSegmentSession extends ProjectSession {
  _ThreeSegmentSession(this.sourceRoot) : super(EngineSession(_NeverTransport()));

  final Directory sourceRoot;
  final List<List<String>> queueCalls = [];

  @override
  String? get projectRoot => '/project';
  @override
  String? get videoId => 'v1';

  @override
  Future<JsonMap> openProject(String projectRoot) async {
    JsonMap segment(String id, String name, bool exists) => <String, dynamic>{
      'id': id,
      'source_path': '${sourceRoot.path}/$name',
      'source_exists': exists,
      'duration_ms': 30000,
      'roi': <String, dynamic>{
        'calibration': <String, dynamic>{'source': 'manual'},
      },
    };
    return <String, dynamic>{
      'project_root': projectRoot,
      'project': <String, dynamic>{'id': 'proj-1'},
      'video': segment('v1', 'one.mp4', true),
      'videos': <dynamic>[
        segment('v1', 'one.mp4', true),
        segment('v2', 'moved.mp4', false),
        segment('v3', 'three.mp4', true),
      ],
    };
  }

  @override
  Future<JsonMap> setAnalysisQueue(
    List<String> videoIds, {
    double beforeSeconds = 3,
    double afterSeconds = 1,
  }) async {
    queueCalls.add(videoIds);
    return <String, dynamic>{'ok': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer boot(ProjectSession session) {
    final container = ProviderContainer(
      overrides: <Override>[
        projectSessionProvider.overrideWithValue(session),
        engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('打开三段项目第 2 段缺失时提示段号，其它段不报', () async {
    final directory = Directory.systemTemp.createTempSync('bhe-missing-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/one.mp4').writeAsStringSync('a');
    File('${directory.path}/three.mp4').writeAsStringSync('a');
    final container = boot(_ThreeSegmentSession(directory));
    await container.read(projectProvider.notifier).openProject('/project');

    final notices = container.read(noticeProvider);
    final missing = notices
        .where((notice) => notice.title.contains('找不到'))
        .toList();
    expect(missing, isNotEmpty, reason: '应有缺失提示');
    expect(missing.last.title, contains('第 2 段'));
    expect(missing.last.title, isNot(contains('第 1')));
    expect(missing.last.title, isNot(contains('第 3')));
    expect(missing.last.severity, NoticeSeverity.warning);
  });

  test('分析全部跳过缺失段，不把 v2 排进队列', () async {
    final directory = Directory.systemTemp.createTempSync('bhe-missing-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/one.mp4').writeAsStringSync('a');
    File('${directory.path}/three.mp4').writeAsStringSync('a');
    final session = _ThreeSegmentSession(directory);
    final container = boot(session);
    await container.read(projectProvider.notifier).openProject('/project');
    // 队列刚排上时会立刻 _startNextQueued；_NeverTransport 会抛错但不影响断言。

    await container
        .read(projectProvider.notifier)
        .startAnalysisQueue(beforeSeconds: 3, afterSeconds: 1);

    expect(session.queueCalls, isNotEmpty);
    final queued = session.queueCalls.last;
    expect(queued, containsAll(<String>['v1', 'v3']));
    expect(queued, isNot(contains('v2')));
    final notices = container.read(noticeProvider);
    expect(
      notices.any((notice) => notice.title.contains('已跳过')),
      isTrue,
      reason: '跳过缺失段时应有提示',
    );
  });
}
