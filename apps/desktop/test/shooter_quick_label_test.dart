import 'package:desktop/core/engine_session.dart';
import 'package:desktop/features/review/shooter_quick_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReviewEngine {
  final saves = <JsonMap>[];
  bool rejectSave = false, draft = false;
  int rowCount = 2;
  int releaseOffset = 0;
  int? savedTimeMs;
  final players = <JsonMap>[
    {'id': 'red', 'name': 'Red'},
    {'id': 'green', 'name': 'Green'},
  ];
  final createdNames = <String>[];

  Future<JsonMap> request(String command, JsonMap payload) async {
    if (command == 'list_shooter_review') {
      return {
        'players': players,
        'videos': [
          {'id': 'video'},
        ],
        'jobs': [],
        'candidates': [
          for (var i = 0; i < rowCount; i++)
            {
              'id': draft ? 'draft:c$i' : 'c$i',
              'draft': draft,
              'video_id': 'video',
              'event_time_ms': 1800 + i * 2000,
              'review_status': 'excluded',
              'selection_status': 'excluded',
              'player_id': null,
              'shooter_review_state': 'pending',
              'shooter_selection': <String, dynamic>{
                if (savedTimeMs != null) ...{
                  'generation': 'g1',
                  'time_ms': savedTimeMs,
                },
              },
              'shooter_evidence': {
                'generation': 'g1',
                'method': 'ball_release_preview_v1',
                'release_time_ms': 1100 + i * 2000 + releaseOffset,
                'release_uncertain': true,
                'frames': [
                  for (final delta in [-100, 0, 100])
                    {
                      'time_ms': 1100 + i * 2000 + delta,
                      'context_path': null,
                      'focus_region': {
                        'kind': 'approximate_release_area',
                        'crop_path': null,
                      },
                    },
                ],
              },
            },
        ],
      };
    }
    if (command == 'set_candidate_shooter') {
      if (rejectSave) throw StateError('Save failed');
      saves.add(Map.of(payload));
      return {
        'updated': true,
        'selection': Map.of(payload),
        'review_state': payload['review_state'],
      };
    }
    if (command == 'create_player') {
      createdNames.add(payload['name'] as String);
      final player = <String, dynamic>{
        'id': 'new-player',
        'name': payload['name'],
      };
      players.add(player);
      return {'player': player};
    }
    throw StateError('Unexpected command: $command');
  }
}

Future<void> _pump(
  WidgetTester tester,
  _ReviewEngine engine, {
  Size size = const Size(1400, 1100),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ShooterQuickLabel(request: engine.request),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('narrow cards with large text keep player actions usable', (
    tester,
  ) async {
    final engine = _ReviewEngine();
    engine.players.first['name'] = 'A long player name that needs wrapping';
    await _pump(tester, engine, size: const Size(760, 1100), textScale: 2);
    final name = find.byKey(const ValueKey('shooter-name-c0-red'));
    await tester.ensureVisible(name);
    await tester.tap(name);
    await tester.pumpAndSettle();
    expect(engine.saves.single['player_id'], 'red');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop grid has five portrait cards and displays only the middle frame by default',
    (tester) async {
      final engine = _ReviewEngine()
        ..rowCount = 6
        ..releaseOffset = -100;
      await _pump(tester, engine);
      final cards = [
        for (var i = 0; i < 6; i++) find.byKey(ValueKey('shooter-card-c$i')),
      ];
      expect(tester.getTopLeft(cards[0]).dy, tester.getTopLeft(cards[4]).dy);
      expect(
        tester.getTopLeft(cards[5]).dy,
        greaterThan(tester.getTopLeft(cards[0]).dy),
      );
      final photoSize = tester.getSize(
        find.byKey(const ValueKey('shooter-photo-c0')),
      );
      expect(photoSize.width / photoSize.height, closeTo(3 / 4, .001));
      expect(tester.getSize(cards[0]).height, lessThan(620));
      expect(
        find.byKey(const ValueKey('shooter-preview-c0-1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shooter-preview-c0-0')), findsNothing);
      expect(find.byKey(const ValueKey('shooter-preview-c0-2')), findsNothing);
      final frames = [
        for (var i = 0; i < 3; i++) find.byKey(ValueKey('shooter-frame-c0-$i')),
      ];
      expect(tester.getTopLeft(frames[0]).dy, tester.getTopLeft(frames[2]).dy);
      expect(
        tester.getTopLeft(frames[0]).dx,
        lessThan(tester.getTopLeft(frames[1]).dx),
      );
      expect(
        tester.getTopLeft(frames[1]).dx,
        lessThan(tester.getTopLeft(frames[2]).dx),
      );
      await tester.tap(frames[2]);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('shooter-preview-c0-2')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shooter-preview-c0-1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('shooter-name-c0-red')));
      await tester.pumpAndSettle();
      expect(engine.saves.single['time_ms'], 1200);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved human frame is restored and can be switched back to the middle',
    (tester) async {
      final engine = _ReviewEngine()
        ..savedTimeMs = 1000;
      await _pump(tester, engine);
      expect(
        find.byKey(const ValueKey('shooter-preview-c0-0')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shooter-preview-c0-1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('shooter-frame-c0-1')));
      await tester.tap(find.byKey(const ValueKey('shooter-name-c0-green')));
      await tester.pumpAndSettle();
      expect(engine.saves.single['time_ms'], 1100);
      expect(
        find.byKey(const ValueKey('shooter-preview-c0-1')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final emptyRoster in [false, true]) {
    testWidgets(
      'card add-player is always available and assigns only this shot; empty=$emptyRoster',
      (tester) async {
        final engine = _ReviewEngine();
        if (emptyRoster) engine.players.clear();
        await _pump(tester, engine);
        await tester.tap(find.byKey(const ValueKey('shooter-frame-c0-2')));
        await tester.tap(find.byKey(const ValueKey('shooter-add-player-c0')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '  New player  ');
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(FilledButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(engine.createdNames, ['New player']);
        expect(engine.saves.single['candidate_id'], 'c0');
        expect(engine.saves.single['player_id'], 'new-player');
        expect(engine.saves.single['time_ms'], 1200);
        expect(engine.saves.single.containsKey('status'), isFalse);
        expect(engine.saves.single.containsKey('outcome'), isFalse);
        expect(
          find.byKey(const ValueKey('shooter-add-player-c0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('shooter-name-c1-new-player')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('embedded watch action calls parent instead of closing review', (
    tester,
  ) async {
    final engine = _ReviewEngine();
    String? watched;
    await tester.pumpWidget(
      MaterialApp(
        home: ShooterQuickLabel(
          embedded: true,
          request: engine.request,
          onWatchClip: (id) => watched = id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('shooter-card-c0'));
    await tester.ensureVisible(
      find.descendant(of: card, matching: find.text('Watch clip')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: card, matching: find.text('Watch clip')),
    );
    await tester.pumpAndSettle();
    expect(watched, 'c0');
    expect(find.byType(ShooterQuickLabel), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: ShooterQuickLabel(
          embedded: true,
          active: false,
          request: engine.request,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    expect(engine.saves, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'release areas are read-only during analysis and save names without tracks after completion',
    (tester) async {
      final engine = _ReviewEngine()..draft = true;
      await _pump(tester, engine);
      final name = find.byKey(const ValueKey('shooter-name-draft:c0-red'));
      expect(tester.widget<FilledButton>(name).onPressed, isNull);
      expect(find.text('Analysis preview'), findsNWidgets(2));
      engine.draft = false;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Uncertain'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();
      expect(engine.saves.single['player_id'], 'red');
      expect(engine.saves.single.containsKey('track_id'), isFalse);
      expect(engine.saves.single['review_state'], 'confirmed');
      expect(find.byKey(const ValueKey('shooter-card-c0')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saves the selected frame and shooter without changing outcome',
    (tester) async {
      final engine = _ReviewEngine();
      await _pump(tester, engine);
      await tester.tap(find.byKey(const ValueKey('shooter-frame-c0-2')));
      await tester.tap(find.byKey(const ValueKey('shooter-name-c0-green')));
      await tester.pumpAndSettle();
      expect(engine.saves.single, containsPair('time_ms', 1200));
      expect(engine.saves.single, containsPair('player_id', 'green'));
      expect(engine.saves.single, containsPair('generation', 'g1'));
      expect(engine.saves.single.containsKey('status'), isFalse);
      expect(engine.saves.single.containsKey('outcome'), isFalse);
      expect(find.text('Shooter: Green'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed save stays pending; retry and undo restore the previous label',
    (tester) async {
      final engine = _ReviewEngine()..rejectSave = true;
      await _pump(tester, engine);
      final name = find.byKey(const ValueKey('shooter-name-c0-red'));
      await tester.tap(name);
      await tester.pumpAndSettle();
      expect(engine.saves, isEmpty);
      expect(find.textContaining('Save failed'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      engine.rejectSave = false;
      await tester.tap(name);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(engine.saves.last['review_state'], 'pending');
      expect(engine.saves.last['player_id'], isNull);
      expect(find.text('Saved'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard label applies only to selected card; uncertain is independently persisted',
    (tester) async {
      final engine = _ReviewEngine();
      await _pump(tester, engine);
      await tester.tap(find.byKey(const ValueKey('shooter-frame-c1-1')));
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();
      expect(engine.saves.single['candidate_id'], 'c1');
      expect(engine.saves.single['player_id'], 'red');
      final card = find.byKey(const ValueKey('shooter-card-c1'));
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.widgetWithText(TextButton, 'Uncertain'),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.saves.last['review_state'], 'uncertain');
      expect(engine.saves.last['player_id'], isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
