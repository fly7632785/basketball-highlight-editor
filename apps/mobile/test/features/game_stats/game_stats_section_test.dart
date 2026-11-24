import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

Candidate _c(
  String id,
  int minute, {
  String? player,
  bool excluded = false,
  bool reviewed = true,
  bool rimRejected = false,
}) => Candidate(
  id: id,
  startMs: minute * 60000 + 1000,
  endMs: minute * 60000 + 5000,
  eventMs: minute * 60000 + 3000,
  player: player,
  reviewed: reviewed,
  selection: excluded
      ? CandidateSelection.excluded
      : CandidateSelection.included,
  rimCheck: rimRejected ? const {'status': 'rejected'} : null,
);

List<Candidate> _candidates() => [
  for (var i = 0; i < 6; i++) _c('a$i', i * 2, player: 'Alice'),
  for (var i = 0; i < 4; i++) _c('b$i', 3 + i * 3, player: 'Bob', reviewed: i > 0),
  _c('n0', 24),
  _c('n1', 12, reviewed: false),
  for (var i = 0; i < 6; i++)
    _c('r$i', i, excluded: true, reviewed: false, rimRejected: true),
  for (var i = 0; i < 6; i++) _c('m$i', i + 1, excluded: true),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fontPath = Platform.environment['BHE_STATS_SCREENSHOT_FONT'];
    if (fontPath == null) return;
    final data = await File(fontPath).readAsBytes();
    final inter = FontLoader('Inter')
      ..addFont(Future.value(ByteData.sublistView(data)));
    await inter.load();
    final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(
        rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
      );
    await icons.load();
    final material = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await material.load();
  });

  for (final locale in const ['zh', 'en']) {
    testWidgets('game stats card $locale', (tester) async {
      final fixture = MobileVideoFixture();
      await tester.runAsync(fixture.init);
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      tester.binding.platformDispatcher.localeTestValue = Locale(locale);
      tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.binding.setSurfaceSize(const Size(360, 800));
      final root = GlobalKey();
      Future<void> capture(String name) async {
        final dir = Platform.environment['BHE_STATS_CAPTURE_DIR'];
        if (dir == null) return;
        await tester.runAsync(() async {
          final boundary =
              root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$dir/${locale}_$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
        });
      }

      try {
        final file = await tester.runAsync(
          () => fixture.file('original.mp4', 'original'),
        );
        fixture.state.project = fixture
            .project(file!.path)
            .copyWith(candidates: _candidates(), players: const ['Alice', 'Bob']);
        await tester.pumpWidget(
          RepaintBoundary(
            key: root,
            child: BheMobileApp(appState: fixture.state),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip(locale == 'zh' ? '导出' : 'Export').first);
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final card = find.byKey(const ValueKey('game-stats-card'));
        await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).last);
        expect(card, findsOneWidget);
        expect(
          find.descendant(
            of: card,
            matching: find.text(
              locale == 'zh'
                  ? '保留 12 个 · 命中率估算 50%'
                  : '12 kept · est. hit rate 50%',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('game-stats-rate')), findsNothing);
        await capture('collapsed');

        await tester.tap(find.byKey(const ValueKey('game-stats-toggle')));
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('game-stats-rate'))).data,
          '50%',
        );
        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text(locale == 'zh' ? '未标记' : 'Untagged'), findsOneWidget);
        expect(
          find.text(
            locale == 'zh'
                ? '手动 6 · 复核 6'
                : 'Manual 6 · Rim 6',
          ),
          findsOneWidget,
        );
        expect(
          find.text(locale == 'zh' ? '0–10 分钟' : '0–10 min'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.binding.setSurfaceSize(const Size(360, 1500));
        await tester.pump();
        await capture('expanded');
        await tester.binding.setSurfaceSize(const Size(360, 800));
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('game-stats-toggle')));
        await tester.pump();
        expect(find.byKey(const ValueKey('game-stats-rate')), findsNothing);
      } finally {
        VideoPlayerPlatform.instance = previous;
        await tester.binding.setSurfaceSize(null);
        tester.binding.platformDispatcher.clearLocaleTestValue();
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.runAsync(() => fixture.close());
      }
    });
  }
}
