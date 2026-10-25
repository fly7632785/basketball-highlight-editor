import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:async';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/features/review/media_readiness.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/theme/tokens.dart';

void main() {
  testWidgets(
    'player tag filters compose with status without changing export scope',
    (tester) async {
      final notifier = _TagReviewNotifier(_tagReviewState());
      await _pumpReview(tester, notifier.initialState, notifier: notifier);
      await _chooseTagFilter(tester, 'player:p1');
      expect(find.byKey(const ValueKey('player-chip-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('player-chip-c3')), findsOneWidget);
      expect(find.byKey(const ValueKey('player-chip-c2')), findsNothing);
      expect(find.text('显示 2 / 4'), findsOneWidget);
      expect(find.text('导出 3 个片段'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('review-status-included')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-chip-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('player-chip-c3')), findsNothing);
      expect(find.text('显示 1 / 4'), findsOneWidget);
      expect(find.text('导出 3 个片段'), findsOneWidget);

      for (final entry in {
        'all': '3',
        'tagged': '2',
        'untagged': '1',
        'player:p1': '1',
        'player:p3': '0',
      }.entries) {
        expect(
          find.descendant(
            of: await _tagOption(tester, entry.key),
            matching: find.text(entry.value),
          ),
          findsOneWidget,
        );
        if (find.byType(PopupMenuItem<String>).evaluate().isNotEmpty) {
          await tester.tapAt(Offset.zero);
          await tester.pumpAndSettle();
        }
      }
      await _chooseTagFilter(tester, 'tagged');
      expect(find.text('#1 00:03'), findsOneWidget);
      expect(find.text('#2 00:12'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.text('候选 00:12'), findsOneWidget);
    },
  );

  testWidgets(
    'untagged filter updates when tags change and can clear an empty result',
    (tester) async {
      final notifier = _TagReviewNotifier(_tagReviewState());
      await _pumpReview(tester, notifier.initialState, notifier: notifier);
      await _chooseTagFilter(tester, 'untagged');
      expect(find.byKey(const ValueKey('player-chip-c2')), findsOneWidget);
      expect(find.text('显示 1 / 4'), findsOneWidget);
      await notifier.setCandidatePlayer('c2', 'p1');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的候选'), findsOneWidget);
      expect(find.text('显示 0 / 4'), findsOneWidget);
      await tester.tap(find.text('显示全部'));
      await tester.pumpAndSettle();
      expect(find.text('全部标签'), findsOneWidget);
      expect(find.byKey(const Key('review-filter-banner')), findsNothing);
      expect(find.text('导出 3 个片段'), findsOneWidget);
    },
  );

  testWidgets(
    'tagging a middle untagged clip advances nearby instead of restarting review',
    (tester) async {
      final initial = _tagReviewState();
      final notifier = _TagReviewNotifier(
        initial.copyWith(
          candidates: [
            for (final candidate in initial.candidates)
              if (candidate['id'] != 'c3')
                {...candidate, 'player_id': null, 'player_name': null}
              else
                candidate,
          ],
        ),
      );
      await _pumpReview(tester, notifier.initialState, notifier: notifier);
      await _chooseTagFilter(tester, 'untagged');
      await tester.tap(find.text('#2 00:06'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-chip-c2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小夏'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-chip-c2')), findsNothing);
      expect(find.text('候选 00:12'), findsOneWidget);
      expect(find.text('显示 2 / 4'), findsOneWidget);
    },
  );

  testWidgets('empty-result recovery clears both tag and status filters', (
    tester,
  ) async {
    final notifier = _TagReviewNotifier(_tagReviewState());
    await _pumpReview(tester, notifier.initialState, notifier: notifier);
    await tester.tap(find.byKey(const ValueKey('review-status-excluded')));
    await tester.pumpAndSettle();
    await _chooseTagFilter(tester, 'player:p2');
    expect(find.text('没有匹配的候选'), findsOneWidget);
    await tester.tap(find.text('显示全部'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-filter-banner')), findsNothing);
    expect(find.text('全部标签'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
  });

  testWidgets('extra players collapse into +N and stay visible once picked', (
    tester,
  ) async {
    final base = _tagReviewState();
    final notifier = _TagReviewNotifier(
      base.copyWith(
        players: [
          ...base.players,
          for (var i = 4; i <= 12; i++) {'id': 'p$i', 'name': '球员$i'},
        ],
      ),
    );
    await _pumpReview(tester, notifier.initialState, notifier: notifier);
    expect(find.byKey(const Key('review-tag-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('review-tag-option-player:p12')), findsNothing);

    await _chooseTagFilter(tester, 'player:p12');
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(
      find.byKey(const ValueKey('review-tag-option-player:p12')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('review-tag-more')), findsOneWidget);
    expect(find.text('没有匹配的候选'), findsOneWidget);
  });

  testWidgets('progress counts reviewed clips and marks the rest', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        candidates: [
          {
            'id': 'seen',
            'event_time_ms': 3000,
            'default_start_ms': 0,
            'default_end_ms': 6000,
            'review_status': 'goal',
          },
          {
            'id': 'new',
            'event_time_ms': 9000,
            'default_start_ms': 6000,
            'default_end_ms': 12000,
            'review_status': 'pending',
          },
        ],
      ),
    );
    expect(find.text('已审核 1 / 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('unreviewed-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('unreviewed-seen')), findsNothing);
  });

  test('players after the ninth get the Q to P letter row', () {
    expect(playerShortcutLabel(0), '1');
    expect(playerShortcutLabel(8), '9');
    expect(playerShortcutLabel(9), 'Q');
    expect(playerShortcutLabel(12), 'R');
    expect(playerShortcutLabel(18), 'P');
    expect(playerShortcutLabel(19), isNull);
  });

  testWidgets('letter keys tag players beyond the ninth', (tester) async {
    final notifier = _TagReviewNotifier(
      _tagReviewState().copyWith(
        players: [
          for (var i = 1; i <= 10; i++) {'id': 'p$i', 'name': '球员$i'},
        ],
      ),
    );
    await _pumpReview(tester, notifier.initialState, notifier: notifier);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pumpAndSettle();

    final tagged = notifier.lastTaggedIds;
    expect(tagged, isNotNull);
    expect(
      notifier.current.candidates.firstWhere((c) => c['id'] == tagged!.single)['player_id'],
      'p10',
    );
  });

  testWidgets('R tags a player instead of replaying', (tester) async {
    final notifier = _TagReviewNotifier(
      _tagReviewState().copyWith(
        players: [
          for (var i = 1; i <= 13; i++) {'id': 'p$i', 'name': '球员$i'},
        ],
      ),
    );
    await _pumpReview(tester, notifier.initialState, notifier: notifier);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();

    final tagged = notifier.lastTaggedIds;
    expect(tagged, isNotNull);
    expect(
      notifier.current.candidates.firstWhere((c) => c['id'] == tagged!.single)['player_id'],
      'p13',
    );
  });

  testWidgets('the key left of 1 excludes the selected clip', (tester) async {
    final notifier = _TagReviewNotifier(_tagReviewState());
    await _pumpReview(tester, notifier.initialState, notifier: notifier);

    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await tester.pumpAndSettle();

    expect(
      notifier.current.candidates.where((c) => c['selection_status'] == 'excluded'),
      hasLength(1),
    );
  });

  testWidgets('number keys tag the selected clip in player menu order', (
    tester,
  ) async {
    final notifier = _TagReviewNotifier(_tagReviewState());
    await _pumpReview(tester, notifier.initialState, notifier: notifier);
    await _chooseTagFilter(tester, 'untagged');
    expect(find.byKey(const ValueKey('player-chip-c2')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
    await tester.pumpAndSettle();
    expect(notifier.lastTaggedIds, isNull);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(notifier.lastTaggedIds, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pumpAndSettle();
    expect(notifier.lastTaggedIds, ['c2']);
    expect(
      notifier.current.candidates.firstWhere(
        (c) => c['id'] == 'c2',
      )['player_id'],
      'p2',
    );
    expect(find.text('没有匹配的候选'), findsOneWidget);

    await tester.tap(find.text('显示全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#1 00:03'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad0);
    await tester.pumpAndSettle();
    expect(notifier.lastTaggedIds, ['c1']);
    expect(
      notifier.current.candidates.firstWhere(
        (c) => c['id'] == 'c1',
      )['player_id'],
      isNull,
    );
  });

  testWidgets('batch duration applies to the current filtered list', (
    tester,
  ) async {
    final notifier = _TagReviewNotifier(_tagReviewState());
    await _pumpReview(tester, notifier.initialState, notifier: notifier);
    await _chooseTagFilter(tester, 'player:p1');
    await tester.tap(find.byTooltip('批量设置片段时长'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前列表的 2 个候选'), findsOneWidget);
    await tester.tap(find.text('应用到 2 个片段'));
    await tester.pumpAndSettle();
    expect(notifier.rangeIds, ['c1', 'c3']);
  });

  testWidgets(
    'deleted tags and a different project cannot leave a stale filter',
    (tester) async {
      final notifier = _TagReviewNotifier(_tagReviewState());
      await _pumpReview(tester, notifier.initialState, notifier: notifier);
      await _chooseTagFilter(tester, 'player:p3');
      expect(find.text('没有匹配的候选'), findsOneWidget);
      notifier.replaceState(
        notifier.current.copyWith(
          players: notifier.current.players.take(2).toList(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('全部标签'), findsOneWidget);
      expect(find.byKey(const Key('review-filter-banner')), findsNothing);
      await _chooseTagFilter(tester, 'player:p1');
      await tester.tap(find.byKey(const ValueKey('review-status-included')));
      await tester.pumpAndSettle();
      notifier.replaceState(_tagReviewState(projectId: 'v2'));
      await tester.pumpAndSettle();
      expect(find.text('全部标签'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.byKey(const Key('review-filter-banner')), findsNothing);
    },
  );

  for (final size in [const Size(1000, 800), const Size(760, 900)]) {
    testWidgets('English tag filters handle long names at $size', (
      tester,
    ) async {
      final notifier = _TagReviewNotifier(
        _tagReviewState(
          playerName: List.filled(20, 'Long player name').join(' '),
        ),
      );
      await _pumpReview(
        tester,
        notifier.initialState,
        notifier: notifier,
        size: size,
        locale: const Locale('en'),
      );
      await tester.ensureVisible(find.byKey(const Key('review-player-filter')));
      await _chooseTagFilter(tester, 'player:p1');
      expect(find.text('Showing 2 / 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final frame in [
    const Size(1440, 1080),
    const Size(1920, 1080),
    const Size(1080, 1920),
    Size.zero,
  ]) {
    testWidgets('range dialog preserves source ratio $frame without overflow', (
      tester,
    ) async {
      await _pumpReview(
        tester,
        ProjectState(
          video: {
            'width': frame.width,
            'height': frame.height,
            'duration_ms': 60000,
          },
          candidates: const [
            {
              'id': 'c1',
              'event_time_ms': 12000,
              'default_start_ms': 8000,
              'default_end_ms': 16000,
            },
          ],
        ),
        size: const Size(1100, 700),
      );
      await tester.tap(find.byTooltip('调整片段范围'));
      await tester.pumpAndSettle();
      final preview = find.byKey(const Key('clip-range-video-frame'));
      final size = tester.getSize(preview);
      final expected = frame.isEmpty ? 16 / 9 : frame.aspectRatio;
      expect(size.aspectRatio, closeTo(expected, 0.001));
      expect(size.width, greaterThan(700));
      expect(
        tester.getTopLeft(preview).dx,
        tester.getTopLeft(find.text('调整片段范围')).dx,
      );
      expect(tester.takeException(), isNull);
      // Tall source frames must scroll rather than clipping the controls.
      await tester.ensureVisible(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.text('应用').hitTestable(), findsOneWidget);
    });
  }

  testWidgets(
    'saving a player tag preserves list geometry, scroll and selected clip',
    (tester) async {
      final notifier = _PlayerLayoutNotifier(
        ProjectState(
          video: const {'id': 'v1'},
          job: const {'state': 'completed'},
          players: const [
            {'id': 'p1', 'name': '小夏'},
          ],
          candidates: List.generate(
            389,
            (i) => <String, dynamic>{
              'id': 'c$i',
              'event_time_ms': i * 3000,
              'default_start_ms': i * 3000,
              'default_end_ms': i * 3000 + 3000,
              'review_status': 'pending',
            },
          ),
        ),
      );
      await _pumpReview(tester, notifier.initialState, notifier: notifier);
      final panel = find.byKey(const Key('candidate-panel-inset'));
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: panel, matching: find.byType(Scrollable)).last,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('player-chip-c388')),
        1500,
        maxScrolls: 100,
        scrollable: find
            .descendant(of: panel, matching: find.byType(Scrollable))
            .last,
      );
      await tester.tap(find.text('#389 19:24'));
      await tester.pumpAndSettle();
      final chip = find.byKey(const ValueKey('player-chip-c388'));
      final bounds = tester.getRect(panel);
      final rowBounds = tester.getRect(chip);
      final offset = scroll.position.pixels;
      final viewport = scroll.position.viewportDimension;
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, offset, reason: 'opening the player menu must not scroll the candidate list');
      await tester.tap(find.text('小夏'));
      await tester.pump();
      expect(find.text('正在保存球员标签…'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('create-manual-candidate'))).onPressed, isNull);
      expect(find.byKey(const Key('review-more-actions')), findsOneWidget);
      expect(tester.getRect(panel), bounds);
      expect(scroll.position.pixels, offset);
      expect(scroll.position.viewportDimension, viewport);
      expect(tester.getRect(chip), rowBounds);
      expect(find.text('候选 19:24'), findsOneWidget);
      notifier.saved.complete();
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), bounds);
      expect(scroll.position.pixels, offset);
      expect(scroll.position.viewportDimension, viewport);
      expect(tester.getRect(chip).top, rowBounds.top);
      expect(find.text('候选 19:24'), findsOneWidget);
      expect(notifier.current.candidates.last['player_id'], 'p1');
      expect(notifier.current.candidates.last['review_status'], 'pending');
    },
  );

  testWidgets('shows saving feedback while player changes are pending', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(busy: true, busyMessage: '正在保存球员标签…'),
    );
    expect(find.text('正在保存球员标签…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  test('does not autoplay the review video after opening', () {
    expect(reviewVideoAutoPlayAfterOpen, isFalse);
  });

  test('autoplays after switching review source or candidate', () {
    expect(reviewVideoAutoPlayAfterSourceSwitch, isTrue);
    expect(reviewVideoAutoPlayAfterCandidateSwitch, isTrue);
  });

  test(
    'uses the full original-video timeline even when a candidate is selected',
    () {
      final bounds = reviewTimelineBounds(
        isOriginalVideo: true,
        candidate: const {'default_start_ms': 6000, 'default_end_ms': 15000},
      );

      expect(bounds.startMs, 0);
      expect(bounds.endMs, isNull);
    },
  );

  test('keeps candidate bounds for an isolated preview source', () {
    final bounds = reviewTimelineBounds(
      isOriginalVideo: false,
      candidate: const {'default_start_ms': 6000, 'default_end_ms': 15000},
    );

    expect(bounds.startMs, 6000);
    expect(bounds.endMs, 15000);
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

  testWidgets('shows fast-mode risk and persisted analysis details', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        analysisMode: 'fast',
        job: {
          'state': 'completed',
          'started_at': '2026-08-11T10:00:00.000+00:00',
          'finished_at': '2026-08-11T10:00:08.000+00:00',
          'checkpoint_json':
              '{"stage_timings_ms":{"prepare_proxy":1250,"coarse_scan":2300,"refine_candidates":4700},"cache_hits":2}',
        },
      ),
    );

    expect(find.text('快速分析 · 可能漏检 · 0 个候选 · 用时 00:08'), findsOneWidget);
    expect(
      find.byTooltip('分析详情：代理 1.3 秒 · 粗扫 2.3 秒 · 精筛 4.7 秒 · 缓存命中 2'),
      findsOneWidget,
    );
  });

  testWidgets('marks GPU acceleration and names the inference backend', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {
          'state': 'completed',
          'started_at': '2026-08-11T10:00:00.000+00:00',
          'finished_at': '2026-08-11T10:12:30.000+00:00',
          'checkpoint_json':
              '{"stage_timings_ms":{"prepare_proxy":1250},"inference_device":"dml"}',
        },
      ),
    );

    expect(find.text('标准分析 · 0 个候选 · 用时 12:30 · GPU'), findsOneWidget);
    expect(
      find.byTooltip('分析详情：代理 1.3 秒 · 推理 DirectML'),
      findsOneWidget,
    );
  });

  testWidgets('reports a CPU fallback without the GPU badge', (tester) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {
          'state': 'completed',
          'started_at': '2026-08-11T10:00:00.000+00:00',
          'finished_at': '2026-08-11T10:12:30.000+00:00',
          'checkpoint_json':
              '{"stage_timings_ms":{"prepare_proxy":1250},"inference_device":"cpu"}',
        },
      ),
    );

    expect(find.text('标准分析 · 0 个候选 · 用时 12:30'), findsOneWidget);
    expect(find.byTooltip('分析详情：代理 1.3 秒 · 推理 CPU'), findsOneWidget);
  });

  testWidgets('explains standard reanalysis for an empty fast result', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        analysisMode: 'fast',
        video: {'id': 'video-1', 'source_path': '/tmp/original.mp4'},
        videoPath: '/tmp/original.mp4',
        job: {'state': 'completed'},
      ),
    );

    expect(find.text('快速分析未找到候选 · 可能漏检'), findsOneWidget);
    expect(find.text('用标准模式重新分析', skipOffstage: false), findsOneWidget);
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

    expect(statusInset.padding, EdgeInsets.zero);
    expect(
      controlsInset.padding,
      const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
    );
    expect(
      candidatePanel.padding,
      const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, Spacing.sm),
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

    expect(find.byType(SingleChildScrollView), findsWidgets);
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
    expect(find.text('已排除'), findsNothing);
    expect(find.text('会导出'), findsOneWidget);
    expect(find.text('9 秒'), findsOneWidget);
    expect(find.byTooltip('保留片段 (C / Enter)'), findsOneWidget);
    expect(find.byTooltip('排除片段 (X / ` / Backspace)'), findsOneWidget);
  });

  testWidgets('opens the player picker next to the candidate row', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        players: [
          {'id': 'player-1', 'name': '科比'},
        ],
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

    await tester.tap(find.byKey(const ValueKey('player-chip-candidate-1')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('选择球员'), findsOneWidget);
    expect(find.text('科比'), findsOneWidget);
    expect(find.text('新建球员'), findsOneWidget);
  });

  testWidgets('player groups save the roster and import it into a project', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'bhe.player_groups': jsonEncode([
        {
          'name': '周六队',
          'players': ['科比', '罗斯'],
        },
      ]),
    });
    final notifier = _TagReviewNotifier(
      const ProjectState(
        job: {'state': 'completed'},
        players: [
          {'id': 'player-1', 'name': '科比'},
        ],
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
    await _pumpReview(tester, notifier.initialState, notifier: notifier);

    await tester.tap(find.byKey(const ValueKey('player-chip-candidate-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('球员分组'));
    await tester.pumpAndSettle();
    expect(find.text('周六队'), findsOneWidget);
    expect(find.text('科比、罗斯'), findsOneWidget);

    await tester.tap(find.text('把当前球员存为分组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新队');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = jsonDecode(
      (await SharedPreferences.getInstance()).getString('bhe.player_groups')!,
    );
    expect(saved, [
      {
        'name': '周六队',
        'players': ['科比', '罗斯'],
      },
      {
        'name': '新队',
        'players': ['科比'],
      },
    ]);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('player-group-周六队')),
        matching: find.text('导入'),
      ),
    );
    await tester.pumpAndSettle();
    expect(notifier.importedNames, ['科比', '罗斯']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a multi-part project reviews parts in order and follows the part', (
    tester,
  ) async {
    Map<String, dynamic> candidate(String id, String videoId, int segment, int ms) => {
      'id': id,
      'video_id': videoId,
      'segment': segment,
      'event_time_ms': ms,
      'default_start_ms': ms - 3000,
      'default_end_ms': ms + 1000,
    };
    final notifier = _TagReviewNotifier(
      ProjectState(
        job: const {'state': 'completed'},
        video: const {'id': 'v1', 'source_path': '/v/part1.mp4', 'duration_ms': 300000},
        videoPath: '/v/part1.mp4',
        previewPath: '/v/part1_frame.jpg',
        videos: const [
          {'id': 'v1', 'source_path': '/v/part1.mp4', 'duration_ms': 300000},
          {'id': 'v2', 'source_path': '/v/part2.mp4', 'duration_ms': 300000},
        ],
        candidates: [
          candidate('late', 'v2', 2, 5000),
          candidate('early', 'v1', 1, 200000),
        ],
      ),
    );
    await _pumpReview(tester, notifier.initialState, notifier: notifier);
    await tester.pumpAndSettle();

    expect(find.text('第 1 段 · 03:20'), findsOneWidget);
    final pane = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_VideoPane',
    );
    expect((tester.widget(pane) as dynamic).videoPath, '/v/part1.mp4');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('player-chip-early'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('player-chip-late'))).dy),
    );

    await tester.tap(find.byKey(const ValueKey('review-segment-option-v2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-chip-early')), findsNothing);
    expect(find.text('第 2 段 · 00:05'), findsOneWidget);
    expect(notifier.activated, ['v2']);
  });

  testWidgets('keeps player chips in a fixed aligned column', (tester) async {
    await _pumpReview(
      tester,
      const ProjectState(
        job: {'state': 'completed'},
        players: [
          {'id': 'player-1', 'name': '科比'},
          {'id': 'player-2', 'name': '非常长的球员名称'},
        ],
        candidates: [
          {
            'id': 'candidate-1',
            'event_time_ms': 12000,
            'default_start_ms': 6000,
            'default_end_ms': 15000,
            'player_id': 'player-1',
            'player_name': '科比',
          },
          {
            'id': 'candidate-2',
            'event_time_ms': 24000,
            'default_start_ms': 18000,
            'default_end_ms': 27000,
            'player_id': 'player-2',
            'player_name': '非常长的球员名称',
          },
        ],
      ),
    );

    final first = tester.getTopLeft(
      find.byKey(const ValueKey('player-chip-candidate-1')),
    );
    final second = tester.getTopLeft(
      find.byKey(const ValueKey('player-chip-candidate-2')),
    );
    expect(second.dx, first.dx);
  });

  testWidgets(
    'shows coarse fast-analysis evidence instead of blank pending values',
    (tester) async {
      await _pumpReview(
        tester,
        ProjectState(
          analysisMode: 'fast',
          job: const {'state': 'completed'},
          candidates: [
            {
              'id': 'candidate-1',
              'event_time_ms': 12000,
              'default_start_ms': 6000,
              'default_end_ms': 15000,
              'confidence': 'medium',
              'score': 0.62,
              'evidence_json': jsonEncode({
                'analysis_source': 'coarse',
                'coarse_detection_confidence': 0.62,
                'trajectory': {'trajectory_score': 0.62},
              }),
            },
          ],
        ),
      );

      expect(find.text('中'), findsOneWidget);
      expect(find.text('62%'), findsWidgets);
      expect(find.text('快速分析未计算'), findsOneWidget);
      expect(find.byTooltip('快速分析不会拟合完整轨迹；切换到标准分析后才会计算。'), findsOneWidget);
    },
  );

  testWidgets('defaults review playback to the candidate preview', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        video: {'id': 'video-1', 'source_path': '/tmp/original.mp4'},
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

    expect(find.text('候选预览'), findsOneWidget);
    expect(find.text('原视频'), findsOneWidget);
    expect(find.byTooltip('切换视频来源'), findsOneWidget);
  });

  test('review playback never falls back to the import preview image', () {
    expect(
      resolveReviewPlaybackPath(
        multiVideo: false,
        originalVideoPath: '/tmp/original.mp4',
        reviewVideoPath: null,
      ),
      '/tmp/original.mp4',
    );
    expect(
      resolveReviewPlaybackPath(
        multiVideo: false,
        originalVideoPath: '/tmp/original.mp4',
        reviewVideoPath: '',
      ),
      '/tmp/original.mp4',
    );
    expect(
      resolveReviewPlaybackPath(
        multiVideo: false,
        originalVideoPath: '/tmp/original.mp4',
        reviewVideoPath: '/tmp/review.mp4',
      ),
      '/tmp/review.mp4',
    );
    expect(
      resolveReviewPlaybackPath(
        multiVideo: true,
        originalVideoPath: '/tmp/segment.mp4',
        reviewVideoPath: '/tmp/review.mp4',
      ),
      '/tmp/segment.mp4',
    );
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
      expect(find.text('预测评分'), findsOneWidget);
      expect(find.text('轨迹不足'), findsOneWidget);
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

  testWidgets('marks rim-check exclusions and explains the result', (
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
            'review_status': 'excluded',
            'selection_status': 'excluded',
            'review_reason': 'auto_rim_check',
            'evidence_json': jsonEncode({
              'rim_check': {'status': 'rejected', 'reason': 'not_occluded'},
            }),
          },
          {
            'id': 'candidate-2',
            'event_time_ms': 30000,
            'default_start_ms': 24000,
            'default_end_ms': 33000,
            'review_status': 'excluded',
            'selection_status': 'excluded',
            'review_reason': 'rim_out',
          },
        ],
      ),
    );

    expect(find.text('自动排除'), findsOneWidget);
    expect(find.text('已排除'), findsOneWidget);
    expect(find.byKey(const Key('inspector-rim-check')), findsOneWidget);
    expect(find.text('未通过：球从篮筐前方掠过，没有进网'), findsOneWidget);
  });

  testWidgets('asks for manual review when the rim is too small to check', (
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
              'rim_check': {'status': 'skipped', 'reason': 'small_rim'},
            }),
          },
        ],
      ),
      locale: const Locale('en'),
    );

    expect(
      find.text(
        'Not checked: the rim is too small in the frame, please review manually',
      ),
      findsOneWidget,
    );
  });

  testWidgets('keeps an unsure rim check and asks for review', (
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
              'rim_check': {'status': 'unsure', 'reason': 'no_exit'},
            }),
          },
        ],
      ),
    );

    expect(find.text('自动排除'), findsNothing);
    expect(find.text('未确认：没看清球是否从网底落下，请人工确认'), findsOneWidget);
  });

  testWidgets('filters the queue by rim check result', (tester) async {
    Map<String, dynamic> candidate(String id, int ms, String status) => {
      'id': id,
      'event_time_ms': ms,
      'default_start_ms': ms - 4000,
      'default_end_ms': ms + 1000,
      'evidence_json': jsonEncode({
        'rim_check': {'status': status, 'reason': 'no_exit'},
      }),
    };
    await _pumpReview(
      tester,
      ProjectState(
        job: const {'state': 'completed'},
        candidates: [
          candidate('made-1', 12000, 'made'),
          candidate('unsure-1', 30000, 'unsure'),
          candidate('unsure-2', 50000, 'unsure'),
        ],
      ),
    );

    expect(find.byKey(const ValueKey('candidate-row-made-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('review-rim-option-unsure')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('candidate-row-made-1')), findsNothing);
    expect(find.byKey(const ValueKey('candidate-row-unsure-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('candidate-row-unsure-2')), findsOneWidget);

    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('candidate-row-made-1')), findsOneWidget);
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

    expect(find.byTooltip('显示标注（A）'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(find.byTooltip('关闭标注（A）'), findsOneWidget);
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
        '快捷键\nSpace  播放/暂停\nL  循环当前\nA  显示/关闭标注\n↑ / ↓  切换候选\n← / →  快退/快进 2 秒 · 加 Shift 每次 0.1 秒\nC / Enter  保留\nX / ` / Backspace  排除\n1–9、Q–P  设置球员标签 · 0  清除\nCmd/Ctrl+Z  撤销',
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

    expect(find.text('待审核'), findsNothing);
    expect(find.text('已确认'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('review-status-excluded')));
    await tester.pump();

    expect(find.text('#1 00:09'), findsOneWidget);
    expect(find.text('#1 00:03'), findsNothing);
    expect(find.text('#1 00:15'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('review-status-included')));
    await tester.pumpAndSettle();
    expect(find.text('#1 00:03'), findsOneWidget);
    expect(find.text('#2 00:15'), findsOneWidget);
    expect(find.text('#1 00:09'), findsNothing);
    await tester.tap(find.byTooltip('保留片段 (C / Enter)').first);
    await tester.pumpAndSettle();
    expect(find.text('#1 00:03'), findsOneWidget);
    expect(find.text('#2 00:15'), findsOneWidget);
  });

  testWidgets('says so when the source video file is missing', (tester) async {
    await _pumpReview(
      tester,
      const ProjectState(
        video: {
          'id': 'v1',
          'source_path': '/tmp/bhe-widget-source-gone.mp4',
          'duration_ms': 60000,
        },
        videoPath: '/tmp/bhe-widget-source-gone.mp4',
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
    await tester.pumpAndSettle();

    expect(find.text('源视频找不到，请到导入页重新定位视频'), findsOneWidget);
  });

  testWidgets('exposes direct candidate editing actions below the video', (
    tester,
  ) async {
    await _pumpReview(
      tester,
      const ProjectState(
        videoPath: '/tmp/bhe-widget-missing.mp4',
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
    expect(find.text('补漏片段'), findsOneWidget);
    expect(find.byTooltip('从原视频当前时间补漏候选'), findsOneWidget);
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
    await tester.tap(find.byTooltip('排除片段 (X / ` / Backspace)').first);
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
  Locale? locale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectProvider.overrideWith(() => notifier ?? _ReviewNotifier(state)),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: locale == null
            ? null
            : BheLocalizations.localizationsDelegates,
        supportedLocales: BheLocalizations.supportedLocales,
        home: const Scaffold(body: ReviewScreen()),
      ),
    ),
  );
  await tester.pump();
}

Future<Finder> _tagOption(WidgetTester tester, String value) async {
  final option = find.byKey(ValueKey('review-tag-option-$value'));
  if (option.evaluate().isEmpty) {
    final more = find.byKey(const Key('review-tag-more'));
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  return option;
}

Future<void> _chooseTagFilter(WidgetTester tester, String value) async {
  await tester.tap(await _tagOption(tester, value));
  await tester.pumpAndSettle();
}

ProjectState _tagReviewState({
  String projectId = 'v1',
  String playerName = '小夏',
}) => ProjectState(
  video: {'id': projectId},
  job: const {'state': 'completed'},
  players: [
    {'id': 'p1', 'name': playerName},
    {'id': 'p2', 'name': '小王'},
    {'id': 'p3', 'name': '零片段'},
  ],
  candidates: [
    {
      'id': 'c1',
      'event_time_ms': 3000,
      'default_start_ms': 0,
      'default_end_ms': 6000,
      'player_id': 'p1',
      'player_name': playerName,
      'review_status': 'pending',
    },
    {
      'id': 'c2',
      'event_time_ms': 6000,
      'default_start_ms': 3000,
      'default_end_ms': 9000,
      'player_id': null,
      'review_status': 'pending',
    },
    {
      'id': 'c3',
      'event_time_ms': 9000,
      'default_start_ms': 6000,
      'default_end_ms': 12000,
      'player_id': 'p1',
      'player_name': playerName,
      'review_status': 'excluded',
    },
    {
      'id': 'c4',
      'event_time_ms': 12000,
      'default_start_ms': 9000,
      'default_end_ms': 15000,
      'player_id': 'p2',
      'player_name': '小王',
      'review_status': 'goal',
    },
  ],
);

class _TagReviewNotifier extends _ReviewNotifier {
  _TagReviewNotifier(super.initialState);
  List<String>? lastTaggedIds;
  List<String>? rangeIds;
  List<String>? importedNames;
  final activated = <String>[];
  ProjectState get current => state;

  @override
  void activateVideo(String videoId) {
    activated.add(videoId);
    state = state.copyWith(
      video: state.videos.firstWhere((video) => video['id'] == videoId),
    );
  }

  @override
  Future<void> importPlayers(List<String> names) async {
    importedNames = names;
  }
  void replaceState(ProjectState value) => state = value;

  @override
  Future<void> startReview(String id) async {}

  @override
  Future<String?> loadCandidatePreview(String candidateId, int timeMs) async =>
      null;

  @override
  Future<Map<String, dynamic>?> updateClipRanges({
    required List<String> candidateIds,
    required int beforeMs,
    required int afterMs,
    bool overwriteManual = false,
  }) async {
    rangeIds = candidateIds;
    return null;
  }

  @override
  Future<void> setCandidatePlayer(String candidateId, String? playerId) async {
    final candidateIds = [candidateId];
    lastTaggedIds = candidateIds;
    final playerName = state.players
        .where((player) => player['id'] == playerId)
        .map((player) => player['name'])
        .firstOrNull;
    state = state.copyWith(
      candidates: [
        for (final candidate in state.candidates)
          if (candidateIds.contains(candidate['id']))
            {...candidate, 'player_id': playerId, 'player_name': playerName}
          else
            candidate,
      ],
    );
  }
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

class _PlayerLayoutNotifier extends _ReviewNotifier {
  _PlayerLayoutNotifier(super.initialState);
  final saved = Completer<void>();
  ProjectState get current => state;

  @override
  Future<void> startReview(String id) async {}

  @override
  Future<String?> loadCandidatePreview(String candidateId, int timeMs) async => null;

  @override
  Future<void> setCandidatePlayer(String candidateId, String? playerId) async {
    state = state.copyWith(busy: true, busyMessage: '正在保存球员标签…');
    await saved.future;
    state = state.copyWith(
      busy: false,
      busyMessage: null,
      candidates: [
        for (final c in state.candidates)
          if (c['id'] == candidateId)
            {...c, 'player_id': playerId, 'player_name': '小夏'}
          else
            c,
      ],
    );
  }
}
