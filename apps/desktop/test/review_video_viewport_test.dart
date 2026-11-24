import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop/features/review/review_video_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final frame in [
    const Size(1920, 1080),
    const Size(1440, 1080),
    const Size(1080, 1920),
    Size.zero,
  ]) {
    for (final viewport in [const Size(954, 701), const Size(600, 300)]) {
      testWidgets('contains $viewport with $frame and aligned annotations', (
        tester,
      ) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: SizedBox.fromSize(
                    size: viewport,
                    child: ReviewVideoViewport(
                      frameSize: frame,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const ColoredBox(
                            key: Key('video'),
                            color: Colors.green,
                          ),
                          const SizedBox.expand(key: Key('annotations')),
                          const Align(
                            alignment: Alignment(0.5, -0.5),
                            child: SizedBox(
                              key: Key('marker'),
                              width: 2,
                              height: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        final visible = tester.getRect(find.byType(ReviewVideoViewport));
        final video = tester.getRect(find.byKey(const Key('video')));
        final annotations = tester.getRect(
          find.byKey(const Key('annotations')),
        );
        // contain：完整显示，不超出视口（宽或高其一恰好贴边）。
        expect(video.width, lessThanOrEqualTo(visible.width + 0.001));
        expect(video.height, lessThanOrEqualTo(visible.height + 0.001));
        expect(
          video.width == visible.width || video.height == visible.height,
          isTrue,
          reason: '视频框应至少贴满视口一个方向',
        );
        expect(video.center.dx, closeTo(visible.center.dx, 0.001));
        expect(video.center.dy, closeTo(visible.center.dy, 0.001));
        expect(annotations, video);
        final aspect = frame.isEmpty ? 16 / 9 : frame.aspectRatio;
        expect(video.width / video.height, closeTo(aspect, 0.0001));
        final marker = tester.getCenter(find.byKey(const Key('marker')));
        expect(
          marker.dx,
          closeTo(video.left + (video.width - 2) * .75 + 1, .001),
        );
        expect(
          marker.dy,
          closeTo(video.top + (video.height - 2) * .25 + 1, .001),
        );
        if (frame.width > 0 &&
            frame.height > 0 &&
            frame.aspectRatio < 1 &&
            viewport.width == 954) {
          final directory = Platform.environment['BHE_L464_CAPTURE_DIR'];
          if (directory != null) {
            await tester.runAsync(() async {
              final boundary =
                  boundaryKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              image.dispose();
              await Directory(directory).create(recursive: true);
              await File(
                '$directory/审核页-竖拍.png',
              ).writeAsBytes(data!.buffer.asUint8List());
            });
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
