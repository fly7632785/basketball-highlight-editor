import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/features/export/export_screen.dart';

import 'tiers_ui_test.dart' as harness;

/// L444：分档界面英文补齐。en 渲染审核页和导出页不得漏出中文；
/// zh 模式的既有文字保持不变。
void main() {
  final cjk = RegExp(r'[\u4e00-\u9fff]');

  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
      'courtside.sidebar_extended': false,
    }),
  );

  harness.FakeProject enProject() {
    final notifier = harness.FakeProject();
    notifier.initial = harness.fixture().copyWith(
      players: [
        for (final p in harness.fixture().players)
          {'id': p['id'], 'name': p['name']},
      ],
      candidates: [
        // 与 tiers_ui_test.fixture 相同的 9 个候选，补上 tier 证据字段，
        // 保证依据句、可能没进折叠组都会渲染。球员名是用户数据，不翻译。
        for (var i = 0; i < 9; i++)
          {
            ...harness.fixture().candidates[i],
            'tier_reason': i < 3
                ? 'r2_net_motion'
                : i == 3
                ? 'contrary_evidence'
                : null,
            'likely_miss': i == 3,
          },
      ],
    );
    return notifier;
  }

  Iterable<String> visibleTexts(WidgetTester tester) =>
      tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s.isNotEmpty);

  /// 球员名是用户数据，英文模式下保留原文，不算泄漏。
  bool _isUserData(String s, Set<String> names) =>
      names.any(s.contains);

  testWidgets('review page renders fully in English without CJK', (
    tester,
  ) async {
    await harness.pump(tester, enProject(), locale: const Locale('en'));

    // 四档 chip
    expect(find.text('Goals 3'), findsOneWidget);
    expect(find.text('Uncertain 2'), findsOneWidget);
    expect(find.text('Excluded 3'), findsOneWidget);
    expect(find.textContaining('All 9'), findsOneWidget);
    // 可能没进折叠组
    expect(
      find.text('Maybe missed 1 · the ball never came near the rim'),
      findsOneWidget,
    );
    // 悬停说明（Tooltip.message 不经过 Text，检查内容）
    final tierTooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '');
    expect(
      tierTooltips.any((m) => m.startsWith('Goals the app is confident')),
      isTrue,
    );
    expect(
      tierTooltips.any((m) => m.startsWith('The ball never came near the rim')),
      isTrue,
    );

    // 展开依据详情
    await tester.tap(
      find.byKey(const Key('candidate-evidence-details-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('candidate-evidence-overlay')), findsOneWidget);

    // 更多筛选面板
    await tester.tap(find.byKey(const Key('review-tag-more')));
    await tester.pumpAndSettle();

    final userNames = {'科比', '三分', '囧', '空标签'};
    final leaked = visibleTexts(tester)
        .where(cjk.hasMatch)
        .where((s) => !_isUserData(s, userNames))
        .toList();
    expect(leaked, isEmpty, reason: 'en 渲染不得出现中文: $leaked');
    expect(tester.takeException(), isNull);
  });

  testWidgets('export page renders fully in English without CJK', (
    tester,
  ) async {
    final app = await harness.pump(
      tester,
      enProject(),
      path: '/export',
      locale: const Locale('en'),
    );

    expect(find.text('Tier'), findsOneWidget);
    expect(find.textContaining('Goals'), findsWidgets);
    expect(find.text('Will export 3 clips · 00:27'), findsOneWidget);
    expect(find.text('Review these 3 clips →'), findsOneWidget);
    // 档位悬停说明
    final tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '');
    expect(
      tooltips.any((m) => m.startsWith('Goals the app is confident')),
      isTrue,
    );

    final leaked = visibleTexts(tester)
        .where(cjk.hasMatch)
        .where((s) => !s.contains('科比') && !s.contains('三分') && !s.contains('囧') && !s.contains('空标签'))
        .toList();
    expect(leaked, isEmpty, reason: 'en 渲染不得出现中文: $leaked');
    expect(tester.takeException(), isNull);
  });

  testWidgets('zh review page keeps existing copy', (tester) async {
    await harness.pump(tester, enProject(), locale: const Locale('zh'));

    expect(find.text('进球 3'), findsOneWidget);
    expect(find.text('疑似 2'), findsOneWidget);
    expect(find.text('排除 3'), findsOneWidget);
    expect(find.text('可能没进 1 · 没看到球靠近篮筐'), findsOneWidget);
    expect(find.text('更多筛选'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('candidate-evidence-details-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('依据详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
