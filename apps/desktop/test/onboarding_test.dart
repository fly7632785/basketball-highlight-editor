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
  test('视频画面占位按持有者计数，互不覆盖', () {
    final first = holdVideoSurfaceHidden();
    final second = holdVideoSurfaceHidden();
    expect(videoSurfaceHidden.value, isTrue);
    first();
    expect(videoSurfaceHidden.value, isTrue);
    first(); // 重复归还无效
    expect(videoSurfaceHidden.value, isTrue);
    second();
    expect(videoSurfaceHidden.value, isFalse);
  });

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
      expect(seen.contains('review.filter'), isFalse);
      expect(seen.contains('review.batch'), isFalse);
      expect(seen.contains('review.missed'), isFalse);
      expect(seen.contains('export.tag'), isFalse);
    });

    test('每个页面的步骤都登记过，且 id 不重复', () {
      expect(allOnboardingStepIds.toSet().length, allOnboardingStepIds.length);
      expect(onboardingStepIds.keys, [
        onboardingImportPage,
        onboardingReviewPage,
        onboardingExportPage,
      ]);
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

    testWidgets('目标比滚动区域高时，高亮框只圈住看得见的部分', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tall = GlobalKey();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: OnboardingGuide(
                page: onboardingImportPage,
                steps: [
                  OnboardingStep(id: 't.tall', title: '高', body: '说明', target: tall),
                ],
                child: Column(
                  children: [
                    const SizedBox(height: 100, width: double.infinity),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SizedBox(key: tall, height: 2000, width: 700),
                      ),
                    ),
                    const SizedBox(height: 80, width: double.infinity),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      final overlay = find.byKey(const Key('onboarding-overlay'));
      expect(overlay, findsOneWidget);
      final painter = tester
          .widget<CustomPaint>(
            find.descendant(of: overlay, matching: find.byType(CustomPaint)).first,
          )
          .painter;
      final rect = (painter as dynamic).rect as Rect;
      // 滚动区域在 y=100 到 y=520 之间；框（含 6 的外扩）不能伸出去太多。
      expect(rect.top, greaterThanOrEqualTo(100 - 6 - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(520 + 6 + 0.5));
    });

    testWidgets('页面被切到后台时引导收起并交还视频画面，回来再弹', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final active = ValueNotifier(true);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (_, enabled, _) => TickerMode(
                  enabled: enabled,
                  child: OnboardingGuide(
                    page: onboardingReviewPage,
                    hideVideo: true,
                    steps: const [
                      OnboardingStep(id: 't.one', title: '第一步', body: '说明一'),
                    ],
                    child: const SizedBox(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
      expect(videoSurfaceHidden.value, isTrue);

      active.value = false;
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
      expect(videoSurfaceHidden.value, isFalse);
      expect(container.read(onboardingProvider).seen, isEmpty);

      active.value = true;
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
    });

    testWidgets('点「重置新手引导」后，已经看完的页面也能再弹', (tester) async {
      final container = await pump(tester, prefs: {});
      await tester.tap(find.byKey(const Key('onboarding-skip')));
      await tester.pump();
      expect(find.byKey(const Key('onboarding-overlay')), findsNothing);

      await container.read(onboardingProvider.notifier).reset();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
      expect(find.text('第一步'), findsOneWidget);
    });

    testWidgets('窗口很小、文字很多时气泡不超出屏幕，内容可滚动', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(380, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final longBody = List.generate(14, (i) => '第 $i 行很长很长的说明文字用来撑高气泡').join('\n');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: OnboardingGuide(
                page: onboardingReviewPage,
                steps: [OnboardingStep(id: 't.long', title: '很长', body: longBody)],
                child: const SizedBox(),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('onboarding-overlay')), findsOneWidget);
      final bubble = tester.getRect(find.byKey(const Key('onboarding-next')));
      expect(bubble.bottom, lessThanOrEqualTo(420));
      expect(bubble.right, lessThanOrEqualTo(380));
      expect(tester.takeException(), isNull);
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
