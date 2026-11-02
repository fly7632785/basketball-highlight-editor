// test/log_line_assert_test.dart
// Q008 跟进：给「界面日志补全（一）」里只有源码检查的三处日志补「写出了这一行」的断言。
import 'package:desktop/core/app_log.dart';
import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/features/export/export_screen.dart';
import 'package:desktop/providers/export_output_picker.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/playback_coordinator.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/session_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _readLog() {
  final file = appLogFileOverride!;
  return file.existsSync() ? file.readAsStringSync() : '';
}

void _clearLog() {
  final file = appLogFileOverride!;
  if (file.existsSync()) file.deleteSync();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
    });
  });

  group('导出页选择日志', () {
    testWidgets('选输出方式、选效果、球员过滤各写出对应日志行', (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifier = _LogExportNotifier(_exportState());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            projectProvider.overrideWith(() => notifier),
            playbackCoordinatorProvider.overrideWithValue(PlaybackCoordinator()),
            exportOutputPickerProvider.overrideWithValue(_TestOutputPicker()),
          ],
          child: const MaterialApp(home: Scaffold(body: ExportScreen())),
        ),
      );
      await tester.pumpAndSettle();
      _clearLog();

      // 输出方式：merge -> separate（merge 是默认值，点 merge 不记日志）。
      final separate = find.byKey(const Key('export-mode-separate'));
      await tester.ensureVisible(separate);
      await tester.tap(separate);
      await tester.pumpAndSettle();

      // 效果：默认 none，点「临门慢动作」。
      final effect = find.byKey(const Key('export-effect-approach'));
      await tester.ensureVisible(effect);
      await tester.tap(effect);
      await tester.pumpAndSettle();

      // 球员过滤：点球员 Alice 的标签。
      final alice = find.widgetWithText(FilterChip, 'Alice');
      await tester.ensureVisible(alice);
      await tester.tap(alice);
      await tester.pumpAndSettle();

      final log = _readLog();
      expect(log, contains('[info] [export] 选择输出方式 separate'));
      expect(log, contains('[info] [export] 选择效果 approach'));
      expect(
        log,
        contains('[info] [export] 球员过滤变化 选中=1 含未标记=false'),
      );
      // 反向：不记路径与球员名。
      expect(log, isNot(contains('/tmp/')));
      expect(log, isNot(contains('Alice')));
    });
  });

  group('项目删除与重命名日志', () {
    test('删除项目写出带 id 的日志行', () async {
      final session = _LogSession()..fakeProjectId = 'proj-42';
      final container = _boot(
        session,
        recentProjects: [
          {'project_root': '/tmp/project', 'id': 'proj-42'},
        ],
      );
      _clearLog();

      await container
          .read(projectProvider.notifier)
          .deleteProject('/tmp/project');

      final log = _readLog();
      expect(log, contains('[info] [project] 删除项目 id=proj-42 当前项目=true'));
      expect(log, isNot(contains('/tmp/project')), reason: '不记路径');
    });

    test('重命名当前项目写出带 id 的日志行', () async {
      final session = _LogSession(
        transport: _UpdateSettingsTransport(),
      )..fakeProjectId = 'proj-42';
      final container = _boot(session);
      _clearLog();

      final renamed = await container
          .read(projectProvider.notifier)
          .renameProject('新名字');

      expect(renamed, isTrue);
      final log = _readLog();
      expect(
        log,
        contains('[info] [home] 重命名项目结束 ok=true 范围=当前项目 id=proj-42'),
      );
      expect(log, isNot(contains('新名字')), reason: '不记项目名');
    });

    test('重命名其他项目写出范围日志（id 为当前会话项目）', () async {
      final session = _LogSession(
        transport: _UpdateSettingsTransport(),
      )
        ..fakeProjectId = 'proj-current'
        ..updateProjectSettingsProjectId = 'proj-other';
      final container = _boot(session);
      _clearLog();

      final renamed = await container
          .read(projectProvider.notifier)
          .renameProject('新名字', projectRoot: '/tmp/other');

      expect(renamed, isTrue);
      final log = _readLog();
      expect(
        log,
        contains('[info] [home] 重命名项目结束 ok=true 范围=其他项目 id=proj-current'),
        reason:
            '现状：改其他项目时 id 记的是当前会话项目，不是被改的那个（已向组长报告）',
      );
    });
  });
}

ProviderContainer _boot(
  ProjectSession session, {
  List<Map<String, dynamic>> recentProjects = const [],
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      projectSessionProvider.overrideWithValue(session),
      engineBootstrapProvider.overrideWith(_StubBootstrap.new),
      if (recentProjects.isNotEmpty)
        projectProvider.overrideWith(
          () => _RecentProjectsNotifier(recentProjects),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _RecentProjectsNotifier extends ProjectNotifier {
  _RecentProjectsNotifier(this.recentProjects);

  final List<Map<String, dynamic>> recentProjects;

  @override
  ProjectState build() => ProjectState(recentProjects: recentProjects);
}

ProjectState _exportState() => const ProjectState(
  video: {'id': 'A'},
  players: [
    {'id': 'p1', 'name': 'Alice'},
    {'id': 'p2', 'name': 'Bob'},
  ],
  candidates: [
    {
      'id': 'c1',
      'default_start_ms': 0,
      'default_end_ms': 4000,
      'player_id': 'p1',
    },
    {
      'id': 'c2',
      'default_start_ms': 5000,
      'default_end_ms': 9000,
      'player_id': 'p2',
    },
  ],
);

class _LogExportNotifier extends ProjectNotifier {
  _LogExportNotifier(this.initialState);

  final ProjectState initialState;

  @override
  ProjectState build() => initialState;
}

class _TestOutputPicker extends ExportOutputPicker {}

class _StubBootstrap extends EngineBootstrapNotifier {
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

class _UpdateSettingsTransport implements EngineTransport {
  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    if (command == 'update_project_settings') return <String, dynamic>{'ok': true};
    throw StateError('unexpected engine call: $command');
  }
}

/// 只覆盖删除/重命名路径需要的方法；其余走 _NeverTransport 兜底。
class _LogSession extends ProjectSession {
  _LogSession({EngineTransport? transport})
    : super(EngineSession(transport ?? _NeverTransport()));

  String? fakeProjectId;
  String? updateProjectSettingsProjectId;

  @override
  String? get projectRoot => '/tmp/project';

  @override
  String? get projectId => fakeProjectId;

  @override
  Future<JsonMap> deleteProject(String projectRoot) async {
    if (fakeProjectId != null) reset();
    return <String, dynamic>{'deleted': true};
  }

  @override
  Future<JsonMap> updateProjectSettings({String? name, String? themeMode}) async {
    updateProjectSettingsProjectId ??= fakeProjectId;
    return <String, dynamic>{'ok': true};
  }

  @override
  Future<List<JsonMap>> loadRecentProjects({
    required String knownRoot,
    int limit = 20,
  }) async => const <JsonMap>[];
}
