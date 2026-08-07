import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/providers/project_state.dart';

/// 假 Notifier:返回固定 ProjectState,并记录 reviewCandidate 调用。
class _FakeProjectNotifier extends ProjectNotifier {
  _FakeProjectNotifier(this.initialState);

  final ProjectState initialState;

  final List<(String, String)> reviewed = [];

  @override
  ProjectState build() => initialState;

  @override
  Future<void> reviewCandidate(String id, String status) async {
    reviewed.add((id, status));
  }
}

ProjectState _analyzingState() => const ProjectState(
  job: {
    'state': 'running',
    'stage': 'coarse_scan',
    'progress': 0.35,
  },
  candidates: [],
);

ProjectState _twoCandidatesState() => const ProjectState(
  job: {'state': 'completed'},
  candidates: [
    {
      'id': 'candidate-1',
      'event_time_ms': 12000,
      'default_start_ms': 6000,
      'default_end_ms': 15000,
      'review_status': 'pending',
    },
    {
      'id': 'candidate-2',
      'event_time_ms': 45000,
      'default_start_ms': 39000,
      'default_end_ms': 48000,
      'review_status': 'pending',
    },
  ],
);

void main() {
  testWidgets('renders analysis status with progress when job is running', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _FakeProjectNotifier(_analyzingState()),
          ),
        ],
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('正在分析视频'), findsOneWidget);
    expect(find.textContaining('快速扫描候选'), findsOneWidget);
    expect(find.textContaining('35%'), findsOneWidget);
  });

  testWidgets('shows empty state when candidate queue is empty', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _FakeProjectNotifier(_analyzingState()),
          ),
        ],
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('没有候选片段'), findsOneWidget);
  });

  testWidgets('renders candidate list and goal button triggers reviewCandidate', (
    tester,
  ) async {
    late _FakeProjectNotifier fake;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(() {
            fake = _FakeProjectNotifier(_twoCandidatesState());
            return fake;
          }),
        ],
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);

    // 点第一个候选的「进球」按钮
    final goalButtons = find.text('进球');
    expect(goalButtons, findsNWidgets(2));
    await tester.tap(goalButtons.first);
    await tester.pump();

    expect(fake.reviewed, [
      ('candidate-1', 'goal'),
    ]);
  });
}
