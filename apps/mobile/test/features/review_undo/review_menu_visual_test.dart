import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fontPath = Platform.environment['BHE_UNDO_SCREENSHOT_FONT'];
    if (fontPath == null) return;
    final data = await File(fontPath).readAsBytes();
    final loader = FontLoader('Inter')
      ..addFont(Future.value(ByteData.sublistView(data)));
    await loader.load();
    final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(
        rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
      );
    await icons.load();
    final material = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await material.load();
  });
  for (final landscape in [false, true]) {
    testWidgets('review menu and failure $landscape', (tester) async {
      final fixture = MobileVideoFixture();
      await tester.runAsync(fixture.init);
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.binding.setSurfaceSize(const Size(360, 800));
      final root = GlobalKey();
      Future<void> capture(String name) async {
        final dir = Platform.environment['BHE_UNDO_CAPTURE_DIR'];
        if (dir == null) return;
        await tester.pump();
        await tester.runAsync(() async {
          final boundary =
              root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final directory = Directory(dir);
          await directory.create(recursive: true);
          await File(
            '${directory.path}/${landscape ? 'landscape' : 'portrait'}_$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
        });
      }

      try {
        final file = await tester.runAsync(
          () => fixture.file('original.mp4', 'original'),
        );
        fixture.state.project = fixture.project(file!.path);
        await tester.pumpWidget(
          RepaintBoundary(
            key: root,
            child: BheMobileApp(appState: fixture.state),
          ),
        );
        await tester.pump();
        final l10n = Localizations.of<BheLocalizations>(
          tester.element(find.byType(Scaffold).first),
          BheLocalizations,
        )!;
        await tester.ensureVisible(find.text(l10n.reviewCount(1)));
        await tester.pump();
        await tester.tap(find.text(l10n.reviewCount(1)));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (landscape) {
          await tester.tap(find.byTooltip('横屏全屏'));
          await tester.binding.setSurfaceSize(const Size(800, 360));
          await tester.runAsync(() => pumpEventQueue());
          await tester.pump();
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.byTooltip('退出横屏审核'), findsOneWidget);
        }
        final keep = find.text('选中').last;
        final initialRect = tester.getRect(keep);
        expect(find.byType(SnackBar), findsNothing);
        expect(
          find.byKey(const ValueKey('review-notice-surface')),
          findsNothing,
        );
        await capture('idle');
        final undoButton = find.byKey(const ValueKey('review-undo-bottom'));
        expect(find.byKey(const ValueKey('review-undo-top')), findsNothing);
        expect(tester.widget<IconButton>(undoButton).onPressed, isNull);
        await capture('menu_disabled');
        await tester.runAsync(
          () => fixture.state.toggleCandidate(
            'goal',
            CandidateSelection.excluded,
          ),
        );
        await tester.pump();
        expect(tester.getRect(keep), initialRect);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.widget<IconButton>(undoButton).onPressed, isNotNull);
        await capture('menu_enabled');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async =>
                  throw PlatformException(code: 'visual_write_failure'),
            );
        await tester.runAsync(
          () => fixture.state.toggleCandidate(
            'goal',
            CandidateSelection.included,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey('review-save-failure')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('review-feedback-action')),
          findsOneWidget,
        );
        expect(tester.getRect(keep), initialRect);
        expect(find.byKey(const ValueKey('video-source-notice')), findsNothing);
        await capture('failure');
        await tester.tap(find.byKey(const ValueKey('review-feedback-action')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const ValueKey('diagnostics-sheet')), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          contains('visual_write_failure'),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await pumpEventQueue();
          await fixture.close();
        });
        VideoPlayerPlatform.instance = previous;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        tester.binding.platformDispatcher.clearLocaleTestValue();
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    });
  }
}
