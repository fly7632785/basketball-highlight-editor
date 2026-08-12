import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';

import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/features/review/media_readiness.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/theme/tokens.dart';

void main() {
  test('does not autoplay the review video after opening', () {
    expect(reviewVideoAutoPlayAfterOpen, isFalse);
  });

  test('autoplays after the user switches review video source', () {
    expect(reviewVideoAutoPlayAfterSourceSwitch, isTrue);
  });

  test('waits for a positive media duration before playback', () async {
    final duration = await waitForPlayableDuration(
      current: Duration.zero,
      updates: Stream<Duration>.fromIterable(const [
        Duration.zero,
        Duration.zero,
        Duration(seconds: 9),
      ]),
    );

    expect(duration, const Duration(seconds: 9));
  });

  test('uses an already available media duration immediately', () async {
    final duration = await waitForPlayableDuration(
      current: const Duration(seconds: 9),
      updates: const Stream<Duration>.empty(),
    );

    expect(duration, const Duration(seconds: 9));
  });

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

  testWidgets('shows total duration after analysis completes', (tester) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {
          'state': 'completed',
          'started_at': '2026-08-11T10:00:00.000+00:00',
          'finished_at': '2026-08-11T10:12:30.000+00:00',
        },
      ),
    );

    expect(find.text('标准分析 · 0 个候选 · 用时 12:30'), findsOneWidget);
  });

  testWidgets('keeps review status and action areas inset from the edges', (
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
          },
        ],
      ),
    );

    final statusInset = tester.widget<Padding>(
      find.byKey(const Key('review-status-inset')),
    );
    final controlsInset = tester.widget<Padding>(
      find.byKey(const Key('review-video-controls-inset')),
    );
    final candidatePanel = tester.widget<Container>(
      find.byKey(const Key('candidate-panel-inset')),
    );
    final candidateActions = tester.widget<Padding>(
      find.byKey(const Key('candidate-actions-inset')),
    );

    expect(
      statusInset.padding,
      const EdgeInsets.symmetric(horizontal: Spacing.md),
    );
    expect(
      controlsInset.padding,
      const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
    );
    expect(
      candidatePanel.padding,
      const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.md,
        Spacing.sm,
      ),
    );
    expect(candidateActions.padding, const EdgeInsets.only(top: Spacing.xs));
  });

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

  testWidgets('shows recovery action for a queued analysis after reopening', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {
          'state': 'queued',
          'stage': 'validate_input',
          'progress': 0,
          'recovery_state': 'queued_recoverable',
          'recoverable': true,
        },
      ),
    );

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

  testWidgets('uses a flat divider on a wide review workbench', (tester) async {
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
          },
        ],
      ),
    );

    expect(find.byType(VerticalDivider), findsOneWidget);
  });

  testWidgets('narrow workbench adapts at phone and tablet widths', (
    tester,
  ) async {
    for (final size in const [Size(320, 700), Size(480, 800)]) {
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
            },
          ],
        ),
        size: size,
      );

      expect(find.byType(SingleChildScrollView), findsWidgets);
      expect(tester.takeException(), isNull);
    }
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

    expect(find.text('候选 00:12'), findsOneWidget);
    expect(find.text('按时间'), findsNothing);
    expect(find.text('默认保留'), findsNothing);
    expect(find.text('保留'), findsNothing);
    expect(find.text('已排除'), findsNothing);
    expect(find.text('时长 9 秒'), findsOneWidget);
    expect(find.byTooltip('保留片段 (C / Enter)'), findsOneWidget);
    expect(find.byTooltip('排除片段 (X / Backspace)'), findsOneWidget);
  });

  testWidgets('always uses the original video for review playback', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        video: {
          'id': 'video-1',
          'source_path': '/tmp/original.mp4',
        },
        videoPath: '/tmp/working.mp4',
        reviewVideoPath: '/tmp/review.mp4',
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'candidate-1',
            'event_time_ms': 12000,
            'default_start_ms': 6000,
            'default_end_ms': 15000,
          },
        ],
      ),
    );

    expect(find.text('候选预览'), findsNothing);
    expect(find.byTooltip('切换视频来源'), findsNothing);
  });

  testWidgets(
    'shows candidate evidence below the video without crowding the row',
    (tester) async {
      await _pumpReview(
        tester,
        ProjectState(
          job: const {'state': 'completed'},
          candidates: [
            {
              'id': 'candidate-1',
              'event_time_ms': 12000,
              'default_start_ms': 6000,
              'default_end_ms': 15000,
              'review_status': 'pending',
              'note': '补篮后进球',
              'evidence_json': jsonEncode({
                'verification': {'trajectory_cross': true},
                'signals': {'net_score': 0.82, 'audio_score': 0.71},
                'rim_rebound': false,
                'review_reason_suggestion': {'primary': 'uncertain'},
              }),
            },
          ],
        ),
      );

      expect(find.text('轨迹穿框'), findsOneWidget);
      expect(find.text('篮网运动'), findsOneWidget);
      expect(find.text('音频支持'), findsNothing);
      expect(find.text('反弹判断'), findsOneWidget);
      expect(find.text('系统说明'), findsOneWidget);
      expect(find.byTooltip('综合轨迹穿框、篮网运动和反弹等信号得出，只用于排序和辅助审核。'), findsOneWidget);
      expect(find.byTooltip('判断篮球轨迹是否从篮筐上方进入，并在篮筐横向范围内向下穿过。'), findsOneWidget);
      expect(
        find.byTooltip('检测白色篮网区域在球经过后的运动强度；光线、球员遮挡会影响该信号。'),
        findsOneWidget,
      );
      expect(find.byTooltip('检测篮球撞框后向上或向外回弹；出现反弹通常降低进球可能性。'), findsOneWidget);
      expect(find.text('候选 00:12'), findsOneWidget);
      expect(find.text('片段 00:06 - 00:15 · 时长 9 秒'), findsOneWidget);
      expect(find.text('补篮后进球'), findsOneWidget);
      expect(find.byTooltip('调整片段范围'), findsOneWidget);
      expect(find.byTooltip('编辑备注'), findsOneWidget);
      expect(find.byTooltip('候选操作'), findsNothing);
      expect(find.text('00:06 - 00:15 · 时长 9 秒 · 置信度'), findsNothing);
    },
  );

  testWidgets('labels an ambiguous geometric crossing as inferred', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      ProjectState(
        job: const {'state': 'completed'},
        candidates: [
          {
            'id': 'candidate-1',
            'event_time_ms': 12000,
            'default_start_ms': 6000,
            'default_end_ms': 15000,
            'evidence_json': jsonEncode({
              'verification': {
                'verdict': 'ambiguous',
                'trajectory_cross': true,
                'complete_crossing': true,
              },
            }),
          },
        ],
      ),
    );

    expect(find.text('推定穿框'), findsOneWidget);
    expect(find.text('通过'), findsNothing);
  });

  testWidgets('provides a toggle for video annotations', (tester) async {
    await _pumpReview(
      tester,
      ProjectState(
        video: const {'width': 1920, 'height': 1080},
        job: const {'state': 'completed'},
        candidates: [
          {
            'id': 'candidate-1',
            'event_time_ms': 12000,
            'default_start_ms': 6000,
            'default_end_ms': 15000,
            'review_status': 'pending',
            'evidence_json': jsonEncode({
              'overlay': {
                'rim': {'center_x': 960, 'rim_y': 420, 'width': 100},
                'trajectory': [
                  {'time': 11.5, 'x': 900, 'y': 300},
                  {'time': 12.0, 'x': 950, 'y': 380},
                ],
                'crossing': {'time': 12.2, 'x': 960, 'y': 420, 'valid': true},
              },
            }),
          },
        ],
      ),
    );

    expect(find.byTooltip('关闭标注（A）'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(find.byTooltip('显示标注（A）'), findsOneWidget);
  });

  testWidgets('shows keyboard shortcut help on the candidate panel', (
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
          },
        ],
      ),
    );

    expect(
      find.byTooltip(
        '快捷键\nSpace  播放/暂停\nR  重播当前\nL  循环当前\nA  显示/关闭标注\n↑ / ↓  切换候选\n← / →  快退/快进 2 秒\nC / Enter  保留\nX / Backspace  排除\nCmd/Ctrl+Z  撤销',
      ),
      findsOneWidget,
    );
  });

  testWidgets('routes review shortcuts through the workspace focus node', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'early',
            'event_time_ms': 3000,
            'default_start_ms': 0,
            'default_end_ms': 6000,
          },
          {
            'id': 'late',
            'event_time_ms': 12000,
            'default_start_ms': 6000,
            'default_end_ms': 15000,
          },
        ],
      ),
    );

    final focus = tester.widget<Focus>(
      find.byKey(const Key('review-shortcut-focus')),
    );
    expect(focus.onKeyEvent, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('候选 00:12'), findsOneWidget);
  });

  testWidgets('filters candidates without changing their chronological order', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'pending',
            'event_time_ms': 3000,
            'default_start_ms': 0,
            'default_end_ms': 6000,
            'review_status': 'pending',
          },
          {
            'id': 'excluded',
            'event_time_ms': 9000,
            'default_start_ms': 6000,
            'default_end_ms': 12000,
            'review_status': 'excluded',
          },
          {
            'id': 'goal',
            'event_time_ms': 15000,
            'default_start_ms': 12000,
            'default_end_ms': 18000,
            'review_status': 'goal',
          },
        ],
      ),
    );

    await tester.tap(find.byTooltip('筛选候选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已排除').last);
    await tester.pump();

    expect(find.text('#1 00:09'), findsOneWidget);
    expect(find.text('#1 00:03'), findsNothing);
    expect(find.text('#1 00:15'), findsNothing);
  });

  testWidgets('exposes direct candidate editing actions below the video', (
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
          },
        ],
      ),
    );

    expect(find.byTooltip('调整片段范围'), findsOneWidget);
    expect(find.byTooltip('编辑备注'), findsOneWidget);
    expect(find.byTooltip('撤销上一次审核 (Cmd/Ctrl+Z)'), findsOneWidget);
    expect(find.byTooltip('候选操作'), findsNothing);
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

    final first = find.text('#1 00:03');
    final second = find.text('#2 00:12');
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
  });

  testWidgets('decision buttons do not switch the selected candidate', (
    tester,
  ) async {
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

    expect(find.text('候选 00:03'), findsOneWidget);
    await tester.tap(find.byTooltip('保留片段 (C / Enter)').at(1));
    await tester.pump();

    expect(find.text('候选 00:03'), findsOneWidget);
    expect(find.text('候选 00:12'), findsNothing);
  });

  testWidgets('excluding a candidate keeps the current preview', (
    tester,
  ) async {
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

    expect(find.text('候选 00:03'), findsOneWidget);
    await tester.tap(find.byTooltip('排除片段 (X / Backspace)').first);
    await tester.pump();

    expect(find.text('候选 00:03'), findsOneWidget);
    expect(find.text('候选 00:12'), findsNothing);
  });

  testWidgets('throttles candidate cover extraction', (tester) async {
    final notifier = _PreviewTrackingNotifier(
      ProjectState(
        video: const {'id': 'video-1'},
        job: const {'state': 'completed'},
        candidates: List.generate(
          20,
          (index) => {
            'id': 'candidate-$index',
            'event_time_ms': index * 3000,
            'default_start_ms': index * 3000,
            'default_end_ms': index * 3000 + 3000,
          },
        ),
      ),
    );
    await _pumpReview(tester, notifier.initialState, notifier: notifier);
    await tester.pump(const Duration(seconds: 1));

    expect(notifier.maxConcurrentPreviewLoads, lessThanOrEqualTo(2));
  });
}

Future<void> _pumpReview(
  WidgetTester tester,
  ProjectState state, {
  Size size = const Size(1200, 800),
  ProjectNotifier? notifier,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectProvider.overrideWith(() => notifier ?? _ReviewNotifier(state)),
      ],
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

  @override
  Future<bool> reviewCandidate(
    String id,
    String status, {
    String? reason,
    bool showNotice = true,
  }) async {
    final candidates = state.candidates.map((candidate) {
      if (candidate['id']?.toString() != id) return candidate;
      return <String, dynamic>{...candidate, 'selection_status': status};
    }).toList();
    state = state.copyWith(candidates: candidates);
    return true;
  }
}

class _PreviewTrackingNotifier extends _ReviewNotifier {
  _PreviewTrackingNotifier(super.initialState);

  int activePreviewLoads = 0;
  int maxConcurrentPreviewLoads = 0;

  @override
  Future<String?> loadCandidatePreview(String candidateId, int timeMs) async {
    activePreviewLoads++;
    if (activePreviewLoads > maxConcurrentPreviewLoads) {
      maxConcurrentPreviewLoads = activePreviewLoads;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    activePreviewLoads--;
    return null;
  }
}
