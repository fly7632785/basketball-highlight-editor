import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      expect(find.text('分析进行中'), findsOneWidget);
    },
  );

  testWidgets('shows recovery action for an interrupted analysis', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {
          'state': 'running',
          'stage': 'prepare_proxy',
          'progress': 0,
          'runtime_state': 'stale',
          'recovery_state': 'stale_recoverable',
          'recoverable': true,
        },
      ),
    );

    expect(find.text('正在分析视频'), findsNothing);
    expect(find.text('上次分析没有完成'), findsOneWidget);
    expect(find.text('重试分析'), findsOneWidget);
  });

  testWidgets('uses a scrollable workbench on a narrow window', (tester) async {
    tester.view.physicalSize = const Size(612, 927);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'running', 'stage': 'prepare_proxy', 'progress': 0},
      ),
      size: const Size(612, 927),
    );

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no candidates state guides the user to import a video', (
    tester,
  ) async {
    await _pumpReview(tester, const ProjectState());

    expect(find.text('还没有分析结果'), findsOneWidget);
    expect(find.text('去导入视频'), findsOneWidget);
  });

  testWidgets('plays the selected candidate range and shows event time', (
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
            'selection_status': 'included',
            'confidence': 'high',
          },
        ],
      ),
    );

    expect(find.text('候选 00:12 · 片段 00:06 - 00:15'), findsOneWidget);
    expect(find.text('按时间'), findsNothing);
    expect(find.text('默认保留'), findsNothing);
    expect(find.text('保留'), findsNothing);
    expect(find.text('已排除'), findsNothing);
    expect(find.textContaining('时长 9 秒'), findsOneWidget);
    expect(find.byTooltip('保留片段'), findsOneWidget);
    expect(find.byTooltip('排除片段'), findsOneWidget);
  });

  testWidgets('sorts the review list by event time', (tester) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'late',
            'event_time_ms': 12000,
            'default_start_ms': 6000,
            'default_end_ms': 15000,
            'review_status': 'pending',
          },
          {
            'id': 'early',
            'event_time_ms': 3000,
            'default_start_ms': 0,
            'default_end_ms': 6000,
            'review_status': 'pending',
          },
        ],
      ),
    );

    final first = find.text('1. 00:03');
    final second = find.text('2. 00:12');
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
  });
}

Future<void> _pumpReview(
  WidgetTester tester,
  ProjectState state, {
  Size size = const Size(1200, 800),
}) async {
  tester.view.physicalSize = size;
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
