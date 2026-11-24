import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/features/video_source/video_source_failure.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() => fixture.close());

  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets(
          '$width $brightness $language notices scale to 1.3 without overflow',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            for (final failure in VideoSourceFailure.values) {
              fixture.state.markVideoFailure(failure);
              await tester.pumpWidget(
                MaterialApp(
                  locale: Locale(language),
                  localizationsDelegates:
                      BheLocalizations.localizationsDelegates,
                  supportedLocales: BheLocalizations.supportedLocales,
                  theme: bheTheme(brightness),
                  builder: (_, child) => MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 800),
                      textScaler: const TextScaler.linear(1.3),
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Padding(
                      padding: const EdgeInsets.all(16),
                      child: VideoSourcePanel(
                        state: fixture.state,
                        child: const SizedBox(
                          key: ValueKey('content-after-notice'),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pump();
              expect(tester.takeException(), isNull);
              final button = find.byKey(const ValueKey('video-relink'));
              expect(button, failure.canRelink ? findsOneWidget : findsNothing);
              if (failure.canRelink) {
                final size = tester.getSize(button);
                expect(size.height, greaterThanOrEqualTo(48));
                expect(size.width, greaterThanOrEqualTo(48));
                final notice = find.byKey(
                  const ValueKey('video-source-notice'),
                );
                final message = find
                    .descendant(of: notice, matching: find.byType(Text))
                    .first;
                final label = find
                    .descendant(of: button, matching: find.byType(Text))
                    .first;
                expect(
                  tester.getTopLeft(label).dx,
                  closeTo(tester.getTopLeft(message).dx, .1),
                );
                expect(
                  tester.getBottomLeft(notice).dy -
                      tester
                          .getBottomLeft(
                            find.byKey(const ValueKey('video-feedback')),
                          )
                          .dy,
                  closeTo(4, .1),
                );
                expect(
                  tester
                          .getTopLeft(
                            find.byKey(const ValueKey('content-after-notice')),
                          )
                          .dy -
                      tester.getBottomLeft(notice).dy,
                  closeTo(12, .1),
                );
              }
              if (language == 'en') {
                for (final text in tester.widgetList<Text>(find.byType(Text))) {
                  expect(
                    text.data ?? '',
                    isNot(matches(RegExp(r'[\u4e00-\u9fff]'))),
                  );
                }
              }
            }
            fixture.state.relinkingVideo = true;
            fixture.state.markVideoFailure(VideoSourceFailure.missing);
            await tester.pump();
            expect(
              tester
                  .widget<TextButton>(
                    find.byKey(const ValueKey('video-relink')),
                  )
                  .onPressed,
              isNull,
            );
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('video-relink-cancel')))
                  .height,
              greaterThanOrEqualTo(48),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'review shows missing notice and replaces its player after recovery',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final platform = FakeVideoPlatform();
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      fixture.state.project = fixture.project(
        '${fixture.root.path}/missing.mp4',
      );
      fixture.state.markVideoFailure(VideoSourceFailure.missing);
      await tester.pumpWidget(BheMobileApp(appState: fixture.state));
      await tester.pump();
      await tester.ensureVisible(find.text('审核 1'));
      await tester.pump();
      await tester.tap(find.text('审核 1'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review-filter-included')));
      await tester.pump();
      await tester.runAsync(() async {
        await pumpEventQueue();
      });
      await tester.pump();
      expect(find.byType(VideoSourcePanel), findsOneWidget);
      expect(find.text(VideoSourceFailure.missing.message), findsOneWidget);
      expect(find.text('视频不可用'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.runAsync(() async {
        fixture.choose(await fixture.file('recovered.mp4', 'original'));
        await fixture.state.relinkVideo();
      });
      await tester.pump();
      await tester.runAsync(() async {
        await pumpEventQueue();
      });
      await tester.pump();
      await tester.pumpAndSettle();
      final firstPlayer = tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller;
      expect(firstPlayer.value.isInitialized, isTrue);
      final path = fixture.state.project.video!.path;
      expect(
        platform.sources.values.any(
          (source) => source.uri == Uri.file(path).toString(),
        ),
        isTrue,
      );
      expect(find.text(VideoSourceFailure.missing.message), findsNothing);
      final beforeReload = platform.sources.length;
      fixture.state.markVideoFailure(VideoSourceFailure.mismatch);
      await tester.pump();
      await tester.runAsync(() async {
        fixture.choose(
          await fixture.file('same_path_replacement.mp4', 'original'),
        );
        await fixture.state.relinkVideo();
      });
      expect(fixture.state.project.video!.path, path);
      await tester.pump();
      await tester.runAsync(() async {
        await pumpEventQueue();
      });
      await tester.pump();
      await tester.pumpAndSettle();
      expect(platform.sources.length, greaterThan(beforeReload));
      final replacement = tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller;
      expect(replacement.value.isInitialized, isTrue);
      expect(replacement.playerId, isNot(firstPlayer.playerId));
      await tester.runAsync(() => pumpEventQueue());
      expect(platform.disposed, contains(firstPlayer.playerId));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'complete preparation status messages use English punctuation',
    () async {
      final l10n = await BheLocalizations.delegate.load(const Locale('en'));
      for (final status in ['正在读取视频信息', '正在保存视频到本机', '正在识别篮筐区域']) {
        final translated = l10n.text('$status，大文件可能需要几秒。');
        expect(translated, isNot(matches(RegExp(r'[\u4e00-\u9fff，。]'))));
        expect(translated, endsWith('Large files may take a few seconds.'));
      }
    },
  );
}
