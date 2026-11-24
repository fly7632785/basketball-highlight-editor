import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['BHE_PROJECT_LIST_FONT'];
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
  for (final (language, landscape) in [
    ('zh', false),
    ('zh', true),
    ('en', false),
    ('en', true),
  ]) {
    testWidgets('project list $language $landscape', (tester) async {
      final english = language == 'en';
      final fixture = MobileVideoFixture();
      await tester.runAsync(fixture.init);
      tester.binding.platformDispatcher.localeTestValue = Locale(language);
      tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.binding.setSurfaceSize(
        landscape ? const Size(800, 360) : const Size(360, 800),
      );
      final root = GlobalKey();
      Future<void> capture(String name) async {
        final path = Platform.environment['BHE_PROJECT_LIST_CAPTURE_DIR'];
        if (path == null || english) return;
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
        fixture.state.project = fixture.project(file!.path);
        await tester.runAsync(() => fixture.state.renameProject('主队比赛'));
        await tester.runAsync(
          () => fixture.file(
            'BHE Mobile/projects/B.json',
            const ProjectPackageCodec().encode(
              ProjectSnapshot(id: 'B', name: '客队比赛', video: null),
            ),
          ),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: root,
            child: BheMobileApp(appState: fixture.state),
          ),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('project-name-rename')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('project-action-projects')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
          if (find.text('客队比赛').evaluate().isNotEmpty) break;
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byWidgetPredicate((widget) => widget is Text && widget.semanticsLabel == '主队比赛'), findsAtLeastNWidgets(1));
        expect(find.text('客队比赛'), findsOneWidget);
        expect(find.text(english ? 'Current' : '当前'), findsOneWidget);
        await capture('list');
        await tester.tap(
          find.byTooltip(english ? 'More actions' : '更多操作').last,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text(english ? 'Rename project' : '重命名项目'), findsOneWidget);
        expect(find.text(english ? 'Close project' : '关闭项目'), findsOneWidget);
        final deleteLabel = english ? 'Delete project' : '删除项目';
        expect(find.text(deleteLabel), findsOneWidget);
        await capture('menu');
        await tester.tap(find.text(deleteLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.text(english ? 'Delete project?' : '删除项目？'),
          findsOneWidget,
        );
        expect(find.text(deleteLabel), findsOneWidget);
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
