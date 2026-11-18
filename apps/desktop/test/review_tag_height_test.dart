import 'package:desktop/providers/onboarding_provider.dart';
import 'package:flutter/gestures.dart';
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
  testWidgets(
    'L440 same card 0 to 4 tags keeps height, one line, aligned text add and full tooltip',
    (tester) async {
      final notifier = harness.FakeProject();
      final players = [
        {'id': 'p1', 'name': '科比'},
        {'id': 'p2', 'name': '持球突破后的三分球'},
        {'id': 'p3', 'name': '库里'},
        {'id': 'p4', 'name': '反击快攻'},
      ];
      notifier.initial = harness.fixture().copyWith(
        players: players,
        candidates: [
          for (final i in [3, 4, 5])
            {
              ...harness.fixture().candidates[i],
              'tags': [if (i > 3) players[0], if (i == 5) ...players.skip(1)],
            },
        ],
      );
      await harness.pump(tester, notifier, size: const Size(1428, 880));
      final row = find.byKey(const ValueKey('candidate-row-c3'));
      final next = find.byKey(const ValueKey('candidate-row-c4'));
      final original = tester.getSize(row).height;
      final nextTop = tester.getTopLeft(next).dy;
      expect(original, 80);
      final add = find.byKey(const ValueKey('player-tag-add-c3'));
      expect(
        find.descendant(of: add, matching: find.text('+ 标签')),
        findsOneWidget,
      );
      final time = find
          .descendant(of: row, matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('#1 ')))
          .first;
      expect(tester.getTopLeft(add).dx, tester.getTopLeft(time).dx);
      final button = tester.widget<TextButton>(add);
      expect(button.style!.padding!.resolve({}), EdgeInsets.zero);
      expect(
        button.style!.overlayColor!.resolve({WidgetState.hovered}),
        Colors.transparent,
      );
      expect(
        button.style!.backgroundColor!.resolve({WidgetState.hovered}),
        Colors.transparent,
      );
      expect(
        button.style!.foregroundColor!.resolve({WidgetState.hovered}),
        isNot(button.style!.foregroundColor!.resolve({})),
      );
      for (final key in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(tester.getSize(row).height, original);
        expect(tester.getTopLeft(next).dy, nextTop);
        expect(tester.takeException(), isNull);
      }
      expect(
        find.descendant(of: add, matching: find.text('+')),
        findsOneWidget,
      );
      final badge = find.byKey(const ValueKey('player-tag-overflow-c3'));
      expect(badge, findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(badge));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('科比、持球突破后的三分球、库里、反击快攻'), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      // Return the first row to zero tags; the rendered sample contains 0 / 1 / 4.
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pumpAndSettle();
      expect(tester.getSize(row).height, original);
      expect(
        tester.getSize(find.byKey(const ValueKey('candidate-row-c5'))).height,
        original,
      );
      await harness.screenshot(tester, 'l440-1428-tags-0-1-4');
      await tester.tap(find.byKey(const ValueKey('player-tag-add-c5')));
      await tester.pumpAndSettle();
      expect(find.text('选择标签 · 可多选'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
