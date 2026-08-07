import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/providers/project_state.dart';

void main() {
  testWidgets(
    'shows analysis progress instead of an unexplained waiting state',
    (tester) async {
      await _pumpReview(
        tester,
        const ProjectState(
          job: {'state': 'running', 'stage': 'coarse_scan', 'progress': 0.35},
        ),
      );

      expect(find.text('正在分析视频'), findsOneWidget);
      expect(find.text('快速扫描候选 · 35%'), findsOneWidget);
      expect(find.textContaining('分析进行中'), findsOneWidget);
    },
  );

  testWidgets('shows event time separately from the export clip range', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'candidate-1',
            'event_time_ms': 12000,
            'default_start_ms': 6000,
            'default_end_ms': 15000,
            'review_start_ms': 6000,
            'review_end_ms': 15000,
            'review_status': 'pending',
          },
        ],
      ),
    );

    expect(find.text('候选 00:12 · 片段 00:06 - 00:15'), findsOneWidget);
  });

  testWidgets('filtered candidate navigation skips hidden candidates', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'pending-1',
            'event_time_ms': 1000,
            'default_start_ms': 0,
            'default_end_ms': 4000,
            'review_status': 'pending',
          },
          {
            'id': 'excluded-1',
            'event_time_ms': 2000,
            'default_start_ms': 1000,
            'default_end_ms': 5000,
            'review_status': 'excluded',
          },
          {
            'id': 'pending-2',
            'event_time_ms': 3000,
            'default_start_ms': 2000,
            'default_end_ms': 6000,
            'review_status': 'pending',
          },
        ],
      ),
    );

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待审核').last);
    await tester.pump();

    expect(find.textContaining('候选 00:02'), findsNothing);
    expect(find.textContaining('候选 00:01'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.textContaining('候选 00:03'), findsOneWidget);
  });
}

Future<void> _pumpReview(WidgetTester tester, ProjectState state) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [projectProvider.overrideWith(() => _ReviewNotifier(state))],
      child: const MaterialApp(home: Scaffold(body: ReviewScreen())),
    ),
  );
  await tester.pump();
}

class _ReviewNotifier extends ProjectNotifier {
  _ReviewNotifier(this.initialState);

  final ProjectState initialState;

  @override
  ProjectState build() => initialState;
}
