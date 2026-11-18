import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'tiers_ui_test.dart' as harness;
import 'tiers_i18n_test_support.dart';

void main() {
  final cjk = RegExp(r'[\u4e00-\u9fff]');
  setUpAll(loadSdkTextFont);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
      'courtside.sidebar_extended': false,
    }),
  );
  harness.FakeProject project({
    String? tierReason,
    Map<String, dynamic>? rimCheck,
  }) {
    final notifier = harness.FakeProject();
    notifier.initial = harness.fixture().copyWith(
      video: {'id': 'synthetic-video'},
      candidates: [
        {
          ...harness.fixture().candidates[0],
          'tier': rimCheck?['status'] == 'made' ? 'must' : 'suspect',
          'tier_source': 'algorithm',
          'review_status': 'pending',
          'selection_status': 'pending',
          'tier_reason': tierReason,
          if (rimCheck != null)
            'evidence_json': jsonEncode({'rim_check': rimCheck}),
        },
      ],
    );
    return notifier;
  }

  String summary(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('candidate-evidence-summary')),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data ?? '')
      .join(' ');
  void expectFits(WidgetTester tester, String label) {
    final finder = find.text(label);
    expect(finder, findsWidgets, reason: 'Required control missing: $label');
    for (final element in finder.evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      final painter = TextPainter(
        text: paragraph.text,
        textDirection: paragraph.textDirection,
        textScaler: paragraph.textScaler,
        maxLines: paragraph.maxLines,
        ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '…' : null,
      )..layout(maxWidth: paragraph.size.width);
      expect(painter.didExceedMaxLines, isFalse, reason: '$label is truncated');
      painter.dispose();
      expect(paragraph.text.toPlainText(), isNot(contains('…')));
    }
  }

  for (final width in [1280.0, 1440.0]) {
    testWidgets('en required controls fit at $width', (tester) async {
      final notifier = harness.FakeProject();
      notifier.initial = harness.fixture().copyWith(
        video: {'id': 'synthetic-video'},
      );
      await harness.pump(
        tester,
        notifier,
        size: Size(width, 900),
        locale: const Locale('en'),
      );
      for (final label in [
        'Clips',
        'Goals 3',
        'Uncertain 3',
        'Excluded 3',
        'All 9',
        'Keep · Scored',
        'Exclude · Miss',
        'Add missed',
      ]) {
        expectFits(tester, label);
      }
      await tester.tap(
        find.byKey(const Key('candidate-evidence-details-toggle')),
      );
      await tester.pumpAndSettle();
      expectFits(tester, 'Confidence');
      expect(tester.takeException(), isNull);
    });
  }
  const reasons = [
    'no_crossing',
    'no_entry',
    'off_center',
    'exit_off_center',
    'rebound',
    'no_exit',
    'not_occluded',
    'small_rim',
    'net_still',
  ];
  for (final status in ['rejected', 'unsure', 'skipped']) {
    testWidgets('all mapped rim reasons render in English: $status', (
      tester,
    ) async {
      for (final reason in reasons) {
        await harness.pump(
          tester,
          project(rimCheck: {'status': status, 'reason': reason}),
          locale: const Locale('en'),
        );
        final text = summary(tester);
        expect(cjk.hasMatch(text), isFalse, reason: '$status/$reason: $text');
        expect(
          text,
          startsWith(
            status == 'rejected'
                ? 'Rim check failed · '
                : 'Rim check needs confirmation · ',
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });
  }
  for (final reason in ['r2_net_motion', 'r1_complete_crossing']) {
    testWidgets('made sentence translates each segment: $reason', (
      tester,
    ) async {
      await harness.pump(
        tester,
        project(tierReason: reason, rimCheck: {'status': 'made'}),
        locale: const Locale('en'),
      );
      await tester.tap(find.byKey(const Key('review-status-must')));
      await tester.pumpAndSettle();
      final text = summary(tester);
      expect(cjk.hasMatch(text), isFalse);
      expect(text, startsWith('Rim check: made · '));
      expect(text, contains('the ball dropped from the bottom of the net'));
    });
  }
}
