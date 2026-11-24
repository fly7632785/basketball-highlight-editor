import 'dart:async';

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
  for (final included in [true, false]) {
    for (final landscape in [false, true]) {
      for (final fail in [false, true]) {
        testWidgets(
          'filtered rapid review included=$included landscape=$landscape failure=$fail',
          (tester) async {
            final f = MobileVideoFixture();
            await tester.runAsync(() => f.init());
            final previous = VideoPlayerPlatform.instance;
            VideoPlayerPlatform.instance = FakeVideoPlatform();
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  SystemChannels.platform,
                  (_) async => null,
                );
            await tester.binding.setSurfaceSize(const Size(360, 800));
            final entered = Completer<void>();
            final release = Completer<void>();
            try {
              final video = (await tester.runAsync(
                () => f.file('original.mp4', 'original'),
              ))!;
              final initial = included
                  ? CandidateSelection.included
                  : CandidateSelection.excluded;
              final target = included
                  ? CandidateSelection.excluded
                  : CandidateSelection.included;
              f.state.project = f
                  .project(video.path)
                  .copyWith(
                    candidates: [
                      for (var i = 0; i < 3; i++)
                        Candidate(
                          id: ['one', 'two', 'three'][i],
                          startMs: i * 1000,
                          endMs: (i + 1) * 1000,
                          eventMs: i * 1000 + 500,
                          selection: initial,
                          reviewed: false,
                        ),
                    ],
                  );
              await tester.pumpWidget(BheMobileApp(appState: f.state));
              await tester.pump();
              final l10n = Localizations.of<BheLocalizations>(
                tester.element(find.byType(Scaffold).first),
                BheLocalizations,
              )!;
              final review = find.text(l10n.reviewCount(3));
              await tester.ensureVisible(review);
              await tester.pump();
              await tester.tap(review);
              await tester.pump(const Duration(milliseconds: 400));
              await tester.tap(
                find.byKey(
                  Key(
                    included
                        ? 'review-filter-uncertain'
                        : 'review-filter-excluded',
                  ),
                ),
              );
              await tester.pump(const Duration(milliseconds: 400));
              if (landscape) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 200)),
                );
                for (var i = 0; i < 10; i++) {
                  await tester.pump(const Duration(milliseconds: 100));
                }
                await tester.tap(find.byTooltip(l10n.text('横屏全屏')));
                await tester.binding.setSurfaceSize(const Size(800, 360));
                await tester.runAsync(() => pumpEventQueue());
                for (var i = 0; i < 10; i++) {
                  await tester.pump(const Duration(milliseconds: 100));
                }
                expect(find.byTooltip(l10n.text('退出横屏审核')), findsOneWidget);
              }
              var first = true;
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(
                    const MethodChannel('plugins.flutter.io/path_provider'),
                    (_) async {
                      if (first) {
                        first = false;
                        entered.complete();
                        await release.future;
                        if (fail) {
                          throw PlatformException(
                            code: 'injected_save_failure',
                          );
                        }
                      }
                      return f.root.path;
                    },
                  );
              final action = find.text(l10n.text(included ? '不选' : '恢复·算进球')).last;
              await tester.tap(action);
              await tester.pump();
              for (var i = 0; i < 100 && !entered.isCompleted; i++) {
                await tester.pump();
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)),
                );
              }
              expect(entered.isCompleted, isTrue);
              await tester.tap(action);
              await tester.pump();
              expect(release.isCompleted, isFalse);
              release.complete();
              await waitProjectWrites(tester, f.state.pendingProjectWrites);
              final items = f.state.project.candidates;
              expect(items[0].selection, fail ? initial : target);
              expect(items[0].reviewed, !fail);
              expect(items[1].selection, target);
              expect(items[1].reviewed, isTrue);
              expect(items[2].selection, initial);
              expect(items[2].reviewed, isFalse);
              await tester.runAsync(() => f.state.undoReview());
              await tester.pump();
              expect(f.state.project.candidates[1].selection, initial);
              await tester.tap(action);
              await tester.pump();
              await waitProjectWrites(tester, f.state.pendingProjectWrites);
              expect(f.state.project.candidates[1].selection, target);
              expect(f.state.project.candidates[2].selection, initial);
              expect(tester.takeException(), isNull);
            } finally {
              if (!release.isCompleted) release.complete();
              await tester.pumpWidget(const SizedBox());
              await tester.runAsync(() => pumpEventQueue());
              VideoPlayerPlatform.instance = previous;
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null);
              await tester.binding.setSurfaceSize(null);
              await tester.runAsync(() => f.close());
            }
          },
        );
      }
    }
  }
}
