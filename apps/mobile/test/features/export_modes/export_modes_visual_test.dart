import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:bhe_mobile/features/export/export_modes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['BHE_EXPORT_MODES_FONT'];
    if (font != null) {
      final loader = FontLoader('Inter')
        ..addFont(
          Future.value(ByteData.sublistView(await File(font).readAsBytes())),
        );
      await loader.load();
      final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
        ..addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        );
      await icons.load();
      final material = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await material.load();
    }
  });
  for (final landscape in [false, true]) {
    testWidgets('output modes at 1.3x $landscape', (tester) async {
      final fixture = MobileVideoFixture();
      await tester.runAsync(fixture.init);
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.binding.setSurfaceSize(
        landscape ? const Size(800, 360) : const Size(360, 800),
      );
      final root = GlobalKey();
      Future<void> capture(String name) async {
        final path = Platform.environment['BHE_EXPORT_MODES_CAPTURE_DIR'];
        if (path == null) return;
        await tester.pump();
        await tester.runAsync(() async {
          final boundary =
              root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final directory = Directory(path);
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
        fixture.state.project = fixture
            .project(file!.path)
            .copyWith(
              candidates: const [
                Candidate(
                  id: 'a',
                  startMs: 100,
                  endMs: 1000,
                  eventMs: 500,
                  player: 'Alice',
                ),
                Candidate(id: 'b', startMs: 1200, endMs: 2000, eventMs: 1500),
              ],
            );
        await tester.pumpWidget(
          RepaintBoundary(
            key: root,
            child: BheMobileApp(appState: fixture.state),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('导出').first);
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final labels = find.text('每个标签各合成一个视频');
        await tester.scrollUntilVisible(
          labels,
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pump();
        await tester.tap(labels);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('将导出 1 个视频 · 共 1 段'), findsOneWidget);
        expect(find.textContaining('Alice (1)'), findsOneWidget);
        expect(find.textContaining('没标签的 1 段不导出'), findsOneWidget);
        await tester.ensureVisible(find.text('输出方式'));
        await tester.pump();
        await capture('selector');
        await tester.ensureVisible(find.text('开始导出'));
        await tester.pump();
        await capture('summary');
        fixture.state.exportBatchTotal = 3;
        fixture.state.exportBatchFiles = const [
          LabelExportFile('Alice', '/tmp/a.mp4'),
          LabelExportFile(null, '/tmp/b.mp4'),
        ];
        fixture.state.exportedPaths = const ['/tmp/a.mp4', '/tmp/b.mp4'];
        fixture.state.notifyListeners();
        await tester.pump();
        await tester.scrollUntilVisible(
          find.text('分享全部'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pump();
        expect(find.text('已完成 2/3 个标签'), findsOneWidget);
        expect(find.text('部分完成'), findsOneWidget);
        expect(find.text('保存全部到相册'), findsOneWidget);
        await capture('partial');
        await tester.ensureVisible(find.text('部分完成'));
        await tester.pump();
        await capture('partial_details');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.binding.platformDispatcher.clearLocaleTestValue();
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(fixture.close);
      }
    });
  }
}
