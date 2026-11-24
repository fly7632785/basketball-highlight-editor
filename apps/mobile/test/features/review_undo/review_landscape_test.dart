import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

void main() {
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
    final video = await fixture.file('original.mp4', 'original');
    fixture.state.project = fixture.project(video.path);
  });
  tearDown(() => fixture.close());
  for (final height in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('landscape notice fits $height $brightness $language', (
          tester,
        ) async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                SystemChannels.platform,
                (call) async => null,
              );
          final previousHandler = FlutterError.onError;
          FlutterError.onError = (details) {
            debugPrint(details.toString());
            previousHandler?.call(details);
          };
          final previous = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = FakeVideoPlatform();
          await tester.binding.setSurfaceSize(const Size(360, 800));
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          try {
            await tester.pumpWidget(BheMobileApp(appState: fixture.state));
            await tester.pump();
            if (brightness == Brightness.light) {
              tester
                  .widget<PopupMenuButton<String>>(
                    find.byType(PopupMenuButton<String>),
                  )
                  .onSelected!('theme');
              await tester.pump();
            }
            final context = tester.element(find.byType(Scaffold).first);
            final l10n = Localizations.of<BheLocalizations>(
              context,
              BheLocalizations,
            )!;
            final review = find.text(l10n.reviewCount(1));
            await tester.ensureVisible(review);
            await tester.pump();
            await tester.tap(review);
            await tester.pump();
            await tester.tap(find.byKey(const Key('review-filter-all')));
            await tester.pump();
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            });
            await tester.pump();
            for (var i = 0; i < 10; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            await tester.tap(find.byTooltip(l10n.text('横屏全屏')));
            await tester.binding.setSurfaceSize(Size(800, height));
            await tester.runAsync(() => pumpEventQueue());
            await tester.pump();
            for (var i = 0; i < 10; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(find.byTooltip(l10n.text('退出横屏审核')), findsOneWidget);
            await tester.pump(const Duration(milliseconds: 400));
            final keep = find.text(l10n.text('选中')).last;
            final before = tester.getRect(keep);
            await tester.runAsync(
              () => fixture.state.toggleCandidate(
                'goal',
                CandidateSelection.excluded,
              ),
            );
            await tester.pump();
            expect(tester.getRect(keep), before);
            expect(find.byKey(const ValueKey('review-undo-bottom')), findsOneWidget);
            expect(find.byKey(const ValueKey('review-undo-top')), findsNothing);
            expect(find.byType(SnackBar), findsNothing);
            final error = tester.takeException();
            if (error != null) debugPrint(error.toString());
            expect(error, isNull);
            await tester.tap(find.byKey(const ValueKey('review-undo-bottom')));
            await tester.pump();
            await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
            await tester.pump();
            expect(
              fixture.state.project.candidates.single.selection,
              CandidateSelection.included,
            );
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() => pumpEventQueue());
            VideoPlayerPlatform.instance = previous;
            FlutterError.onError = previousHandler;
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null);
            tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
            tester.binding.platformDispatcher.clearLocaleTestValue();
            await tester.binding.setSurfaceSize(null);
          }
        });
      }
    }
  }
}
