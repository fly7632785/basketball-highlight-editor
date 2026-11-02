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
      onboardingSeenPrefsKey,
    );

void main() {
  group('看过状态', () {
    test('新用户：各页面都没看过，按页面分别记录', () async {
      final container = await _container({});
      final notifier = container.read(onboardingProvider.notifier);
      expect(container.read(onboardingProvider).loaded, isTrue);
      expect(container.read(onboardingProvider).seen, isEmpty);

      await notifier.markSeen(onboardingReviewPage);

      final state = container.read(onboardingProvider);
      expect(state.seen, {onboardingReviewPage});
      expect(state.seen.contains(onboardingExportPage), isFalse);
      expect(await _saved(), [onboardingReviewPage]);
    });

    test('升级用户（已有最近项目）视为都看过，不弹', () async {
      final container = await _container({
        recentProjectRootsPrefsKey: ['/tmp/p'],
      });
      expect(container.read(onboardingProvider).seen, onboardingPages.toSet());
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
      await notifier.markSeen(onboardingExportPage);
      notifier.replay(onboardingExportPage);
      final state = container.read(onboardingProvider);
      expect(state.replay[onboardingExportPage], 1);
      expect(state.replay[onboardingReviewPage], isNull);
      expect(state.seen, {onboardingExportPage});
    });
  });

  group('引导遮罩', () {
    final targetKey = GlobalKey();

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
                    title: '第一步',
                    body: '说明一',
                    target: targetKey,
                  ),
                  const OnboardingStep(title: '第二步', body: '说明二'),
                ],
                child: Center(child: SizedBox(key: targetKey, width: 100, height: 40)),
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

    testWidgets('首次进入弹出，下一步走完后记为看过', (tester) async {
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
      expect(container.read(onboardingProvider).seen, {onboardingReviewPage});
    });

    testWidgets('跳过有效，并记为看过', (tester) async {
      final container = await pump(tester, prefs: {});
      await tester.tap(find.byKey(const Key('onboarding-skip')));
      await tester.pump();
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
      expect(container.read(onboardingProvider).seen, {onboardingReviewPage});
    });

    testWidgets('已看过的页面不再弹；点“?”（重看）又能弹出', (tester) async {
      final container = await pump(
        tester,
        prefs: {onboardingSeenPrefsKey: [onboardingReviewPage]},
      );
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
      container.read(onboardingProvider.notifier).replay(onboardingReviewPage);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
    });

    testWidgets('别的页面看过不影响本页；内容没就绪时不弹', (tester) async {
      await pump(
        tester,
        prefs: {onboardingSeenPrefsKey: [onboardingExportPage]},
        page: onboardingReviewPage,
        ready: false,
      );
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
    });

    testWidgets('别的页面看过时，本页首次仍会弹', (tester) async {
      await pump(
        tester,
        prefs: {onboardingSeenPrefsKey: [onboardingExportPage]},
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
