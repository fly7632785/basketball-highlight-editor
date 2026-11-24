import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
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
  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('player management fits $width $brightness $language', (
          tester,
        ) async {
          final previous = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = FakeVideoPlatform();
          await tester.binding.setSurfaceSize(Size(width, 800));
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          try {
            final base = f.project('${f.root.path}/missing.mp4');
            f.state.project = base.copyWith(players: ['Alice', 'Bob']);
            await tester.pumpWidget(BheMobileApp(appState: f.state));
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
            await tester.tap(find.byKey(const Key('review-filter-included')));
            await tester.pump();
            await tester.tap(find.byTooltip(l10n.text('球员：Alice')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const ValueKey('player-menu-Alice')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text(l10n.text('重命名')).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.enterText(find.byType(TextField).last, '   ');
            await tester.tap(find.text(l10n.text('保存')).last);
            await tester.pump();
            expect(find.text(l10n.text('名称不能为空')), findsOneWidget);
            await tester.enterText(find.byType(TextField).last, 'Bob');
            await tester.tap(find.text(l10n.text('保存')).last);
            await tester.pump();
            expect(find.text(l10n.text('已有同名球员')), findsOneWidget);
            await tester.enterText(find.byType(TextField).last, 'Carol');
            await tester.tap(find.text(l10n.text('保存')).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await waitProjectWrites(tester, f.state.pendingProjectWrites);
            expect(f.state.project.players, ['Carol', 'Bob']);
            await tester.tap(find.byKey(const ValueKey('player-menu-Carol')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text(l10n.text('删除')).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.text(l10n.text('删除')).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await waitProjectWrites(tester, f.state.pendingProjectWrites);
            expect(f.state.project.candidates.single.player, isNull);
            await tester.tap(find.byKey(const ValueKey('player-menu-Bob')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text(l10n.text('删除')).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              tester.widget<AlertDialog>(find.byType(AlertDialog)).content,
              isNull,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() => pumpEventQueue());
            VideoPlayerPlatform.instance = previous;
            tester.binding.platformDispatcher.clearLocaleTestValue();
            tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
            await tester.binding.setSurfaceSize(null);
          }
        });
      }
    }
  }
}
