import 'package:desktop/core/draft_flush_registry.dart';
import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/features/import_video/import_video_screen.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/session_provider.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Saved, analyzed projects at the engine boundary. No native playback or real
// analysis runs in these widget tests; project close/open and video activation
// use the production notifier and session.
class _SavedProject implements EngineTransport {
  _SavedProject(this.segments, {this.calibrated = true});
  final int segments;
  final bool calibrated;
  Map<String, dynamic>? draft;
  final calls = <String>[];

  Map<String, dynamic> video(int index) => {
    'id': 'v$index',
    // Missing media can still be reconfigured. Avoid native video/file dialogs.
    'source_path': '',
    'source_exists': false,
    'duration_ms': 60000,
    'width': 1920,
    'height': 1080,
    'analysis_start_ms': index * 1000,
    'analysis_end_ms': 50000,
    if (calibrated) 'roi': roi,
    'analysis_job': {'state': 'completed'},
    'candidate_count': 1,
  };

  static const roi = {'x1': 100, 'y1': 100, 'x2': 900, 'y2': 900};

  @override
  Future<Map<String, dynamic>> request(
    String command,
    Map<String, dynamic> payload,
  ) async {
    calls.add('$command:${payload['video_id'] ?? ''}');
    switch (command) {
      case 'open_project':
        return {
          'project_root': '/projects/reconfigure',
          'project': {'id': 'reconfigure', 'name': 'Reconfigure'},
          'video': video(1),
          'videos': [for (var i = 1; i <= segments; i++) video(i)],
          'roi': calibrated ? roi : null,
          'workflow_draft': draft,
        };
      case 'list_candidates':
        return {
          'candidates': [
            {'id': 'c1', 'video_id': 'v1', 'center_ms': 10000},
          ],
        };
      case 'get_latest_job':
        return {
          'job': payload['job_type'] == 'analysis'
              ? {'id': 'analyzed', 'state': 'completed'}
              : null,
        };
      case 'save_workflow_draft':
        draft = Map<String, dynamic>.from(payload['draft'] as Map);
        calls.add('saved:${draft!['video_id']}:step=${draft!['step']}');
        return {};
      case 'get_workflow_draft':
        return {'draft': draft};
      default:
        return {};
    }
  }
}

class _Bootstrap extends EngineBootstrapNotifier {
  @override
  AsyncValue<bool> build() => const AsyncData(true);
  @override
  Future<void> ensure({
    String? runtimeRootOverride,
    String? pythonExecutableOverride,
  }) async {}
}

class _CancelRelink extends FileSelectorPlatform {
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => null;
}

Finder _step(int index) => find.byKey(ValueKey('import-step-$index'));

bool _selected(WidgetTester tester, int index) =>
    tester
        .widget<Semantics>(
          find
              .ancestor(of: _step(index), matching: find.byType(Semantics))
              .first,
        )
        .properties
        .selected ==
    true;

Future<ProviderContainer> _reopen(
  WidgetTester tester,
  _SavedProject saved,
) async {
  SharedPreferences.setMockInitialValues({
    onboardingStepsPrefsKey: allOnboardingStepIds,
  });
  final selector = FileSelectorPlatform.instance;
  FileSelectorPlatform.instance = _CancelRelink();
  addTearDown(() => FileSelectorPlatform.instance = selector);
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      projectSessionProvider.overrideWithValue(
        ProjectSession(EngineSession(saved)),
      ),
      engineBootstrapProvider.overrideWith(_Bootstrap.new),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester);
    resetDraftFlushForTest();
  });
  final notifier = container.read(projectProvider.notifier);
  var opened = notifier.openProject('/projects/reconfigure');
  await _pump(tester);
  expect(await _finish(tester, opened, saved), isTrue);
  expect(container.read(projectProvider).candidates, hasLength(1));
  final closed = notifier.closeProjectSafely();
  await _pump(tester);
  expect(await _finish(tester, closed, saved), isTrue);
  expect(container.read(projectProvider).video, isNull);
  opened = notifier.openProject('/projects/reconfigure');
  await _pump(tester);
  expect(await _finish(tester, opened, saved), isTrue);
  expect(container.read(projectProvider).candidates, hasLength(1));
  expect(
    saved.calls.where((call) => call.startsWith('open_project')),
    hasLength(2),
  );
  // Review's reconfigure action navigates to a fresh ImportVideoScreen.
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
    ),
  );
  await _pump(tester);
  expect(_selected(tester, saved.segments > 1 ? 0 : 1), isTrue);
  return container;
}

Future<T> _finish<T>(
  WidgetTester tester,
  Future<T> future,
  _SavedProject saved,
) async {
  var done = false;
  late T result;
  future.then((value) {
    result = value;
    done = true;
  });
  for (var i = 0; i < 40 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    done,
    isTrue,
    reason: 'Project lifecycle did not finish: ${saved.calls}',
  );
  return result;
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(resetDraftFlushForTest);
  tearDown(resetDraftFlushForTest);
  testWidgets('no video blocks every forward step', (tester) async {
    SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectSessionProvider.overrideWithValue(
            ProjectSession(EngineSession(_SavedProject(1))),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    await _pump(tester);
    for (var index = 1; index <= 3; index++) {
      await tester.tap(_step(index));
      await _pump(tester);
      expect(_selected(tester, 0), isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester);
  });
  for (final segments in [1, 3]) {
    testWidgets(
      'reopened analyzed $segments-segment project jumps to configured steps',
      (tester) async {
        final saved = _SavedProject(segments);
        final container = await _reopen(tester, saved);
        container.read(projectProvider.notifier).setPreviewTimeOnly(0);
        for (final target in [0, 2, 0, 3, 0, 1]) {
          await tester.tap(_step(target));
          await _pump(tester);
          expect(_selected(tester, target), isTrue, reason: 'step $target');
          if (target != 0) expect(saved.draft?['step'], target);
          if (target == 2) {
            expect(container.read(projectProvider).previewTimeMs, 1000);
          }
        }
      },
    );
  }

  testWidgets(
    'reopened segments 1, 2, 3 adjust their own range and calibration',
    (tester) async {
      final saved = _SavedProject(3);
      final container = await _reopen(tester, saved);
      for (var index = 1; index <= 3; index++) {
        final row = find.byKey(ValueKey('video-segment-v$index'));
        await tester.tap(find.descendant(of: row, matching: find.text('调整')));
        await _pump(tester);
        expect(container.read(projectProvider).video?['id'], 'v$index');
        expect(_selected(tester, 1), isTrue);
        // Use existing Next here so B is independently reproducible before A's fix.
        await tester.tap(find.text('下一步'));
        await _pump(tester);
        expect(_selected(tester, 2), isTrue);
        expect(saved.draft?['video_id'], 'v$index');
        expect(
          (saved.draft?['analysis_range'] as Map)['start_ms'],
          index * 1000,
        );
        await tester.tap(_step(0));
        await _pump(tester);
      }
      // ignore: avoid_print
      print('L412 B real notifier/session: ${saved.calls.join(', ')}');
    },
  );

  testWidgets(
    'missing calibration blocks confirmation but allows range and region',
    (tester) async {
      final saved = _SavedProject(1, calibrated: false);
      await _reopen(tester, saved);
      await tester.tap(_step(3));
      await _pump(tester);
      expect(_selected(tester, 1), isTrue);
      await tester.tap(_step(2));
      await _pump(tester);
      expect(_selected(tester, 2), isTrue);
      await tester.tap(_step(3));
      await _pump(tester);
      expect(_selected(tester, 2), isTrue);
    },
  );
}
