import 'package:desktop/components/onboarding_guide.dart';
import 'package:desktop/core/video_orientation.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/project_state.dart'
    show recentProjectRootsPrefsKey;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(onboardingProvider);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return container;
}

Future<List<String>?> _saved() async =>
    (await SharedPreferences.getInstance()).getStringList(
      onboardingStepsPrefsKey,
    );

void main() {
  group('看过状态', () {
    test('新用户：什么都没看过，按步骤分别记录', () async {
      final container = await _container({});
      final notifier = container.read(onboardingProvider.notifier);
      expect(container.read(onboardingProvider).loaded, isTrue);
      expect(container.read(onboardingProvider).seen, isEmpty);

      await notifier.markSeen(['review.video', 'review.queue']);

      final state = container.read(onboardingProvider);
      expect(state.seen, {'review.video', 'review.queue'});
      expect(state.seen.contains('review.range'), isFalse);
      expect(state.seen.contains('export.mode'), isFalse);
      expect(await _saved(), containsAll(['review.video', 'review.queue']));
    });

    test('升级用户（已有最近项目）所有步骤视为看过，不弹', () async {
      final container = await _container({
        recentProjectRootsPrefsKey: ['/tmp/p'],
      });
      expect(
        container.read(onboardingProvider).seen,
        allOnboardingStepIds.toSet(),
      );
    });

    test('旧版按页面记录的用户：只算旧步骤看过，升级后新增的步骤仍会弹', () async {
      final container = await _container({
        onboardingLegacySeenPrefsKey: ['review', 'export'],
        recentProjectRootsPrefsKey: ['/tmp/p'],
      });
      final seen = container.read(onboardingProvider).seen;
      expect(seen, containsAll(['review.video', 'review.queue', 'export.mode']));
      expect(seen.contains('review.shortcuts'), isFalse);
      expect(seen.contains('review.tag'), isFalse);
      expect(seen.contains('review.range'), isFalse);
      expect(seen.contains('export.tag'), isFalse);
    });

    test('每个页面的步骤都登记过，且 id 不重复', () {
      expect(allOnboardingStepIds.toSet().length, allOnboardingStepIds.length);
      for (final entry in onboardingStepIds.entries) {
        for (final id in entry.value) {
          expect(id.startsWith('${entry.key}.'), isTrue, reason: id);
        }
      }
    });

    test('重置有效：清空记录，重启后也不会被当成升级用户', () async {
      final container = await _container({
        recentProjectRootsPrefsKey: ['/tmp/p'],
      });
      await container.read(onboardingProvider.notifier).reset();
      expect(container.read(onboardingProvider).seen, isEmpty);
      expect(await _saved(), isEmpty);

      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      restarted.read(onboardingProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(restarted.read(onboardingProvider).seen, isEmpty);
    });

    test('重看只增加该页面的计数，不改看过记录', () async {
      final container = await _container({});
      final notifier = container.read(onboardingProvider.notifier);
      await notifier.markSeen(['export.mode']);
      notifier.replay(onboardingExportPage);
      final state = container.read(onboardingProvider);
      expect(state.replay[onboardingExportPage], 1);
      expect(state.replay[onboardingReviewPage], isNull);
      expect(state.seen, {'export.mode'});
    });
  });

  group('引导遮罩', () {
    final targetKey = GlobalKey();
    const steps = [
      ('t.one', '第一步', '说明一'),
      ('t.two', '第二步', '说明二'),
    ];

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required Map<String, Object> prefs,
      String page = onboardingReviewPage,
      bool ready = true,
      bool hideVideo = false,
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: OnboardingGuide(
                page: page,
                ready: ready,
                hideVideo: hideVideo,
                steps: [
                  OnboardingStep(
                    id: steps[0].$1,
                    title: steps[0].$2,
                    body: steps[0].$3,
                    target: targetKey,
                  ),
                  OnboardingStep(
                    id: steps[1].$1,
                    title: steps[1].$2,
                    body: steps[1].$3,
                  ),
                ],
                child: Center(
                  child: SizedBox(key: targetKey, width: 100, height: 40),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      return container;
    }

    testWidgets('首次进入弹出，下一步走完后各步骤记为看过', (tester) async {
      final container = await pump(tester, prefs: {});
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
      expect(find.text('第一步'), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pump();
      expect(find.text('第二步'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pump();
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
      expect(container.read(onboardingProvider).seen, {'t.one', 't.two'});
    });

    testWidgets('跳过有效，并记为看过', (tester) async {
      final container = await pump(tester, prefs: {});
      await tester.tap(find.byKey(const Key('onboarding-skip')));
      await tester.pump();
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
      expect(container.read(onboardingProvider).seen, {'t.one', 't.two'});
    });

    testWidgets('全部看过的页面不再弹；点“?”（重看）从头再弹', (tester) async {
      final container = await pump(
        tester,
        prefs: {
          onboardingStepsPrefsKey: ['t.one', 't.two'],
        },
      );
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
      container.read(onboardingProvider.notifier).replay(onboardingReviewPage);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
      expect(find.text('第一步'), findsOneWidget);
    });

    testWidgets('升级后新增的步骤只弹新的，已看过的不重复', (tester) async {
      await pump(
        tester,
        prefs: {
          onboardingStepsPrefsKey: ['t.one'],
        },
      );
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
      expect(find.text('第二步'), findsOneWidget);
      expect(find.text('第一步'), findsNothing);
      expect(find.text('1/1'), findsOneWidget);
    });

    testWidgets('内容没就绪时不弹', (tester) async {
      await pump(tester, prefs: {}, ready: false);
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
    });

    testWidgets('别的页面的步骤看过，本页首次仍会弹', (tester) async {
      await pump(
        tester,
        prefs: {
          onboardingStepsPrefsKey: ['export.mode', 'export.start'],
        },
      );
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
    });

    testWidgets('引导期间视频画面换成占位，结束后恢复', (tester) async {
      await pump(tester, prefs: {}, hideVideo: true);
      expect(videoSurfaceHidden.value, isTrue);
      await tester.tap(find.byKey(const Key('onboarding-skip')));
      await tester.pump();
      expect(videoSurfaceHidden.value, isFalse);
    });
  });
}
