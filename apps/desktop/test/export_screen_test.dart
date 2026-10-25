import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:desktop/components/cs_button.dart';
import 'package:desktop/features/export/export_screen.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/playback_coordinator.dart';
import 'package:desktop/providers/export_output_picker.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the goal effect picks one option and the total follows it', (
    tester,
  ) async {
    final notifier = _FilterExportNotifier(
      const ProjectState(
        video: {'id': 'A'},
        candidates: [
          {
            'id': 'goal',
            'event_time_ms': 3000,
            'review_start_ms': 0,
            'review_end_ms': 4000,
            'detector_version': 'python-v2',
          },
          {
            'id': 'manual',
            'event_time_ms': 12000,
            'review_start_ms': 10000,
            'review_end_ms': 14000,
            'detector_version': 'manual-v1',
          },
        ],
      ),
    );
    final picker = _TestOutputPicker();
    await _pumpFilterExport(tester, notifier, picker: picker);
    expect(find.text('00:08'), findsOneWidget);

    // 临门慢动作：进球那个片段多出 1.3 秒，手动片段不加。
    final approach = find.byKey(const Key('export-effect-approach'));
    await tester.ensureVisible(approach);
    await tester.tap(approach);
    await tester.pumpAndSettle();
    expect(find.text('00:09'), findsOneWidget);

    // 慢放特写回放：多出 1.6 秒。
    final replay = find.byKey(const Key('export-effect-replay'));
    await tester.ensureVisible(replay);
    await tester.tap(replay);
    await tester.pumpAndSettle();
    expect(find.text('00:09'), findsOneWidget);

    final start = find.byKey(const Key('export-start'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    picker.result.complete('/tmp/game.mp4');
    await tester.pumpAndSettle();
    expect(notifier.exportedEffect, 'replay');
    expect(
      (await SharedPreferences.getInstance()).getString('export_goal_effect'),
      'replay',
    );
  });

  testWidgets('one video per tag asks for a folder and exports per tag', (
    tester,
  ) async {
    final notifier = _FilterExportNotifier(_filterState());
    final picker = _TestOutputPicker();
    await _pumpFilterExport(tester, notifier, picker: picker);

    final byTag = find.byKey(const Key('export-mode-by-player'));
    await tester.ensureVisible(byTag);
    await tester.tap(byTag);
    await tester.pumpAndSettle();
    final start = find.byKey(const Key('export-start'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    picker.result.complete('/tmp/by-tag');
    await tester.pumpAndSettle();

    expect(notifier.exportedMode, 'merge_by_player');
    expect(notifier.exportedOutputDir, '/tmp/by-tag');
    expect(notifier.exportedOutputPath, isNull);
  });

  testWidgets('the per-tag option only appears when the project has tags', (
    tester,
  ) async {
    final notifier = _FilterExportNotifier(
      const ProjectState(
        video: {'id': 'A'},
        candidates: [
          {'id': 'a', 'default_start_ms': 0, 'default_end_ms': 4000},
        ],
      ),
    );
    await _pumpFilterExport(tester, notifier);

    expect(find.byKey(const Key('export-mode-by-player')), findsNothing);
  });

  testWidgets('shows game stats from the current review', (tester) async {
    final notifier = _FilterExportNotifier(
      const ProjectState(
        video: {'id': 'A'},
        players: [
          {'id': 'p1', 'name': 'Alice'},
        ],
        candidates: [
          {'id': 'a', 'event_time_ms': 60000, 'player_id': 'p1', 'review_status': 'included'},
          {'id': 'b', 'event_time_ms': 720000, 'review_status': 'pending'},
          {
            'id': 'c',
            'event_time_ms': 90000,
            'review_status': 'excluded',
            'selection_status': 'excluded',
            'review_reason': 'auto_rim_check',
          },
        ],
      ),
    );
    await _pumpFilterExport(tester, notifier);

    expect(find.byKey(const Key('export-game-stats')), findsOneWidget);
    expect(find.text('67%  ·  2 / 3'), findsOneWidget);
    expect(find.text('0–10 分钟'), findsOneWidget);
    expect(find.text('10–20 分钟'), findsOneWidget);
  });

  testWidgets('cached export resets player filters when the video changes', (
    tester,
  ) async {
    final notifier = _FilterExportNotifier(_filterState());
    await _pumpFilterExport(tester, notifier);
    await _pickFilter(tester, 'Alice');
    notifier.replace(
      const ProjectState(
        video: {'id': 'B'},
        candidates: [
          {'id': 'new-clip', 'default_start_ms': 0, 'default_end_ms': 4000},
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 个'), findsOneWidget);
    expect(_mergeButton(tester).onPressed, isNotNull);
  });

  testWidgets('cached export resets filters when the source path changes', (
    tester,
  ) async {
    final initial = _filterState().copyWith(videoPath: '/tmp/source-A.mp4');
    final notifier = _FilterExportNotifier(initial);
    await _pumpFilterExport(tester, notifier);
    await _pickFilter(tester, 'Alice');
    notifier.replace(initial.copyWith(videoPath: '/tmp/source-B.mp4'));
    await tester.pumpAndSettle();
    expect(_filterChip(tester, '全部球员').selected, isTrue);
    expect(find.text('3 个'), findsOneWidget);
  });

  testWidgets('same-scope hydration and refresh preserve a valid filter', (
    tester,
  ) async {
    final initial = _filterState();
    final notifier = _FilterExportNotifier(initial);
    await _pumpFilterExport(tester, notifier);
    await _pickFilter(tester, 'Alice');
    notifier.replace(initial.copyWith(hydrating: true, players: []));
    await tester.pump();
    expect(_mergeButton(tester).onPressed, isNull);
    notifier.replace(initial);
    await tester.pumpAndSettle();
    expect(_filterChip(tester, 'Alice').selected, isTrue);
    expect(_filterChip(tester, '全部球员').selected, isFalse);
    expect(find.text('1 个'), findsOneWidget);
  });

  testWidgets('adding a player retains explicitly included unassigned clips', (
    tester,
  ) async {
    final notifier = _FilterExportNotifier(_filterState());
    final picker = _TestOutputPicker();
    await _pumpFilterExport(tester, notifier, picker: picker);
    await _pickFilter(tester, 'Alice');
    expect(_filterChip(tester, '未标记').selected, isFalse);
    expect(find.text('1 个'), findsOneWidget);
    await _pickFilter(tester, '未标记');
    await _pickFilter(tester, 'Bob');
    expect(_filterChip(tester, '未标记').selected, isTrue);
    expect(find.text('3 个'), findsOneWidget);
    await _exportFiltered(tester, picker);
    expect(notifier.exportedPlayerIds, unorderedEquals(['p1', 'p2']));
    expect(notifier.exportedIncludeUnassigned, isTrue);
  });

  testWidgets('selecting unassigned first survives adding a player', (
    tester,
  ) async {
    final notifier = _FilterExportNotifier(_filterState());
    await _pumpFilterExport(tester, notifier);
    await _pickFilter(tester, '未标记');
    await _pickFilter(tester, 'Alice');
    expect(_filterChip(tester, '未标记').selected, isTrue);
    expect(find.text('2 个'), findsOneWidget);
    await _pickFilter(tester, '全部球员');
    await _pickFilter(tester, 'Bob');
    expect(_filterChip(tester, '未标记').selected, isFalse);
    expect(find.text('1 个'), findsOneWidget);
  });

  testWidgets('deleting one selected player prunes only its export ID', (
    tester,
  ) async {
    final initial = _filterState();
    final notifier = _FilterExportNotifier(initial);
    final picker = _TestOutputPicker();
    await _pumpFilterExport(tester, notifier, picker: picker);
    await _pickFilter(tester, 'Alice');
    await _pickFilter(tester, 'Bob');
    notifier.replace(
      initial.copyWith(
        players: [initial.players.last],
        candidates: [
          {...initial.candidates.first, 'player_id': null},
          ...initial.candidates.skip(1),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(_filterChip(tester, 'Bob').selected, isTrue);
    expect(find.text('1 个'), findsOneWidget);
    await _exportFiltered(tester, picker);
    expect(notifier.exportedPlayerIds, ['p2']);
    expect(notifier.exportedIncludeUnassigned, isFalse);
  });

  testWidgets('deleting all tags leaves a visible reset for the empty filter', (
    tester,
  ) async {
    final initial = _filterState();
    final notifier = _FilterExportNotifier(initial);
    await _pumpFilterExport(tester, notifier);
    await _pickFilter(tester, 'Alice');
    notifier.replace(
      initial.copyWith(
        players: [],
        candidates: [
          for (final candidate in initial.candidates)
            {...candidate, 'player_id': null},
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 个'), findsOneWidget);
    expect(_mergeButton(tester).onPressed, isNull);
    expect(_filterChip(tester, '全部球员').selected, isFalse);
    await _pickFilter(tester, '全部球员');
    expect(find.text('3 个'), findsOneWidget);
    expect(_mergeButton(tester).onPressed, isNotNull);
  });

  testWidgets('refresh does not broaden an intentionally empty filter', (
    tester,
  ) async {
    final initial = _filterState();
    final notifier = _FilterExportNotifier(initial);
    await _pumpFilterExport(tester, notifier);
    await _pickFilter(tester, 'Alice');
    await _pickFilter(tester, 'Alice');
    expect(find.text('0 个'), findsOneWidget);
    notifier.replace(initial.copyWith(players: []));
    await tester.pumpAndSettle();
    expect(find.text('0 个'), findsOneWidget);
    expect(_filterChip(tester, '全部球员').selected, isFalse);
    expect(_mergeButton(tester).onPressed, isNull);
  });

  testWidgets(
    'export waits for paused previews and prevents duplicate native dialogs',
    (tester) async {
      final coordinator = PlaybackCoordinator();
      final paused = Completer<void>();
      coordinator.register(Object(), () => paused.future);
      final picker = _TestOutputPicker();
      final notifier = _TrackingExportNotifier();
      await _pumpExport(tester, coordinator, picker, notifier);
      final merge = find.byKey(const Key('export-start'));
      await tester.ensureVisible(merge);
      await tester.tap(merge);
      await tester.pump();
      expect(picker.calls, 0);
      expect(tester.widget<CsButton>(merge).onPressed, isNull);
      expect(find.text('正在准备输出位置…'), findsOneWidget);
      paused.complete();
      await tester.pump();
      await tester.pump();
      expect(picker.calls, 1);
      picker.result.complete(null);
      await tester.pumpAndSettle();
      expect(notifier.exports, isEmpty);
      expect(tester.widget<CsButton>(merge).onPressed, isNotNull);
      picker.result = Completer<String?>();
      await tester.tap(merge);
      await tester.pump();
      await tester.pump();
      expect(picker.calls, 2);
      picker.result.complete('/tmp/highlights.mp4');
      await tester.pumpAndSettle();
      expect(notifier.exports, ['merge:/tmp/highlights.mp4']);
    },
  );

  testWidgets(
    'failed pause never opens native dialog and leaves export retryable',
    (tester) async {
      final coordinator = PlaybackCoordinator();
      coordinator.register(Object(), () async {
        throw StateError('pause failed');
      });
      final picker = _TestOutputPicker();
      final notifier = _TrackingExportNotifier();
      await _pumpExport(tester, coordinator, picker, notifier);
      final merge = find.byKey(const Key('export-start'));
      await tester.ensureVisible(merge);
      await tester.tap(merge);
      await tester.pump();
      await tester.pump();
      expect(picker.calls, 0);
      expect(notifier.exports, isEmpty);
      expect(find.textContaining('选择输出位置失败'), findsOneWidget);
      expect(tester.widget<CsButton>(merge).onPressed, isNotNull);
    },
  );

  testWidgets('separate export uses the same paused native-dialog path', (
    tester,
  ) async {
    final picker = _TestOutputPicker();
    final notifier = _TrackingExportNotifier();
    await _pumpExport(tester, PlaybackCoordinator(), picker, notifier);
    final mode = find.byKey(const Key('export-mode-separate'));
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    final separate = find.byKey(const Key('export-start'));
    await tester.ensureVisible(separate);
    await tester.tap(separate);
    await tester.pump();
    await tester.pump();
    picker.result.complete('/tmp/clips');
    await tester.pumpAndSettle();
    expect(notifier.exports, ['separate:/tmp/clips']);
  });

  testWidgets('导出历史提供打开目录按钮', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _ExportNotifier(
              const ProjectState(
                exportHistory: [
                  {
                    'mode': 'merge',
                    'candidate_count': 2,
                    'duration_ms': 12000,
                    'processing_ms': 3000,
                    'output_path': '/tmp/highlights.mp4',
                    'metadata': {
                      'files': ['/tmp/highlights.mp4'],
                    },
                    'created_at': '2026-08-07T01:00:00.000Z',
                  },
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: ExportScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('打开目录'), findsOneWidget);
  });

  testWidgets('快速分析导出前显示漏检风险但不阻塞导出', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _ExportNotifier(
              const ProjectState(
                analysisMode: 'fast',
                candidates: [
                  {
                    'id': 'candidate-1',
                    'event_time_ms': 12000,
                    'default_start_ms': 6000,
                    'default_end_ms': 15000,
                  },
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: ExportScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('当前结果来自快速分析，可能漏检；如需更完整结果，建议先用标准模式重新分析。'), findsOneWidget);
    expect(
      tester.widget<CsButton>(find.byKey(const Key('export-start'))).onPressed,
      isNotNull,
    );
    expect(find.byKey(const Key('export-mode-merge')), findsOneWidget);
    expect(find.byKey(const Key('export-mode-separate')), findsOneWidget);
  });
}

class _ExportNotifier extends ProjectNotifier {
  _ExportNotifier(this.initialState);

  final ProjectState initialState;

  @override
  ProjectState build() => initialState;
}

ProjectState _filterState() => const ProjectState(
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
    {'id': 'c3', 'default_start_ms': 10000, 'default_end_ms': 14000},
  ],
);

class _FilterExportNotifier extends _ExportNotifier {
  _FilterExportNotifier(super.initialState);

  List<String>? exportedPlayerIds;
  bool? exportedIncludeUnassigned;
  String? exportedMode;
  String? exportedEffect;
  String? exportedOutputDir;
  String? exportedOutputPath;

  void replace(ProjectState value) => state = value;

  @override
  Future<void> export(
    String mode, {
    String? outputDir,
    String? outputPath,
    List<String>? playerIds,
    bool? includeUnassigned,
    String effect = 'none',
  }) async {
    exportedMode = mode;
    exportedEffect = effect;
    exportedOutputDir = outputDir;
    exportedOutputPath = outputPath;
    exportedPlayerIds = playerIds;
    exportedIncludeUnassigned = includeUnassigned;
  }
}

Future<void> _pumpFilterExport(
  WidgetTester tester,
  _FilterExportNotifier notifier, {
  _TestOutputPicker? picker,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _pumpExport(
    tester,
    PlaybackCoordinator(),
    picker ?? _TestOutputPicker(),
    notifier,
  );
}

FilterChip _filterChip(WidgetTester tester, String label) =>
    tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));

CsButton _mergeButton(WidgetTester tester) =>
    tester.widget<CsButton>(find.byKey(const Key('export-start')));

Future<void> _pickFilter(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(FilterChip, label);
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

Future<void> _exportFiltered(
  WidgetTester tester,
  _TestOutputPicker picker,
) async {
  final merge = find.byKey(const Key('export-start'));
  await tester.ensureVisible(merge);
  await tester.tap(merge);
  await tester.pump();
  await tester.pump();
  expect(picker.calls, 1);
  picker.result.complete('/tmp/filter-regression.mp4');
  await tester.pumpAndSettle();
}

Future<void> _pumpExport(
  WidgetTester tester,
  PlaybackCoordinator coordinator,
  _TestOutputPicker picker,
  ProjectNotifier notifier,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectProvider.overrideWith(() => notifier),
        playbackCoordinatorProvider.overrideWithValue(coordinator),
        exportOutputPickerProvider.overrideWithValue(picker),
      ],
      child: const MaterialApp(home: Scaffold(body: ExportScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

class _TestOutputPicker extends ExportOutputPicker {
  var result = Completer<String?>();
  var calls = 0;
  @override
  Future<String?> mergedPath({required String typeLabel}) {
    calls++;
    return result.future;
  }

  @override
  Future<String?> directory({required String confirmLabel}) {
    calls++;
    return result.future;
  }
}

class _TrackingExportNotifier extends _ExportNotifier {
  _TrackingExportNotifier()
    : super(
        const ProjectState(
          candidates: [
            {'id': 'c1', 'default_start_ms': 0, 'default_end_ms': 4000},
          ],
        ),
      );
  final exports = <String>[];
  @override
  Future<void> export(
    String mode, {
    String? outputDir,
    String? outputPath,
    List<String>? playerIds,
    bool? includeUnassigned,
    String effect = 'none',
  }) async {
    exports.add('$mode:${outputPath ?? outputDir}');
  }
}
