import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/review/review_screen.dart';

void main() {
  testWidgets(
    'shows analysis progress instead of an unexplained waiting state',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReviewScreen(
              videoPath: null,
              job: const {
                'state': 'running',
                'stage': 'coarse_scan',
                'progress': 0.35,
              },
              candidates: const [],
              busy: false,
              onCancelAnalysis: () async {},
              onRetryAnalysis: () async {},
              onExport: () {},
              onReviewCandidate: (_, _) async {},
              onUpdateClipRange: (_, _, _) async {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('正在分析视频'), findsOneWidget);
      expect(find.text('快速扫描候选 · 35%'), findsOneWidget);
      expect(find.textContaining('分析进行中'), findsOneWidget);
    },
  );
}
