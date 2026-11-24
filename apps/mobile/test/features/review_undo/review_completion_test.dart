import 'dart:async';
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
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
  });
  tearDown(() => f.close());
  for (final scenario in [
    'single',
    'twice',
    'slow',
    'failure',
    'undo',
    'leave',
  ]) {
    testWidgets('completion prompt follows saved last review: $scenario', (
      tester,
    ) async {
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      await tester.binding.setSurfaceSize(const Size(360, 800));
      final entered = Completer<void>(), release = Completer<void>();
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        final l10n = Localizations.of<BheLocalizations>(
          tester.element(find.byType(Scaffold).first),
          BheLocalizations,
        )!;
        final review = find.text(l10n.reviewCount(1));
        await tester.ensureVisible(review);
        await tester.pump();
        await tester.tap(review);
        await tester.pump();
        await tester.tap(find.byKey(const Key('review-filter-all')));
        await tester.pump();
        if (scenario == 'slow' || scenario == 'failure') {
          var first = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (_) async {
                  if (first) {
                    first = false;
                    entered.complete();
                    if (scenario == 'slow') await release.future;
                    if (scenario == 'failure') {
                      throw PlatformException(code: 'review_failed');
                    }
                  }
                  return f.root.path;
                },
              );
        }
        await tester.tap(find.text(l10n.text('不选')).last);
        await tester.pump();
        if (scenario == 'twice') {
          await tester.tap(find.text(l10n.text('选中')).last);
          await tester.pump();
        }
        if (scenario == 'slow') {
          for (var i = 0; i < 100 && !entered.isCompleted; i++) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(entered.isCompleted, isTrue);
          await tester.pump(const Duration(seconds: 6));
          expect(find.byType(AlertDialog), findsNothing);
          release.complete();
        }
        await waitProjectWrites(tester, f.state.pendingProjectWrites);
        await tester.pump();
        if (scenario == 'failure') {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byKey(const ValueKey('review-feedback-action')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('review-feedback-action')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.byKey(const ValueKey('diagnostics-sheet')),
            findsOneWidget,
          );
          expect(
            tester.widget<SelectableText>(find.byType(SelectableText)).data,
            contains('review_failed'),
          );
          Navigator.of(
            tester.element(find.byKey(const ValueKey('diagnostics-sheet'))),
          ).pop();
          await tester.pump(const Duration(milliseconds: 400));
        }
        if (scenario == 'leave') {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 6));
          expect(tester.takeException(), isNull);
          return;
        }
        if (scenario == 'undo') {
          final undo = find.byKey(const ValueKey('review-undo-bottom'));
          expect(tester.widget<IconButton>(undo).onPressed, isNotNull);
          await tester.tap(undo);
          await tester.pump();
          await waitProjectWrites(tester, f.state.pendingProjectWrites);
        }
        await tester.pump(const Duration(seconds: 6));
        await tester.pump();
        expect(
          find.byType(AlertDialog),
          scenario == 'failure' || scenario == 'undo'
              ? findsNothing
              : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    });
  }
}
