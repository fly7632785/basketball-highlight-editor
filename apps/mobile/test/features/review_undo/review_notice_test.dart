import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() => fixture.close());
  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('undo notice fits $width $brightness $language', (
          tester,
        ) async {
          final oldPlatform = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = FakeVideoPlatform();
          await tester.binding.setSurfaceSize(Size(width, 800));
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          try {
            fixture.state.project = fixture.project(
              '${fixture.root.path}/missing.mp4',
            );
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
            // The localizations live below MaterialApp.
            final review = find.text(
              language == 'en' ? 'Review 1 clips' : '审核 1 个片段',
            );
            if (review.evaluate().isEmpty) {
              final context = tester.element(find.byType(Scaffold).first);
              final text = Localizations.of<BheLocalizations>(
                context,
                BheLocalizations,
              )!.reviewCount(1);
              await tester.ensureVisible(find.text(text));
              await tester.pump();
              await tester.tap(find.text(text));
            } else {
              await tester.ensureVisible(review);
              await tester.pump();
              await tester.tap(review);
            }
            await tester.pump();
            final context = tester.element(find.byType(Scaffold).first);
            final localizations = Localizations.of<BheLocalizations>(
              context,
              BheLocalizations,
            )!;
            final keep = find.text(localizations.text('选中'));
            final before = tester.getRect(keep);
            await tester.runAsync(
              () => fixture.state.toggleCandidate(
                'goal',
                CandidateSelection.excluded,
              ),
            );
            await tester.pump();
            expect(
              find.byKey(const ValueKey('review-undo-action')),
              findsNothing,
            );
            expect(find.byType(SnackBar), findsNothing);
            expect(tester.takeException(), isNull);
            expect(tester.getRect(keep), before);
            final undo = find.byKey(const ValueKey('review-undo-top'));
            expect(tester.widget<IconButton>(undo).onPressed, isNotNull);
            await tester.tap(undo);
            await tester.pump();
            await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
            await tester.pump();
            expect(
              fixture.state.project.candidates.single.selection,
              CandidateSelection.included,
            );
            expect(find.byType(SnackBar), findsNothing);
            expect(tester.takeException(), isNull);
            expect(tester.getRect(keep), before);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() => pumpEventQueue());
            VideoPlayerPlatform.instance = oldPlatform;
            tester.binding.platformDispatcher.clearLocaleTestValue();
            tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
            await tester.binding.setSurfaceSize(null);
          }
        });
      }
    }
  }
}
