import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:bhe_mobile/features/review_undo/review_action_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

void main() {
  late MobileVideoFixture f;
  late String videoPath;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
    videoPath = (await f.file('original.mp4', 'original')).path;
  });
  tearDown(() => f.close());
  for (final included in [true, false]) {
    for (final landscape in [false, true]) {
      for (final last in [false, true]) {
        testWidgets(
          'already reviewed state included=$included landscape=$landscape last=$last',
          (tester) async {
            final previous = VideoPlayerPlatform.instance;
            VideoPlayerPlatform.instance = FakeVideoPlatform();
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  SystemChannels.platform,
                  (_) async => null,
                );
            tester.binding.platformDispatcher.localeTestValue = const Locale(
              'zh',
            );
            await tester.binding.setSurfaceSize(const Size(360, 800));
            try {
              final initial = included
                  ? CandidateSelection.included
                  : CandidateSelection.excluded;
              f.state.project = f
                  .project(videoPath)
                  .copyWith(
                    candidates: [
                      for (var i = 0; i < (last ? 1 : 2); i++)
                        Candidate(
                          id: '$i',
                          startMs: i * 1000,
                          endMs: (i + 1) * 1000,
                          eventMs: i * 1000 + 500,
                          selection: initial,
                          reviewed: true,
                        ),
                    ],
                  );
              await tester.pumpWidget(BheMobileApp(appState: f.state));
              await tester.pump();
              final l10n = Localizations.of<BheLocalizations>(
                tester.element(find.byType(Scaffold).first),
                BheLocalizations,
              )!;
              await tester.ensureVisible(
                find.text(l10n.reviewCount(last ? 1 : 2)),
              );
              await tester.pump();
              await tester.tap(find.text(l10n.reviewCount(last ? 1 : 2)));
              await tester.pump();
              await tester.tap(find.byKey(const Key('review-filter-all')));
              await tester.pump();
              if (landscape) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 200)),
                );
                await tester.pump();
                for (var i = 0; i < 10; i++) {
                  await tester.pump(const Duration(milliseconds: 100));
                }
                await tester.tap(find.byTooltip(l10n.text('横屏全屏')));
                await tester.binding.setSurfaceSize(const Size(800, 360));
                await tester.runAsync(() => pumpEventQueue());
                await tester.pump();
                for (var i = 0; i < 10; i++) {
                  await tester.pump(const Duration(milliseconds: 100));
                }
                expect(find.byTooltip(l10n.text('退出横屏审核')), findsOneWidget);
              }
              var writes = 0;
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(
                    const MethodChannel('plugins.flutter.io/path_provider'),
                    (_) async {
                      writes++;
                      return f.root.path;
                    },
                  );
              await tester.tap(
                find.text(l10n.text(included ? '选中' : '不选')).last,
              );
              await tester.pump();
              await waitProjectWrites(tester, f.state.pendingProjectWrites);
              expect(writes, 0);
              expect(f.state.canUndoReview, isFalse);
              expect(find.text(l10n.text('本次审核未保存')), findsNothing);
              if (last) {
                await tester.pump(const Duration(seconds: 6));
                await tester.pump();
                expect(find.byType(AlertDialog), findsOneWidget);
              } else {
                await tester.tap(
                  find.text(l10n.text(included ? '不选' : '选中')).last,
                );
                await tester.pump();
                await waitProjectWrites(tester, f.state.pendingProjectWrites);
                expect(f.state.project.candidates[0].selection, initial);
                expect(
                  f.state.project.candidates[1].selection,
                  included
                      ? CandidateSelection.excluded
                      : CandidateSelection.included,
                );
              }
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox());
              await tester.runAsync(() => pumpEventQueue());
              VideoPlayerPlatform.instance = previous;
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null);
              tester.binding.platformDispatcher.clearLocaleTestValue();
              await tester.binding.setSurfaceSize(null);
            }
          },
        );
      }
    }
  }
  test(
    'result distinguishes unchanged from missing, blocked and failure',
    () async {
      final fixture = MobileVideoFixture();
      await fixture.init();
      try {
        fixture.state.project = fixture.project('missing');
        expect(
          await fixture.state.toggleCandidate(
            'goal',
            CandidateSelection.included,
          ),
          ReviewActionResult.unchanged,
        );
        expect(
          await fixture.state.toggleCandidate(
            'missing',
            CandidateSelection.included,
          ),
          ReviewActionResult.rejected,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => throw PlatformException(code: 'save_failed'),
            );
        expect(
          await fixture.state.toggleCandidate(
            'goal',
            CandidateSelection.excluded,
          ),
          ReviewActionResult.rejected,
        );
        expect(fixture.state.diagnosticError, isNotNull);
      } finally {
        await fixture.close();
      }
    },
  );
}
