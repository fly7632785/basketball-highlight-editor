import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/features/review/batch_review_helpers.dart';
import 'package:desktop/features/review/review_helpers.dart';
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

  testWidgets('does not show a stale analysis job as still running', (
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
    expect(find.textContaining('上次分析没有完成'), findsOneWidget);
    expect(find.text('重试分析'), findsOneWidget);
  });

  testWidgets('uses a scrollable workbench on a narrow window', (tester) async {
    tester.view.physicalSize = const Size(612, 927);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _ReviewNotifier(
              const ProjectState(
                job: {
                  'state': 'running',
                  'stage': 'prepare_proxy',
                  'progress': 0,
                },
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ReviewScreen())),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no candidates state guides the user to import a video', (
    tester,
  ) async {
    await _pumpReview(tester, const ProjectState());

    expect(find.text('还没有分析结果'), findsOneWidget);
    expect(find.text('去导入视频'), findsOneWidget);
    expect(find.text('调整篮筐区域'), findsNothing);
  });

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

    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('待审核').last);
    await tester.pump();

    expect(find.textContaining('候选 00:02'), findsNothing);
    expect(find.textContaining('候选 00:01'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.textContaining('候选 00:03'), findsOneWidget);
  });

  test('filters and sorts candidates by review signals', () {
    final entries = reviewQueueEntries(
      [
        {
          'id': 'normal',
          'event_time_ms': 3000,
          'review_status': 'pending',
          'confidence': 'high',
          'evidence_json': '{}',
        },
        {
          'id': 'conflict',
          'event_time_ms': 1000,
          'review_status': 'pending',
          'confidence': 'high',
          'evidence_json': '{"evidence_conflict": true}',
        },
        {
          'id': 'low',
          'event_time_ms': 2000,
          'review_status': 'pending',
          'confidence': 'low',
          'evidence_json': '{}',
        },
      ],
      filter: 'all',
      sort: 'conflict',
    );

    expect(entries.map((entry) => entry.value['id']), [
      'conflict',
      'low',
      'normal',
    ]);
    expect(
      reviewQueueEntries(
        entries.map((entry) => entry.value).toList(),
        filter: 'low_confidence',
        sort: 'time',
      ).single.value['id'],
      'low',
    );
  });

  test('parses evidence summaries without throwing on invalid JSON', () {
    expect(parseEvidenceJson({'evidence_json': '{bad json}'}), isEmpty);
    expect(
      evidenceSummaryLines({
        'score': 0.82,
        'confidence': 'review',
        'evidence_json':
            '{"trajectory_score": 0.7, "signals": {"net_score": 0.6, "audio_score": 0.4}, "prediction": {"landing_center": 0.55}, "review_reason_suggestion": {"primary": "rebound", "confidence": "high"}}',
      }),
      containsAll(<String>[
        '模型分数 82%',
        '轨迹 70%',
        '篮网 60%',
        '音频 40%',
        '预测落点 55%',
        '建议：篮板/反弹',
      ]),
    );
  });

  test(
    'builds review stats from candidates and keeps duration absent when backend has no field',
    () {
      final stats = buildReviewStats([
        {'review_status': 'goal'},
        {'review_status': 'excluded', 'evidence_conflict': true},
        {'review_status': 'pending'},
      ], const <String, dynamic>{});

      expect(stats.pendingCount, 1);
      expect(stats.candidateCount, 3);
      expect(stats.goalCount, 1);
      expect(stats.excludedCount, 1);
      expect(stats.conflictCount, 1);
      expect(stats.confirmationRate, 0.5);
      expect(stats.averageReviewDurationMs, isNull);
    },
  );

  test('uses an explicit backend review duration without inventing one', () {
    final stats = buildReviewStats(
      [
        {'review_status': 'goal', 'review_duration_ms': 999},
      ],
      const <String, dynamic>{'average_review_duration_ms': 12500},
    );

    expect(stats.averageReviewDurationMs, 12500);
    expect(formatReviewDuration(stats.averageReviewDurationMs), '12.5 秒');
  });

  test('uses backend counts and reason distribution when available', () {
    final stats = buildReviewStats(
      [
        {'review_status': 'pending'},
      ],
      const <String, dynamic>{
        'candidate_count': 12,
        'goal_count': 5,
        'excluded_count': 4,
        'reason_distribution': {'rebound': 3, 'pass_ball': 1},
      },
    );

    expect(stats.candidateCount, 12);
    expect(stats.goalCount, 5);
    expect(stats.excludedCount, 4);
    expect(stats.reasonDistribution, {'rebound': 3, 'pass_ball': 1});
  });

  test(
    'prefers backend confirmation rate and includes every non-pending status as fallback',
    () {
      final candidates = [
        {'review_status': 'goal'},
        {'review_status': 'excluded'},
        {'review_status': 'deferred'},
        {'review_status': 'second_review'},
        {'review_status': 'pending'},
      ];

      expect(
        buildReviewStats(
          candidates,
          const <String, dynamic>{},
        ).confirmationRate,
        0.25,
      );
      expect(
        buildReviewStats(candidates, const <String, dynamic>{
          'confirmation_rate': 0.8,
        }).confirmationRate,
        0.8,
      );
    },
  );

  test('formats review history timestamps for humans', () {
    final now = DateTime(2026, 8, 7, 12, 0);

    expect(formatReviewTimestamp('2026-08-07T11:59:30+08:00', now: now), '刚刚');
    expect(
      formatReviewTimestamp('2026-08-06T12:00:00+08:00', now: now),
      '昨天 12:00',
    );
    expect(
      formatReviewTimestamp('2025-12-01T09:05:00+08:00', now: now),
      '2025年12月1日 09:05',
    );
  });

  test('toggles candidate selection without mutating the original set', () {
    final selected = <String>{'candidate-1'};

    final added = toggleReviewSelection(selected, 'candidate-2');
    final removed = toggleReviewSelection(added, 'candidate-1');

    expect(selected, {'candidate-1'});
    expect(added, {'candidate-1', 'candidate-2'});
    expect(removed, {'candidate-2'});
  });

  test(
    'batch targets include only selected candidates in the visible result',
    () {
      final candidates = [
        {
          'id': 'visible-low',
          'event_time_ms': 3000,
          'review_status': 'pending',
          'confidence': 'low',
        },
        {
          'id': 'hidden-goal',
          'event_time_ms': 1000,
          'review_status': 'goal',
          'confidence': 'low',
        },
        {
          'id': 'visible-high',
          'event_time_ms': 2000,
          'review_status': 'pending',
          'confidence': 'high',
        },
      ];

      expect(
        visibleSelectedCandidateIds(
          candidates,
          {'visible-high', 'hidden-goal', 'not-in-list'},
          filter: 'pending',
          sort: 'time',
        ),
        ['visible-high'],
      );
    },
  );

  testWidgets('shows batch actions for selected visible candidates', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'candidate-1',
            'event_time_ms': 1000,
            'default_start_ms': 0,
            'default_end_ms': 4000,
            'review_status': 'pending',
          },
          {
            'id': 'candidate-2',
            'event_time_ms': 2000,
            'default_start_ms': 1000,
            'default_end_ms': 5000,
            'review_status': 'excluded',
          },
        ],
      ),
    );

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(find.text('1 项已选'), findsOneWidget);
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    expect(find.text('批量确认进球'), findsOneWidget);
    expect(find.text('批量排除'), findsOneWidget);
    expect(find.text('批量暂缓'), findsOneWidget);
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
