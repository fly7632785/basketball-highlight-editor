import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop/features/import_video/import_video_screen.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// L464：竖拍视频两处显示适配。
/// 1) 检测框页（_RoiCanvas）：竖拍画布限高、按高度等比缩小，不再超出可视区；
///    横拍表现与尺寸上限不变。2) 审核页 contain 见 review_video_viewport_test.dart。
void main() {
  setUpAll(() async {
    final fontPath = Platform.environment['BHE_L464_SCREENSHOT_FONT'];
    if (fontPath != null) {
      final data = await File(fontPath).readAsBytes();
      final inter = FontLoader('Inter')
        ..addFont(Future.value(ByteData.sublistView(data)));
      await inter.load();
    }
    final lucide = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(
        rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
      );
    await lucide.load();
    final material = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await material.load();
  });

  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
    }),
  );

  for (final testCase in [
    (frame: const Size(1080, 1920), rotation: 0),
    (frame: const Size(1920, 1080), rotation: 0),
    // inspect_video 已把带 90° 旋转的编码尺寸换成显示尺寸。
    (frame: const Size(1920, 1080), rotation: 90),
  ]) {
    testWidgets('roi canvas fits viewport for $testCase', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: ProviderScope(
            overrides: [
              projectProvider.overrideWith(
                () => _RoiFrameNotifier(testCase.frame, testCase.rotation),
              ),
            ],
            child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      final canvas = find.byKey(const Key('roi-canvas-frame'));
      expect(canvas, findsOneWidget);
      final rect = tester.getRect(canvas);
      // 等比：画布比例等于源显示比例。
      expect(
        rect.width / rect.height,
        closeTo(testCase.frame.aspectRatio, 0.001),
      );
      // 画布自身限高：竖拍不再又长又大。
      expect(rect.height, lessThanOrEqualTo(620));
      expect(rect.width, lessThanOrEqualTo(1200));
      if (testCase.frame.aspectRatio < 1) {
        expect(rect.height, closeTo(620, 0.001));
        expect(rect.width, closeTo(620 * testCase.frame.aspectRatio, 0.001));
      } else {
        // 横拍保持可用的最大画布（近满宽）。
        expect(rect.width, greaterThan(1000));
      }
      final overlay = find
          .descendant(of: canvas, matching: find.byType(Stack))
          .first;
      expect(tester.getRect(overlay), rect);
      if (testCase.frame.aspectRatio < 1 && testCase.rotation == 0) {
        final directory = Platform.environment['BHE_L464_CAPTURE_DIR'];
        if (directory != null) {
          await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            await Directory(directory).create(recursive: true);
            await File(
              '$directory/框选页-竖拍.png',
            ).writeAsBytes(data!.buffer.asUint8List());
          });
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}

class _RoiFrameNotifier extends ProjectNotifier {
  _RoiFrameNotifier(this.frame, this.rotation);
  final Size frame;
  final int rotation;

  @override
  ProjectState build() => ProjectState(
    video: {
      'id': 'v1',
      'duration_ms': 60000,
      'width': frame.width,
      'height': frame.height,
      'rotation': rotation,
    },
    workflowDraft: const {'step': 2},
  );
}
