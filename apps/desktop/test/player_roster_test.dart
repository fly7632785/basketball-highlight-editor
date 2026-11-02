import 'dart:convert';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/features/import_video/import_video_screen.dart';
import 'package:desktop/features/import_video/player_roster_picker.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/player_groups_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _names = ['Chris', 'Alex', 'Blake'];
final _savedGroups = jsonEncode([
  {'name': 'Saturday', 'players': _names},
]);

class _RosterProject extends ProjectNotifier {
  _RosterProject({
    this.existing = false,
    this.failImport = false,
    this.multi = false,
  });
  final bool existing;
  final bool failImport;
  final bool multi;
  final imports = <List<String>>[];
  final events = <String>[];

  @override
  ProjectState build() => ProjectState(
    video: const {
      'id': 'video-test',
      'source_path': 'test-game.mp4',
      'duration_ms': 60000,
      'width': 1920,
      'height': 1080,
    },
    suggestedRoi: const Rect.fromLTWH(.2, .2, .4, .4),
    workflowDraft: const {'step': 3, 'video_id': 'video-test'},
    videos: multi
        ? [
            for (final id in ['video-test', 'video-two'])
              {
                'id': id,
                'source_path': '$id.mp4',
                'duration_ms': 60000,
                'roi': {
                  'x1': 1,
                  'y1': 1,
                  'x2': 100,
                  'y2': 100,
                  'calibration': {'source': 'manual'},
                },
              },
          ]
        : const [],
    players: existing
        ? const [
            {'id': 'existing-player', 'name': 'Alex'},
          ]
        : const [],
  );

  @override
  Future<Map<String, dynamic>?> loadWorkflowDraft() async =>
      state.workflowDraft;

  @override
  Future<void> saveWorkflowDraft(Map<String, dynamic> draft) async {}

  @override
  Future<void> propagateHoopToFollowingParts(String sourceVideoId) async {}

  @override
  Future<void> startAnalysisQueue({
    required double beforeSeconds,
    required double afterSeconds,
  }) async {
    events.add('queue');
  }

  @override
  Future<bool> applyWorkflowDraft(Map<String, dynamic> draft) async {
    events.add('apply');
    return true;
  }

  @override
  Future<void> importPlayers(List<String> names) async {
    events.add('import');
    imports.add(List.of(names));
    if (failImport) return;
    final players = [...state.players];
    for (final name in names) {
      if (!players.any((player) => player['name'] == name)) {
        players.add({'id': 'player-$name', 'name': name});
      }
    }
    state = state.copyWith(players: players);
  }

  @override
  Future<bool> startAnalysis({
    bool replaceRecoverable = false,
    double? beforeSeconds,
    double? afterSeconds,
    String? mode,
  }) async {
    events.add('analyze');
    // Navigation belongs to GoRouter; keep this fixture on the confirm page.
    return false;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _RosterProject notifier, {
  bool withGroups = true,
  bool withDefault = true,
  bool english = false,
}) async {
  SharedPreferences.setMockInitialValues({
    onboardingStepsPrefsKey: allOnboardingStepIds,
    if (withGroups) playerGroupsPrefsKey: _savedGroups,
    if (withDefault) defaultPlayerGroupPrefsKey: 'Saturday',
  });
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [projectProvider.overrideWith(() => notifier)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: Locale(english ? 'en' : 'zh'),
        localizationsDelegates: BheLocalizations.localizationsDelegates,
        supportedLocales: BheLocalizations.supportedLocales,
        home: const Scaffold(body: ImportVideoScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _selectGroup(WidgetTester tester, String name) async {
  final dropdown = find.byKey(const Key('player-roster-group'));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> _analyze(WidgetTester tester) async {
  await tester.tap(find.text('确认配置并开始分析'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'renaming the selected default invalidates this selection but updates the saved default',
    (tester) async {
      final notifier = _RosterProject();
      final container = await _pump(tester, notifier);
      await container
          .read(playerGroupsProvider.notifier)
          .update('Saturday', name: 'Renamed', players: ['Blake', 'Chris']);
      await tester.pumpAndSettle();
      expect(container.read(defaultPlayerGroupProvider), 'Renamed');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const Key('player-roster-group')),
            )
            .value,
        '',
      );
      await _analyze(tester);
      expect(notifier.imports, isEmpty);
    },
  );
  testWidgets('returning to confirmation preserves this project attendance', (
    tester,
  ) async {
    final notifier = _RosterProject();
    await _pump(tester, notifier);
    await tester.tap(find.byKey(const ValueKey('roster-player-Alex')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('下一步').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('roster-player-Alex')),
          )
          .value,
      isFalse,
    );
    await _analyze(tester);
    expect(notifier.imports, [
      ['Chris', 'Blake'],
    ]);
  });

  testWidgets(
    'multi-video confirmation defers roster import until queue analysis',
    (tester) async {
      final notifier = _RosterProject(multi: true);
      await _pump(tester, notifier);
      await tester.tap(find.byKey(const ValueKey('roster-player-Alex')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-save-segment')));
      await tester.pumpAndSettle();
      expect(notifier.imports, isEmpty);
      await tester.tap(find.byKey(const Key('import-analyze-all')));
      await tester.pumpAndSettle();
      expect(notifier.events, ['apply', 'import', 'queue']);
      expect(notifier.imports, [
        ['Chris', 'Blake'],
      ]);
    },
  );
  testWidgets(
    'confirm defaults to the saved roster with every player checked',
    (tester) async {
      final notifier = _RosterProject();
      await _pump(tester, notifier);
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const Key('player-roster-group')),
            )
            .value,
        'Saturday',
      );
      for (final name in _names) {
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(ValueKey('roster-player-$name')),
              )
              .value,
          isTrue,
        );
      }
      expect(notifier.imports, isEmpty);
    },
  );

  testWidgets(
    'unchecked players are excluded and rechecking preserves group order',
    (tester) async {
      final notifier = _RosterProject();
      final container = await _pump(tester, notifier);
      for (final name in ['Alex', 'Chris', 'Chris']) {
        final checkbox = find.byKey(ValueKey('roster-player-$name'));
        await tester.ensureVisible(checkbox);
        await tester.tap(checkbox);
        await tester.pumpAndSettle();
      }
      await _analyze(tester);
      expect(notifier.imports, [
        ['Chris', 'Blake'],
      ]);
      expect(notifier.events, ['apply', 'import', 'analyze']);
      expect(container.read(playerGroupsProvider).single.players, _names);
      final persisted = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          playerGroupsPrefsKey,
        )!,
      );
      expect(persisted.single['players'], _names);
    },
  );

  testWidgets(
    'no groups shows a useful prompt and invalid defaults are cleared',
    (tester) async {
      final notifier = _RosterProject();
      final container = await _pump(tester, notifier, withGroups: false);
      expect(find.text('还没有球员分组，可以在审核页把球员存为分组。'), findsOneWidget);
      expect(find.byKey(const Key('player-roster-group')), findsNothing);
      expect(container.read(defaultPlayerGroupProvider), isNull);
      await _analyze(tester);
      expect(notifier.events, ['apply', 'analyze']);
    },
  );

  testWidgets('an existing project does not automatically import the default', (
    tester,
  ) async {
    final notifier = _RosterProject(existing: true);
    final container = await _pump(tester, notifier);
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const Key('player-roster-group')),
          )
          .value,
      '',
    );
    expect(find.byType(CheckboxListTile), findsNothing);
    await _analyze(tester);
    expect(notifier.imports, isEmpty);
    expect(container.read(projectProvider).players.single['name'], 'Alex');
  });

  testWidgets(
    'explicit imports append without deleting, reordering or duplicating existing players',
    (tester) async {
      final notifier = _RosterProject(existing: true);
      final container = await _pump(tester, notifier);
      await _selectGroup(tester, 'Saturday');
      await _analyze(tester);
      await _analyze(tester);
      expect(notifier.imports, [_names, _names]);
      expect(container.read(projectProvider).players.map((p) => p['name']), [
        'Alex',
        'Chris',
        'Blake',
      ]);
    },
  );

  testWidgets('none and an entirely unchecked roster do not import anyone', (
    tester,
  ) async {
    final notifier = _RosterProject();
    await _pump(tester, notifier);
    for (final name in _names) {
      final checkbox = find.byKey(ValueKey('roster-player-$name'));
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
    }
    await _analyze(tester);
    await _selectGroup(tester, '不使用');
    await _analyze(tester);
    expect(notifier.imports, isEmpty);
  });

  testWidgets(
    'deleting the selected group falls back to none without an import',
    (tester) async {
      final notifier = _RosterProject();
      final container = await _pump(tester, notifier);
      await container.read(playerGroupsProvider.notifier).delete('Saturday');
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      await _analyze(tester);
      expect(notifier.imports, isEmpty);
    },
  );

  testWidgets('default can be set and cleared from the confirmation step', (
    tester,
  ) async {
    final notifier = _RosterProject();
    final container = await _pump(tester, notifier, withDefault: false);
    await _selectGroup(tester, 'Saturday');
    final button = find.byKey(const Key('player-roster-default'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(container.read(defaultPlayerGroupProvider), 'Saturday');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(container.read(defaultPlayerGroupProvider), isNull);
  });

  testWidgets('a failed roster import does not start analysis', (tester) async {
    final notifier = _RosterProject(failImport: true);
    await _pump(tester, notifier);
    await _analyze(tester);
    expect(notifier.events, ['apply', 'import']);
  });

  testWidgets(
    'English confirmation roster has no untranslated interface copy',
    (tester) async {
      await _pump(tester, _RosterProject(), english: true);
      final roster = find.byType(PlayerRosterPicker);
      expect(
        find.descendant(of: roster, matching: find.text('Player roster')),
        findsOneWidget,
      );
      final texts = tester.widgetList<Text>(
        find.descendant(of: roster, matching: find.byType(Text)),
      );
      for (final text in texts) {
        expect(text.data ?? '', isNot(matches(RegExp(r'[\u4e00-\u9fff]'))));
      }
    },
  );
}
