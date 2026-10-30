import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/features/review/shooter_quick_label.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ModuleEngine implements EngineTransport {
  final roots = <String>[];

  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    roots.add(payload['project_root'] as String);
    if (command == 'list_shooter_review') {
      return {
        'players': <JsonMap>[],
        'videos': [
          {'id': 'v'},
        ],
        'jobs': <JsonMap>[],
        'candidates': [
          {
            'id': 'c0',
            'video_id': 'v',
            'event_time_ms': 2000,
            'shooter_review_state': 'pending',
            'shooter_evidence': {
              'method': 'ball_release_preview_v1',
              'generation': 'g',
              'release_time_ms': 1000,
              'frames': [
                for (final t in [800, 1000, 1200])
                  {'time_ms': t, 'context_path': null, 'people': <JsonMap>[]},
              ],
            },
          },
        ],
      };
    }
    throw StateError('Unexpected request: $command');
  }
}

class _ModuleNotifier extends ProjectNotifier {
  int refreshes = 0;
  @override
  ProjectState build() => const ProjectState();
  @override
  Future<void> flushReviewQueue() async {}
  @override
  Future<void> refreshCandidates({
    int? generation,
    ProjectSessionScope? scope,
  }) async {
    refreshes++;
  }

  void rebuild() => state = state.copyWith();
}

void main() {
  testWidgets(
    'review defaults to basket tab and switches inline with scoped requests',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = _ModuleEngine();
      final session = ProjectSession(EngineSession(engine))
        ..restore(
          const ProjectSessionCheckpoint(
            projectRoot: '/qa-project',
            projectId: 'p',
            videoId: 'v',
          ),
        );
      final notifier = _ModuleNotifier();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            projectSessionProvider.overrideWithValue(session),
            projectProvider.overrideWith(() => notifier),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: BheLocalizations.localizationsDelegates,
            supportedLocales: BheLocalizations.supportedLocales,
            home: const Scaffold(body: ReviewScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final basket = find.byKey(const Key('review-basket-tab'));
      final shooter = find.byKey(const Key('open-shooter-quick-label'));
      Color? foreground(Finder f) =>
          tester.widget<TextButton>(f).style?.foregroundColor?.resolve({});
      expect(find.text('进球审核'), findsOneWidget);
      expect(foreground(basket), darkAppColors.orange);
      expect(foreground(shooter), darkAppColors.textSecondary);
      expect(
        tester.getTopLeft(basket).dx,
        lessThan(tester.getTopLeft(shooter).dx),
      );
      expect(engine.roots, isEmpty);
      await tester.tap(shooter);
      await tester.pumpAndSettle();
      expect(find.byType(ShooterQuickLabel), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(foreground(shooter), darkAppColors.orange);
      expect(foreground(basket), darkAppColors.textSecondary);
      expect(engine.roots, everyElement('/qa-project'));
      await tester.tap(find.widgetWithText(ChoiceChip, '待标注'));
      await tester.pumpAndSettle();
      await tester.tap(basket);
      await tester.pumpAndSettle();
      expect(notifier.refreshes, 1);
      expect(find.byType(ShooterQuickLabel), findsNothing);
      await tester.tap(shooter);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '待标注'))
            .selected,
        isTrue,
      );
      final card = find.byKey(const ValueKey('shooter-card-c0'));
      await tester.tap(find.descendant(of: card, matching: find.text('看视频')));
      await tester.pumpAndSettle();
      expect(notifier.refreshes, 2);
      expect(foreground(basket), darkAppColors.orange);
      expect(find.byType(ReviewScreen), findsOneWidget);
      await tester.tap(shooter);
      await tester.pumpAndSettle();
      session.restore(
        const ProjectSessionCheckpoint(
          projectRoot: '/other-project',
          projectId: 'other',
        ),
      );
      notifier.rebuild();
      await tester.pumpAndSettle();
      expect(foreground(basket), darkAppColors.orange);
      expect(find.byType(ShooterQuickLabel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
