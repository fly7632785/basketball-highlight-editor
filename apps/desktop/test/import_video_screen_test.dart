import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/import_video/import_video_screen.dart';

void main() {
  test(
    'estimates standard analysis from the selected range and resolution',
    () {
      final estimate = estimateAnalysisDuration(
        startMs: 0,
        endMs: const Duration(minutes: 30).inMilliseconds,
        width: 1920,
        height: 1080,
        mode: 'standard',
      );

      expect(estimate.label, '约 4–9 分钟');
    },
  );

  test('estimates fast analysis shorter than standard analysis', () {
    const args = <String, int>{
      'startMs': 0,
      'endMs': 1800000,
      'width': 1920,
      'height': 1080,
    };
    final standard = estimateAnalysisDuration(
      startMs: args['startMs']!,
      endMs: args['endMs']!,
      width: args['width']!,
      height: args['height']!,
      mode: 'standard',
    );
    final fast = estimateAnalysisDuration(
      startMs: args['startMs']!,
      endMs: args['endMs']!,
      width: args['width']!,
      height: args['height']!,
      mode: 'fast',
    );

    expect(fast.minimum.inSeconds, lessThan(standard.minimum.inSeconds));
    expect(fast.maximum.inSeconds, lessThan(standard.maximum.inSeconds));
  });

  test('collapses a short estimate with identical rounded bounds', () {
    final estimate = estimateAnalysisDuration(
      startMs: 0,
      endMs: 277000,
      width: 1440,
      height: 1080,
      mode: 'fast',
    );

    expect(estimate.label, '约 1 分钟');
  });
}
