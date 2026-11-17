import 'package:desktop/features/review/review_shortcuts.dart';
import 'dart:convert';
import 'package:desktop/components/cs_scaffold.dart';
import 'package:desktop/providers/session_provider.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/features/review/tier_selection.dart';
import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/features/export/export_screen.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/theme/app_theme.dart';

// Deliberately synthetic project. No user media or original database is opened.
ProjectState fixture() => ProjectState(
  statistics: const {
    'project': {'id': 'tiers-ui-fixture', 'name': '分档演示（合成数据）'},
  },
  players: const [
    {'id': 'p1', 'name': '科比'},
    {'id': 'p2', 'name': '三分'},
    {'id': 'p3', 'name': '囧'},
    {'id': 'p4', 'name': '空标签'},
  ],
  candidates: [
    for (var i = 0; i < 9; i++)
      {
        'id': 'c$i',
        'event_time_ms': (i + 1) * 9000,
        'default_start_ms': i * 9000,
        'default_end_ms': (i + 1) * 9000,
        'tier': i < 3
            ? 'must'
            : i < 6
            ? 'suspect'
            : 'excluded',
        'tier_source': i == 0 ? 'user' : 'algorithm',
        'review_status': i == 0
            ? 'goal'
            : i >= 6
            ? 'excluded'
            : 'pending',
        'selection_status': i < 3
            ? 'included'
            : i < 6
            ? 'pending'
            : 'excluded',
        'tags': [
          if (i != 5 && i != 8)
            {'id': i < 6 ? 'p1' : 'p3', 'name': i < 6 ? '科比' : '囧'},
          if (i == 0 || i == 3) {'id': 'p2', 'name': '三分'},
        ],
      },
  ],
);

class _ReadyEngine extends EngineBootstrapNotifier {
  @override
  AsyncValue<bool> build() => const AsyncData(true);
}

class FakeProject extends ProjectNotifier {
  ProjectState initial = fixture();
  final undo = <ProjectState>[];
  ProjectState get current => state;
  @override
  ProjectState build() => initial;
  @override
  Future<void> startReview(String id) async {}
  @override
  Future<String?> loadCandidatePreview(String id, int timeMs) async => null;
  @override
  Future<bool> reviewCandidate(
    String id,
    String status, {
    String? reason,
    bool showNotice = true,
  }) async {
    undo.add(state);
    state = state.copyWith(
      candidates: [
        for (final c in state.candidates)
          if (c['id'] == id)
            {
              ...c,
              'tier': status == 'excluded' ? 'excluded' : 'must',
              'tier_source': 'user',
              'review_status': status == 'excluded' ? 'excluded' : 'goal',
              'selection_status': status,
            }
          else
            c,
      ],
    );
    return true;
  }

  @override
  Future<void> changeCandidateTags(
    String id, {
    String? toggleId,
    List<String>? replaceIds,
  }) async {
    undo.add(state);
    final candidate = state.candidates.firstWhere((c) => c['id'] == id);
    final ids = candidateTagIds(candidate).toSet();
    if (toggleId == null) {
      ids.clear();
      ids.addAll(replaceIds ?? []);
    } else {
      ids.contains(toggleId) ? ids.remove(toggleId) : ids.add(toggleId);
    }
    state = state.copyWith(
      candidates: [
        for (final c in state.candidates)
          if (c['id'] == id)
            {
              ...c,
              'tags': [
                for (final p in state.players)
                  if (ids.contains(p['id'])) p,
              ],
            }
          else
            c,
      ],
    );
  }

  @override
  Future<void> undoReview() async {
    if (undo.isNotEmpty) state = undo.removeLast();
  }

  void switchProject() => state = state.copyWith(
    statistics: const {
      'project': {'id': 'another'},
    },
  );
}

Future<({GoRouter router, ProviderContainer container})> pump(
  WidgetTester tester,
  FakeProject notifier, {
  String path = '/review',
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: path,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => CsScaffold(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/home', builder: (_, _) => const SizedBox()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/import', builder: (_, _) => const SizedBox()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/review', builder: (_, _) => const ReviewScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/export', builder: (_, _) => const ExportScreen()),
            ],
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      projectProvider.overrideWith(() => notifier),
      engineBootstrapProvider.overrideWith(_ReadyEngine.new),
    ],
  );
  addTearDown(container.dispose);
  const font = String.fromEnvironment('BHE_TIERS_FONT');
  if (font.isNotEmpty) {
    await tester.runAsync(() async {
      final bytes = await File(font).readAsBytes();
      final manifest =
          jsonDecode(
                await File(
                  'build/unit_test_assets/FontManifest.json',
                ).readAsString(),
              )
              as List;
      for (final entry in manifest) {
        final item = (entry['fonts'] as List).first;
        final data = await File(
          'build/unit_test_assets/${item['asset']}',
        ).readAsBytes();
        await (FontLoader(
          entry['family'] as String,
        )..addFont(Future.value(ByteData.sublistView(data)))).load();
      }
      for (final family in ['Ahem', 'Inter', 'Roboto']) {
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    });
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: appTheme(Brightness.dark),
        locale: const Locale('zh'),
        localizationsDelegates: BheLocalizations.localizationsDelegates,
        supportedLocales: BheLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, container: container);
}

Future<void> screenshot(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('BHE_TIERS_SCREENSHOTS');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
      'courtside.sidebar_extended': false,
    }),
  );
  testWidgets(
    'review defaults suspect, tier counts and multi-tag OR are independent',
    (tester) async {
      final notifier = FakeProject();
      await pump(tester, notifier);
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsOneWidget);
      expect(find.byKey(const ValueKey('candidate-row-c0')), findsNothing);
      expect(find.textContaining('含 1 确认'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('review-status-must')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-row-c0')), findsOneWidget);
      if (find
          .byKey(const ValueKey('review-tag-option-player:p2'))
          .evaluate()
          .isEmpty) {
        await tester.tap(find.byKey(const Key('review-tag-more')));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byKey(const ValueKey('review-tag-option-player:p2')),
      );
      await tester.pumpAndSettle();
      expect(find.text('显示 1 / 9'), findsOneWidget);
      if (find
          .byKey(const ValueKey('review-tag-option-player:p1'))
          .evaluate()
          .isEmpty) {
        await tester.tap(find.byKey(const Key('review-tag-more')));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.byKey(const ValueKey('review-tag-option-player:p1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('显示 3 / 9'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('review-tag-option-all')));
      await tester.pumpAndSettle();
      expect(find.text('显示 3 / 9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'numeric/numpad/letter toggle, shifted physical digits replace, zero is undoable, S skips',
    (tester) async {
      final notifier = FakeProject();
      await pump(tester, notifier);
      List<String> ids() => candidateTagIds(notifier.current.candidates[3]);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pumpAndSettle();
      expect(ids(), ['p1']);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad2);
      await tester.pumpAndSettle();
      expect(ids(), ['p1', 'p2']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(
        LogicalKeyboardKey.exclamation,
        physicalKey: PhysicalKeyboardKey.digit1,
        platform: 'macos',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(ids(), ['p1']);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad0);
      await tester.pumpAndSettle();
      expect(ids(), isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(ids(), ['p1']);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pumpAndSettle();
      expect(find.text('候选 00:45'), findsOneWidget);
      expect(notifier.current.candidates[3]['tier'], 'suspect');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'judged suspects stay at position until filter changes, no forced next',
    (tester) async {
      final notifier = FakeProject();
      await pump(tester, notifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsOneWidget);
      expect(find.text('候选 00:36'), findsOneWidget);
      expect(find.textContaining('判进 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('review-status-excluded')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-status-suspect')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'export default, zero-tag disabled, excluded plus 囧, round trip counts update',
    (tester) async {
      final notifier = FakeProject();
      final app = await pump(tester, notifier, path: '/export');
      expect(find.text('将导出 3 段 · 00:27'), findsOneWidget);
      final zero = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, '空标签'),
      );
      expect(zero.onSelected, isNull);
      await tester.tap(find.byKey(const Key('export-tier-must')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-tier-excluded')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '囧'));
      await tester.pumpAndSettle();
      expect(find.text('将导出 2 段 · 00:18'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-review-selection')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-review-banner')), findsOneWidget);
      expect(find.textContaining('（2 段）'), findsOneWidget);
      expect(find.byKey(const ValueKey('candidate-row-c6')), findsOneWidget);
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('candidate-row-c6')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('回到导出 →'));
      await tester.pumpAndSettle();
      expect(find.text('将导出 1 段 · 00:09'), findsOneWidget);
      expect(app.container.read(exportSelectionProvider).tags, {'p3'});
      expect(app.container.read(exportSelectionProvider).tiers, {'excluded'});
      notifier.switchProject();
      await tester.pumpAndSettle();
      expect(app.container.read(exportSelectionProvider).tiers, {'must'});
      expect(app.container.read(exportSelectionProvider).tags, isNull);
      expect(app.container.read(exportReviewProvider), isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'multi-tier export to review shares exact OR selection including empty',
    (tester) async {
      final app = await pump(tester, FakeProject(), path: '/export');
      await tester.tap(find.byKey(const Key('export-tier-suspect')));
      await tester.pumpAndSettle();
      expect(find.text('将导出 6 段 · 00:54'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-review-selection')));
      await tester.pumpAndSettle();
      expect(find.text('显示 6 / 9'), findsOneWidget);
      app.router.go('/export');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-tier-must')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-tier-suspect')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-review-selection')));
      await tester.pumpAndSettle();
      expect(find.text('显示 0 / 9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cached review re-applies unchanged export condition on each visit',
    (tester) async {
      final app = await pump(tester, FakeProject(), path: '/export');
      await tester.tap(find.byKey(const Key('export-review-selection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-status-suspect')));
      await tester.pumpAndSettle();
      app.router.go('/export');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-review-selection')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-row-c0')), findsOneWidget);
      expect(find.byKey(const ValueKey('candidate-row-c3')), findsNothing);
    },
  );
  testWidgets(
    'all 19 tag keys and numpad digits toggle without stealing existing actions',
    (tester) async {
      final notifier = FakeProject();
      notifier.initial = fixture().copyWith(
        players: [
          for (var i = 1; i <= 19; i++) {'id': 'p$i', 'name': '标签$i'},
        ],
      );
      await pump(tester, notifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pumpAndSettle();
      for (var i = 1; i < reviewPlayerKeys.length; i++) {
        for (final key in {reviewPlayerKeys[i].$1, reviewPlayerKeys[i].$2}) {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
          expect(candidateTagIds(notifier.current.candidates[3]), [
            'p$i',
          ], reason: key.debugName);
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
          expect(candidateTagIds(notifier.current.candidates[3]), isEmpty);
        }
      }
    },
  );
  testWidgets('v3 four screen evidence', (tester) async {
    final app = await pump(tester, FakeProject());
    await screenshot(tester, '1-review');
    app.router.go('/export');
    await tester.pumpAndSettle();
    await screenshot(tester, '2-export-default');
    await tester.tap(find.byKey(const Key('export-tier-must')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-tier-excluded')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '囧'));
    await tester.pumpAndSettle();
    await screenshot(tester, '3-export-bloopers');
    await tester.tap(find.byKey(const Key('export-review-selection')));
    await tester.pumpAndSettle();
    await screenshot(tester, '4-review-from-export');
    expect(tester.takeException(), isNull);
  });
}
