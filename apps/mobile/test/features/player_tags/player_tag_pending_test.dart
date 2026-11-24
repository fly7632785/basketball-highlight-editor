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

  testWidgets(
    'pending player save blocks close and apply; failed save exposes feedback and retry',
    (tester) async {
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
        await tester.ensureVisible(find.text(l10n.reviewCount(1)));
        await tester.pump();
        await tester.tap(find.text(l10n.reviewCount(1)));
        await tester.pump();
        await tester.tap(find.byKey(const Key('review-filter-included')));
        await tester.pump();
        await tester.tap(find.byTooltip(l10n.text('球员：Alice')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const ValueKey('player-menu-Alice')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text(l10n.text('重命名')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(find.byType(TextField).last, 'Bob');
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                  throw PlatformException(code: 'failed_player_save');
                }
                return f.root.path;
              },
            );
        await tester.tap(find.text(l10n.text('保存')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 100 && !entered.isCompleted; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(entered.isCompleted, isTrue);
        expect(find.byType(LinearProgressIndicator), findsWidgets);
        expect(find.text(l10n.text('应用标签')), findsNothing);
        expect(tester.widget<InkWell>(find.byKey(const ValueKey('player-select-Alice'))).onTap, isNull);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, l10n.text('球员分组')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, l10n.text('新建球员标签')),
              )
              .onPressed,
          isNull,
        );
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.byKey(const ValueKey('player-menu-Alice')), findsOneWidget);
        await tester.tapAt(const Offset(10, 10));
        await tester.pump();
        expect(find.byKey(const ValueKey('player-menu-Alice')), findsOneWidget);
        expect(f.state.project.players, ['Alice']);
        release.complete();
        await waitProjectWrites(tester, f.state.pendingProjectWrites);
        await tester.pump();
        expect(find.text(l10n.text('保存失败，请重试')), findsOneWidget);
        expect(find.text(l10n.text('反馈')), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('player-menu-Alice')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text(l10n.text('重命名')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(find.byType(TextField).last, 'Bob');
        await tester.tap(find.text(l10n.text('保存')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await waitProjectWrites(tester, f.state.pendingProjectWrites);
        expect(f.state.project.players, ['Bob']);
        expect(find.byKey(const ValueKey('player-menu-Bob')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'pending delete finishes before project switch and closes old picker',
    (tester) async {
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
        await tester.ensureVisible(find.text(l10n.reviewCount(1)));
        await tester.pump();
        await tester.tap(find.text(l10n.reviewCount(1)));
        await tester.pump();
        await tester.tap(find.byKey(const Key('review-filter-included')));
        await tester.pump();
        await tester.tap(find.byTooltip(l10n.text('球员：Alice')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const ValueKey('player-menu-Alice')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text(l10n.text('删除')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                }
                return f.root.path;
              },
            );
        await tester.tap(find.text(l10n.text('删除')).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        for (var i = 0; i < 100 && !entered.isCompleted; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(entered.isCompleted, isTrue);
        final switching = f.state.createNewProject();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('project-transition-notice')),
          findsOneWidget,
        );
        release.complete();
        await waitProjectWrites(tester, switching);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(f.state.project.id, isNot('A'));
        expect(f.state.project.players, isEmpty);
        expect(find.byKey(const ValueKey('player-menu-Alice')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
