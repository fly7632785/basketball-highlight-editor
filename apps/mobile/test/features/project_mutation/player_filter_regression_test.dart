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
  testWidgets(
    'deleting the last filtered player resets the filter and keeps review available',
    (tester) async {
      final before = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
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
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.byKey(const Key('review-player-filter')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(
          find.byKey(const Key('review-player-option-player:Alice')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('review-apply-filters')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byKey(const Key('review-filters-active')), findsOneWidget);
        await tester.tap(find.byTooltip(l10n.text('球员：Alice')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.byKey(const ValueKey('player-menu-Alice')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(l10n.text('删除')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(l10n.text('删除')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await waitProjectWrites(tester, f.state.pendingProjectWrites);
        Navigator.of(tester.element(find.text(l10n.text('还没有球员标签。')))).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(f.state.project.players, isEmpty);
        expect(find.byKey(const Key('review-filters-active')), findsNothing);
        expect(find.byTooltip(l10n.text('球员标签')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = before;
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
  testWidgets(
    'renaming the filtered player keeps the filter and candidate visible',
    (tester) async {
      final before = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
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
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.byKey(const Key('review-player-filter')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(
          find.byKey(const Key('review-player-option-player:Alice')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('review-apply-filters')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byKey(const Key('review-filters-active')), findsOneWidget);
        await tester.runAsync(() => f.state.renamePlayer('Alice', 'Carol'));
        await tester.pump();
        expect(find.text('Carol'), findsWidgets);
        expect(find.byTooltip(l10n.text('球员：Carol')), findsOneWidget);
        expect(find.byKey(const Key('review-filters-active')), findsOneWidget);
        await tester.tap(find.byKey(const Key('review-player-filter')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清除'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('review-filters-active')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = before;
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('failed player rename leaves the active player filter intact', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    await tester.binding.setSurfaceSize(const Size(360, 800));
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    try {
      f.state.project = f.project('${f.root.path}/missing.mp4');
      await tester.pumpWidget(BheMobileApp(appState: f.state));
      await tester.pump();
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
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const Key('review-player-filter')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(
        find.byKey(const Key('review-player-option-player:Alice')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('review-apply-filters')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => throw PlatformException(code: 'rename_failed'),
          );
      expect(
        await tester.runAsync(() => f.state.renamePlayer('Alice', 'Bob')),
        isFalse,
      );
      await tester.pump();
      expect(f.state.project.players, ['Alice']);
      expect(find.byKey(const Key('review-filters-active')), findsOneWidget);
      expect(find.byTooltip(l10n.text('球员：Alice')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
      VideoPlayerPlatform.instance = previous;
      tester.binding.platformDispatcher.clearLocaleTestValue();
      await tester.binding.setSurfaceSize(null);
    }
  });
}
