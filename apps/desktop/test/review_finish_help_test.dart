import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/features/review/tier_selection.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/features/review/review_filter_help.dart';
import 'package:desktop/features/review/review_playback.dart';
import 'tiers_ui_test.dart' as harness;

class _MemoryPlayer extends PlatformPlayer {
  _MemoryPlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(playing: true);
  }
  final calls = <String>[];
  @override
  Future<void> pause() async {
    calls.add('pause');
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    expect(
      state.playing,
      isFalse,
      reason: 'Pause must happen before moving to the analysis result',
    );
    calls.add('seek');
    state = state.copyWith(position: position);
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
      'courtside.sidebar_extended': false,
    }),
  );
  for (final position in [const Duration(seconds: 27), null]) {
    test(
      'analysis result is paused, including empty results $position',
      () async {
        final platform = _MemoryPlayer();
        final player = Player(platformPlayer: platform);
        expect(player.state.playing, isTrue);
        await positionPausedReview(player, position);
        expect(player.state.playing, isFalse);
        expect(
          platform.calls,
          position == null ? ['pause'] : ['pause', 'seek'],
        );
        if (position != null) expect(player.state.position, position);
      },
    );
  }
  testWidgets('Goals label remains English', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: BheLocalizations.localizationsDelegates,
      supportedLocales: BheLocalizations.supportedLocales,
      home: Builder(builder: (context) => Text(context.bheText(tierLabels['must']!))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Goals'), findsOneWidget);
    expect(find.textContaining('必进'), findsNothing);
  });
  testWidgets(
    'L441 tier and tag explanations, advanced rim help, renamed export and golden',
    (tester) async {
      final notifier = harness.FakeProject();
      notifier.initial = harness.fixture().copyWith(
        candidates: [
          for (final c in harness.fixture().candidates)
            {
              ...c,
              'likely_miss': c['id'] == 'c5',
              'evidence_json':
                  '{"rim_check":{"status":"rejected","reason":"no_crossing"}}',
            },
        ],
      );
      final app = await harness.pump(
        tester,
        notifier,
        size: const Size(1428, 880),
      );
      expect(find.text('进球 3'), findsOneWidget);
      for (final message in tierHelp.values) {
        expect(find.byTooltip(message), findsOneWidget);
      }
      for (final message in tagFilterHelp.values) {
        expect(find.byTooltip(message), findsOneWidget);
      }
      expect(find.byTooltip(moreFilterHelp), findsOneWidget);
      expect(find.byTooltip(likelyMissHelp), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(
          find.byKey(const ValueKey('review-status-must')),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(tierHelp['must']!), findsOneWidget);
      await harness.screenshot(tester, 'l441-1428-goals-help');
      await mouse.removePointer();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('review-tag-more')));
      await tester.pumpAndSettle();
      for (final message in rimFilterHelp.values) {
        expect(find.byTooltip(message), findsOneWidget);
      }
      await tester.tapAt(const Offset(500, 100));
      await tester.pumpAndSettle();
      app.router.go('/export');
      await tester.pumpAndSettle();
      expect(find.text('进球 3'), findsOneWidget);
      expect(find.byTooltip(tierHelp['must']!), findsWidgets);
      expect(find.textContaining('必进'), findsNothing);
      await harness.screenshot(tester, 'l441-1428-export');
      expect(tester.takeException(), isNull);
    },
  );
}
