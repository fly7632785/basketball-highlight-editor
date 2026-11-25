import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/export_settings_actions.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['BHE_EXPORT_HISTORY_FONT'];
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
    testWidgets('history three entries and details at 1.3x $landscape', (
      tester,
    ) async {
      final f = MobileVideoFixture();
      await tester.runAsync(f.init);
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.binding.setSurfaceSize(
        landscape ? const Size(800, 360) : const Size(360, 800),
      );
      final root = GlobalKey();
      Future<void> capture(String name) async {
        final dir = Platform.environment['BHE_EXPORT_HISTORY_CAPTURE_DIR'];
        if (dir == null) return;
        await tester.pump();
        await tester.runAsync(() async {
          final boundary =
              root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory(dir).create(recursive: true);
          await File(
            '$dir/${landscape ? 'landscape' : 'portrait'}_$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }

      try {
        final source = await tester.runAsync(
          () => f.file('original.mp4', 'original'),
        );
        f.state.project = f
            .project(source!.path)
            .copyWith(
              exportHistory: [
                for (var i = 1; i <= 4; i++)
                  ExportHistoryEntry(
                    id: 'r$i',
                    createdAt: DateTime.utc(2026, 10, 28 - i),
                    mode: i == 1 ? 'labels' : 'merged',
                    plannedCount: 2,
                    durationMs: 1200,
                    files: [
                      ExportHistoryFile(
                        name: 'Alice $i',
                        relativePath: 'missing_$i.mp4',
                        savedToGallery: i == 1,
                      ),
                    ],
                  ),
              ],
            );
        await tester.pumpWidget(
          RepaintBoundary(
            key: root,
            child: BheMobileApp(appState: f.state),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('导出').first);
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await openExportControl(tester, 'export-history');
        expect(
          find.byKey(const ValueKey('export-history-page')),
          findsOneWidget,
        );
        await capture('recent');
        final first = find.byKey(const ValueKey('history-entry-r1'));
        await tester.tap(first);
        await settleExportRoute(tester);
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (find.text('已保存到相册，请在相册查看').evaluate().isNotEmpty) break;
        }
        expect(find.text('已保存到相册，请在相册查看'), findsOneWidget);
        await tester.ensureVisible(find.text('missing_1.mp4'));
        await tester.pump();
        await capture('expanded');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.binding.platformDispatcher.clearLocaleTestValue();
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(f.close);
      }
    });
  }
  testWidgets(
    'history failure shows feedback without reporting export failure',
    (tester) async {
      final f = MobileVideoFixture();
      await tester.runAsync(f.init);
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      try {
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        f.state.recordDiagnosticFailure(
          StateError('history write failure'),
          StackTrace.current,
          operation: 'export.history',
        );
        f.state.errorMessage = null;
        f.state.exportHistoryWarning = '视频已导出，历史记录保存失败。';
        f.state.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('视频已导出，历史记录保存失败。'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byType(SnackBarAction));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('diagnostics-sheet')), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.runAsync(f.close);
      }
    },
  );
}
