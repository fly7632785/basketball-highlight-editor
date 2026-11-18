import 'dart:convert';
import 'dart:io';

import 'package:desktop/features/review/tier_selection.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tiers_ui_test.dart' as harness;

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

  testWidgets(
    'collapsed group stays suspect and is skipped by arrows and S; expanded is reviewable',
    (tester) async {
      final notifier = groupedProject();
      await harness.pump(tester, notifier);
      expect(find.text('疑似 2'), findsOneWidget);
      expect(find.text('可能没进 1 · 没看到球靠近篮筐'), findsOneWidget);
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
      expect(find.text('可能没进 · 没看到球靠近篮筐'), findsOneWidget);
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

  testWidgets(
    'all tab sinks group; collapsing selected group clears hidden selection; filters still apply',
    (tester) async {
      final notifier = groupedProject();
      await harness.pump(tester, notifier);
      await tester.tap(find.byKey(const ValueKey('review-status-all')));
      await tester.pumpAndSettle();
      expect(find.text('全部 3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('review-likely-miss-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tier-dot-c3')));
      await tester.pumpAndSettle();
      expect(find.text('候选 00:36'), findsOneWidget);
      await tester.tap(find.byKey(const Key('review-likely-miss-group')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsNothing);
      expect(find.text('候选 00:45'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('review-tag-option-untagged')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('review-likely-miss-group')), findsNothing);
      expect(find.byKey(const ValueKey('candidate-row-c5')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
        expect(find.text('可能没进 65 · 没看到球靠近篮筐'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await harness.screenshot(tester, 'l439b-${width.toInt()}-collapsed');
        await tester.tap(group);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).last, const Offset(0, -250));
        await tester.pumpAndSettle();
        final firstLikely = candidates.firstWhere(candidateLikelyMiss);
        await tester.tap(find.byKey(ValueKey('tier-dot-${firstLikely['id']}')));
        await tester.pumpAndSettle();
        expect(find.text('可能没进 · 没看到球靠近篮筐'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await harness.screenshot(tester, 'l439b-${width.toInt()}-expanded');
      });
    }
  }
}
