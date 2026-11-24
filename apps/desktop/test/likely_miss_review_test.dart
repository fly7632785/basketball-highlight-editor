import 'dart:convert';
import 'dart:io';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/features/review/tier_selection.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tiers_ui_test.dart' as harness;

class _BulkProject extends ProjectNotifier {
  _BulkProject(this.initial);

  final ProjectState initial;

  @override
  ProjectState build() => initial;
}

class _BulkReviewTransport implements EngineTransport {
  _BulkReviewTransport(this.initial)
    : stored = {
        for (final c in initial.candidates) c['id'] as String: {...c},
      };

  final ProjectState initial;
  final Map<String, JsonMap> stored;
  final writes = <(String, String)>[];

  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    switch (command) {
      case 'start_review':
        return {};
      case 'get_statistics':
        return {'statistics': initial.statistics};
      case 'list_candidates':
        return {'candidates': stored.values.toList(), 'players': initial.players};
      case 'review_candidate':
        final id = payload['candidate_id'] as String;
        final status = payload['status'] as String;
        writes.add((id, status));
        final original = initial.candidates.singleWhere((c) => c['id'] == id);
        stored[id] = {
          ...stored[id]!,
          'review_status': status,
          'review_reason': payload['reason'],
          'note': payload['note'],
          'selection_status': status == 'excluded' ? 'excluded' : original['selection_status'],
          'tier': status == 'excluded' ? 'excluded' : original['tier'],
          'tier_source': status == 'excluded' ? 'user' : original['tier_source'],
        };
        return {'updated': true};
      default:
        throw StateError('Unexpected command: $command');
    }
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
      'courtside.sidebar_extended': false,
    }),
  );

  harness.FakeProject groupedProject() {
    final notifier = harness.FakeProject();
    notifier.initial = harness.fixture().copyWith(
      candidates: [
        for (final i in [3, 4, 5])
          {...harness.fixture().candidates[i], 'likely_miss': i == 3},
      ],
    );
    return notifier;
  }

  testWidgets('bulk miss confirms the filtered count, saves and undoes one batch', (
    tester,
  ) async {
    final fixture = harness.fixture();
    final initial = fixture.copyWith(
      candidates: [
        for (final (index, candidate) in fixture.candidates.take(5).indexed)
          {
            ...candidate,
            'tier': 'suspect',
            'tier_source': 'algorithm',
            'review_status': index == 2 ? 'second_review' : 'pending',
            'review_reason': index == 2 ? 'uncertain' : null,
            'selection_status': 'included',
            'likely_miss': index < 4,
            'note': 'Note $index',
            'tags': index >= 3 ? [fixture.players.first] : <JsonMap>[],
          },
      ],
    );
    final transport = _BulkReviewTransport(initial);
    final session = ProjectSession(EngineSession(transport));
    session.restore(const ProjectSessionCheckpoint(
      projectRoot: '/virtual/l505',
      projectId: 'tiers-ui-fixture',
    ));
    final notifier = _BulkProject(initial);
    final app = await harness.pump(tester, notifier, session: session);
    const button = Key('review-bulk-miss');
    expect(find.text('可能没进 4 · 没看到球穿过篮筐'), findsOneWidget);
    expect(find.byKey(button), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('review-tag-option-untagged')));
    await tester.pumpAndSettle();
    expect(find.text('可能没进 3 · 没看到球穿过篮筐'), findsOneWidget);

    await tester.tap(find.byKey(button));
    await tester.pumpAndSettle();
    expect(find.text('将这 2 段未判定片段标为没进。可在撤销里恢复。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(transport.writes, isEmpty);

    await tester.tap(find.byKey(button));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('review-bulk-miss-confirm')));
    await tester.pumpAndSettle();
    expect(transport.writes, [('c0', 'excluded'), ('c1', 'excluded')]);
    expect(notifier.reviewUndoDepth, 1);
    for (final candidate in app.container.read(projectProvider).candidates.take(2)) {
      expect(candidate['review_status'], 'excluded');
      expect(candidate['tier_source'], 'user');
      expect(transport.stored[candidate['id']]!['tier_source'], 'user');
    }
    for (final candidate in initial.candidates.skip(2)) {
      expect(transport.stored[candidate['id']], candidate);
    }
    expect(tester.widget<TextButton>(find.byKey(button)).onPressed, isNull);

    expect(find.byKey(const Key('inspector-undo')), findsNothing);
    await tester.tap(find.byKey(const Key('review-empty-undo')));
    await tester.pumpAndSettle();
    expect(notifier.reviewUndoDepth, 0);
    expect(transport.writes, [
      ('c0', 'excluded'), ('c1', 'excluded'), ('c1', 'pending'), ('c0', 'pending'),
    ]);
    expect(transport.stored.values.toList(), initial.candidates);
    expect(find.text('可能没进 3 · 没看到球穿过篮筐'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bulk miss control and confirmation are localized in English', (
    tester,
  ) async {
    await harness.pump(tester, groupedProject(), locale: const Locale('en'));
    expect(find.text('Mark all as missed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-bulk-miss')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.text('Mark 1 unreviewed clip as missed? You can undo this action.'), findsOneWidget);
    final texts = tester.widgetList<Text>(
      find.descendant(of: dialog, matching: find.byType(Text)),
    );
    expect(texts.every((text) => !RegExp(r'[\u3400-\u9fff]').hasMatch(text.data ?? '')), isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-status-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-bulk-miss')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  if (const String.fromEnvironment('BHE_TIERS_SCREENSHOTS').isNotEmpty) {
    for (final hasFold in [true, false]) {
      testWidgets('L505 screenshot ${hasFold ? 'with' : 'without'} fold', (tester) async {
        final notifier = groupedProject();
        if (!hasFold) {
          notifier.initial = notifier.initial.copyWith(
            candidates: [
              for (final c in notifier.initial.candidates) {...c, 'likely_miss': false},
            ],
          );
        }
        await harness.pump(tester, notifier, size: const Size(1428, 880));
        expect(find.byKey(const Key('review-bulk-miss')), hasFold ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
        await harness.screenshot(tester, hasFold ? 'l505-with-fold' : 'l505-without-fold');
      });
    }
  }

  testWidgets(
    'collapsed group stays suspect and is skipped by arrows and S; expanded is reviewable',
    (tester) async {
      final notifier = groupedProject();
      await harness.pump(tester, notifier);
      expect(find.text('疑似 2'), findsOneWidget);
      expect(find.text('可能没进 1 · 没看到球穿过篮筐'), findsOneWidget);
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsNothing);
      expect(find.text('候选 00:45'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.text('候选 00:54'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.text('候选 00:54'), findsOneWidget);
      expect(notifier.current.candidates.first['tier'], 'suspect');
      await tester.tap(find.byKey(const Key('review-likely-miss-group')));
      await tester.pumpAndSettle();
      final normal = tester.getTopLeft(
        find.byKey(const ValueKey('candidate-row-c5')),
      );
      final far = tester.getTopLeft(
        find.byKey(const ValueKey('candidate-row-c3')),
      );
      expect(
        far.dy,
        greaterThan(normal.dy),
        reason: 'group must sink even when its event is earlier',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.text('候选 00:36'), findsOneWidget);
      expect(find.text('可能没进 · 没看到球穿过篮筐'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(notifier.current.candidates.first['tier'], 'must');
      expect(candidateLikelyMiss(notifier.current.candidates.first), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.pumpAndSettle();
      expect(notifier.current.candidates.first['tier'], 'excluded');
      await tester.tap(find.byKey(const ValueKey('review-status-excluded')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(notifier.current.candidates.first['tier'], 'must');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all tab shows every candidate and keeps filters effective', (
    tester,
  ) async {
    final notifier = groupedProject();
    await harness.pump(tester, notifier);
    await tester.tap(find.byKey(const ValueKey('review-status-all')));
    await tester.pumpAndSettle();
    expect(find.text('全部 3'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('candidate-row-c3')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('candidate-row-c3')), findsOneWidget);
    expect(find.byKey(const Key('review-likely-miss-group')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('candidate-row-c3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspector-keep')));
    await tester.pumpAndSettle();
    expect(notifier.current.candidates.first['tier'], 'must');
    expect(find.byKey(const ValueKey('candidate-row-c3')), findsOneWidget);

    // A secondary tag filter still limits the all-candidates list.
    await tester.tap(find.byKey(const ValueKey('review-tag-option-untagged')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-likely-miss-group')), findsNothing);
    expect(find.byKey(const ValueKey('candidate-row-c5')), findsOneWidget);
    expect(find.byKey(const ValueKey('candidate-row-c3')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'only likely misses still show an expandable group and can be manually excluded',
    (tester) async {
      final notifier = groupedProject();
      notifier.initial = notifier.initial.copyWith(
        candidates: [notifier.initial.candidates.first],
      );
      await harness.pump(tester, notifier);
      expect(find.text('疑似 0'), findsOneWidget);
      expect(find.byKey(const Key('review-likely-miss-group')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(notifier.current.candidates.first['tier'], 'suspect');
      await tester.tap(find.byKey(const Key('review-likely-miss-group')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pumpAndSettle();
      expect(notifier.current.candidates.first['tier'], 'excluded');
      expect(notifier.current.candidates.first['tier_source'], 'user');
      expect(tester.takeException(), isNull);
    },
  );

  // Optional local evidence rendering uses a read-only snapshot, never a live DB.
  const snapshot = String.fromEnvironment('BHE_L439B_FIXTURE');
  if (snapshot.isNotEmpty) {
    for (final width in [1428.0, 1280.0]) {
      testWidgets('L439b l437 snapshot ${width.toInt()} collapsed expanded', (
        tester,
      ) async {
        late List<Map<String, dynamic>> candidates;
        await tester.runAsync(() async {
          candidates = (jsonDecode(await File(snapshot).readAsString()) as List)
              .map((c) => Map<String, dynamic>.from(c as Map))
              .toList();
        });
        final notifier = harness.FakeProject();
        notifier.initial = harness.fixture().copyWith(
          candidates: candidates,
          players: [],
        );
        await harness.pump(tester, notifier, size: Size(width, 880));
        expect(find.text('进球 8'), findsOneWidget);
        expect(find.text('疑似 34'), findsOneWidget);
        expect(find.text('排除 21'), findsOneWidget);
        final group = find.byKey(const Key('review-likely-miss-group'));
        // The group is genuinely at the end, not a duplicated sticky header.
        await tester.scrollUntilVisible(
          group,
          500,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(find.text('可能没进 65 · 没看到球穿过篮筐'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await harness.screenshot(tester, 'l439b-${width.toInt()}-collapsed');
        await tester.tap(group);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).last, const Offset(0, -250));
        await tester.pumpAndSettle();
        final firstLikely = candidates.firstWhere(candidateLikelyMiss);
        await tester.tap(find.byKey(ValueKey('tier-dot-${firstLikely['id']}')));
        await tester.pumpAndSettle();
        expect(find.text('可能没进 · 没看到球穿过篮筐'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await harness.screenshot(tester, 'l439b-${width.toInt()}-expanded');
      });
    }
  }
}
