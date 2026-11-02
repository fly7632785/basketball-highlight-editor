
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/features/review/clip_range_timeline.dart';
import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/providers/playback_coordinator.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RangeNotifier extends ProjectNotifier {
  _RangeNotifier({
    this.start = 8000,
    this.end = 16000,
    this.durationMs = 180000,
  });
  final int start;
  final int end;
  final int? durationMs;
  final saved = <({int startMs, int endMs})>[];
  final reviews = <String>[];

  @override
  ProjectState build() => ProjectState(
    video: {'id': 'v1', 'duration_ms': durationMs},
    job: const {'state': 'completed'},
    candidates: [
      {
        'id': 'c1',
        'event_time_ms': (start + end) ~/ 2,
        'default_start_ms': start,
        'default_end_ms': end,
        'review_status': 'pending',
      },
    ],
  );

  @override
  Future<void> startReview(String id) async {}
  @override
  Future<String?> loadCandidatePreview(String id, int timeMs) async => null;

  @override
  Future<bool> reviewCandidate(
    String id,
    String status, {
    String? reason,
    bool showNotice = true,
  }) async {
    reviews.add(status);
    return true;
  }

  @override
  Future<void> updateClipRange(String id, int startMs, int endMs) async {
    saved.add((startMs: startMs, endMs: endMs));
    state = state.copyWith(
      candidates: [
        {
          ...state.candidates.single,
          'review_start_ms': startMs,
          'review_end_ms': endMs,
        },
      ],
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _RangeNotifier notifier, {
  PlaybackCoordinator? coordinator,
  Locale? locale,
}) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectProvider.overrideWith(() => notifier),
        if (coordinator != null)
          playbackCoordinatorProvider.overrideWithValue(coordinator),
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
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('调整片段范围'));
  await tester.pumpAndSettle();
  expect(find.byType(Dialog), findsOneWidget);
}

Finder _field(int index) => find
    .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
    .at(index);

Future<void> _enter(
  WidgetTester tester,
  int index,
  String text, {
  bool submit = false,
}) async {
  await tester.ensureVisible(_field(index));
  await tester.enterText(_field(index), text);
  if (submit) await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Future<void> _apply(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, '应用');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('apply commits both time drafts without Enter', (tester) async {
    final notifier = _RangeNotifier();
    await _pump(tester, notifier);
    await _open(tester);
    await _enter(tester, 0, '00:10');
    await _enter(tester, 1, '00:18');
    await _apply(tester);
    expect(notifier.saved.single, (startMs: 10000, endMs: 18000));
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('Enter commits both drafts outside the initial slider window', (
    tester,
  ) async {
    final notifier = _RangeNotifier(start: 60000, end: 70000);
    await _pump(tester, notifier);
    await _open(tester);
    await _enter(tester, 0, '00:10');
    await _enter(tester, 1, '02:00', submit: true);
    final timeline = tester.widget<ClipRangeTimeline>(
      find.byType(ClipRangeTimeline),
    );
    expect((timeline.startMs, timeline.endMs), (10000, 120000));
    expect(timeline.windowStartMs, lessThanOrEqualTo(10000));
    expect(timeline.windowEndMs, greaterThanOrEqualTo(120000));
    await _apply(tester);
    expect(notifier.saved.single, (startMs: 10000, endMs: 120000));
  });

  testWidgets(
    'restore default after reopening discards the saved manual range',
    (tester) async {
      final notifier = _RangeNotifier(start: 6000, end: 15000);
      await _pump(tester, notifier);
      await _open(tester);
      await _enter(tester, 0, '00:08');
      await _enter(tester, 1, '00:12');
      await _apply(tester);
      await _open(tester);
      await tester.ensureVisible(find.text('恢复默认'));
      await tester.tap(find.text('恢复默认'));
      await _apply(tester);
      expect(notifier.saved.last, (startMs: 6000, endMs: 15000));
    },
  );

  for (final invalid in ['bad', '-1', '00:-1', '00:80', '00:16', '03:01']) {
    testWidgets('invalid range $invalid remains editable and is not saved', (
      tester,
    ) async {
      final notifier = _RangeNotifier();
      await _pump(tester, notifier);
      await _open(tester);
      await _enter(tester, 0, invalid);
      await _apply(tester);
      expect(find.byType(Dialog), findsOneWidget);
      expect(notifier.saved, isEmpty);
      expect(find.text('请输入有效时间：范围须在视频内，且时长至少为 1 秒。'), findsOneWidget);
      await _enter(tester, 0, '00:15');
      await _apply(tester);
      expect(notifier.saved.single, (startMs: 15000, endMs: 16000));
    });
  }

  testWidgets('unchanged inputs preserve millisecond precision', (
    tester,
  ) async {
    final notifier = _RangeNotifier(start: 8123, end: 16456);
    await _pump(tester, notifier);
    await _open(tester);
    await _apply(tester);
    expect(notifier.saved.single, (startMs: 8123, endMs: 16456));
  });

  testWidgets('quick extend and nudges lengthen a cut-off clip', (
    tester,
  ) async {
    final notifier = _RangeNotifier();
    await _pump(tester, notifier);
    await _open(tester);
    Future<void> tap(String key) async {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    await tap('clip-range-extend-end');
    await tap('clip-range-end-nudge-500');
    await tap('clip-range-start-nudge--1000');
    final timeline = tester.widget<ClipRangeTimeline>(
      find.byType(ClipRangeTimeline),
    );
    expect(timeline.originalEndMs, 16000);
    await _apply(tester);
    expect(notifier.saved.single, (startMs: 7000, endMs: 18500));
  });

  testWidgets('extending both sides widens the axis beyond the old window', (
    tester,
  ) async {
    final notifier = _RangeNotifier(start: 60000, end: 70000);
    await _pump(tester, notifier);
    await _open(tester);
    final both = find.byKey(const ValueKey('clip-range-extend-both'));
    await tester.ensureVisible(both);
    for (var i = 0; i < 10; i++) {
      await tester.tap(both);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final timeline = tester.widget<ClipRangeTimeline>(
      find.byType(ClipRangeTimeline),
    );
    expect((timeline.startMs, timeline.endMs), (40000, 90000));
    expect(timeline.windowStartMs, lessThanOrEqualTo(40000));
    expect(timeline.windowEndMs, greaterThanOrEqualTo(90000));
    await _apply(tester);
    expect(notifier.saved.single, (startMs: 40000, endMs: 90000));
  });

  for (final duration in [null, 0, 500]) {
    testWidgets('missing video duration $duration still opens range editor', (
      tester,
    ) async {
      final notifier = _RangeNotifier(durationMs: duration);
      await _pump(tester, notifier);
      await _open(tester);
      expect(tester.takeException(), isNull);
      await _apply(tester);
      expect(notifier.saved.single, (startMs: 8000, endMs: 16000));
    });
  }

  testWidgets('system key combos do not trigger review shortcuts', (
    tester,
  ) async {
    final notifier = _RangeNotifier();
    await _pump(tester, notifier);
    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
    ]) {
      for (final key in [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyX]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
      }
    }
    expect(notifier.reviews, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(notifier.reviews, ['excluded']);
  });

  testWidgets('range modal opens directly and closes on cancel', (tester) async {
    await _pump(tester, _RangeNotifier());
    await tester.tap(find.byTooltip('调整片段范围'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
