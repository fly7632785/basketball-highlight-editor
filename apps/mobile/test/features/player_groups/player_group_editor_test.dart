import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
  });
  tearDown(() => f.close());

  Future<void> openEditor(WidgetTester tester, Brightness brightness) async {
    f.state.project = f.project('${f.root.path}/missing.mp4');
    expect(
      await tester.runAsync(() => f.state.savePlayerGroup('Team')),
      isTrue,
    );
    await tester.pumpWidget(BheMobileApp(appState: f.state));
    await tester.pump();
    if (brightness == Brightness.light) {
      tester
          .widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>))
          .onSelected!('theme');
      await tester.pump();
    }
    final l10n = Localizations.of<BheLocalizations>(
      tester.element(find.byType(Scaffold).first),
      BheLocalizations,
    )!;
    await tester.ensureVisible(find.text(l10n.reviewCount(1)));
    await tester.pump();
    await tester.tap(find.text(l10n.reviewCount(1)));
    await tester.pump();
    await tester.tap(find.byKey(const Key('review-filter-included')));
    await tester.pump();
    await tester.tap(find.byTooltip(l10n.text('球员：Alice')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(l10n.text('球员分组')).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    tester
        .widget<PopupMenuButton<String>>(
          find.byKey(const ValueKey('player-group-menu-Team')),
        )
        .onSelected!('edit');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('editor fits $width $brightness $language', (tester) async {
          final previous = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = FakeVideoPlatform();
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          await tester.binding.setSurfaceSize(Size(width, 800));
          try {
            await openEditor(tester, brightness);
            expect(
              find.byKey(const ValueKey('group-editor-name')),
              findsOneWidget,
            );
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('group-editor-handle-0')))
                  .shortestSide,
              greaterThanOrEqualTo(48),
            );
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('group-editor-save')))
                  .height,
              greaterThanOrEqualTo(48),
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
  testWidgets(
    'editor saves ordered copy, cancel and stale edit do not overwrite',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      await tester.binding.setSurfaceSize(const Size(360, 800));
      try {
        await openEditor(tester, Brightness.dark);
        await tester.enterText(
          find.byKey(const ValueKey('group-editor-new-player')),
          'Carol',
        );
        await tester.tap(find.byKey(const ValueKey('group-editor-add')));
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('group-editor-handle-1'))),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -150));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('group-editor-row-1')))
              .dy,
          lessThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('group-editor-row-0')))
                .dy,
          ),
        );
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('group-editor-menu-1')),
            )
            .onSelected!('down');
        await tester.pump();
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('group-editor-menu-1')),
            )
            .onSelected!('up');
        await tester.pump();
        expect(f.state.playerGroups.single.players, ['Alice']);
        await tester.tap(find.byKey(const ValueKey('group-editor-save')));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(f.state.playerGroups.single.players, ['Carol', 'Alice']);
        expect(f.state.project.players, ['Alice']);
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('player-group-menu-Team')),
            )
            .onSelected!('edit');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(
          find.byKey(const ValueKey('group-editor-new-player')),
          'Dan',
        );
        Navigator.of(
          tester.element(find.byKey(const ValueKey('group-editor-name'))),
        ).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(f.state.playerGroups.single.players, ['Carol', 'Alice']);
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('player-group-menu-Team')),
            )
            .onSelected!('edit');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          await tester.runAsync(
            () => f.state.editPlayerGroup('Team', 'Team', ['Bob']),
          ),
          isTrue,
        );
        await tester.tap(find.byKey(const ValueKey('group-editor-save')));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(find.text('分组已变更，请重新选择'), findsOneWidget);
        expect(f.state.playerGroups.single.players, ['Bob']);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
