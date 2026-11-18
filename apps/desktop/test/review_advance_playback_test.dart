import 'dart:io';
import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'tiers_ui_test.dart' as harness;

// Actual ReviewScreen media queue, with a real Player facade and no native texture.
class MemoryPlayback extends PlatformPlayer {
  MemoryPlayback() : super(configuration: const PlayerConfiguration());
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    state = state.copyWith(
      duration: const Duration(minutes: 10),
      playing: play,
    );
  }

  @override
  Future<void> stop() async {
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> seek(Duration position) async {
    state = state.copyWith(position: position);
  }
}

class MultiProject extends harness.FakeProject {
  @override
  void activateVideo(String videoId) {
    final video = state.videos.firstWhere((v) => v['id'] == videoId);
    state = state.copyWith(video: video, videoPath: video['source_path'] as String);
  }
  void completeAnalysis() {
    state = state.copyWith(analysisResultRevision: state.analysisResultRevision + 1);
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
      'courtside.sidebar_extended': false,
    }),
  );
  Future<MemoryPlayback> launch(
    WidgetTester tester,
    harness.FakeProject n,
  ) async {
    final dir = Directory.systemTemp.createTempSync('bhe-review-widget-');
    final file = File('${dir.path}/synthetic.mp4');
    file.writeAsBytesSync([0]);
    addTearDown(() => dir.deleteSync(recursive: true));
    n.initial = n.initial.copyWith(
      video: {'id': 'v1', 'source_path': file.path},
      videoPath: file.path,
      reviewVideoPath: file.path,
    );
    final p = MemoryPlayback();
    await harness.pump(
      tester,
      n,
      reviewScreen: ReviewScreen(playbackPlayer: Player(platformPlayer: p)),
    );
    expect(p.state.playing, isFalse);
    return p;
  }

  harness.FakeProject project(
    String tier, {
    bool collapsed = false,
    bool reviewedMiddle = false,
  }) {
    final n = harness.FakeProject();
    n.initial = harness.fixture().copyWith(
      candidates: [
        for (final i in [3, 4, 5])
          {
            ...harness.fixture().candidates[i],
            'tier': tier,
            'review_status': reviewedMiddle && i == 4
                ? 'goal'
                : tier == 'excluded'
                ? 'excluded'
                : 'pending',
            'review_reason': tier == 'excluded' && !(reviewedMiddle && i == 4)
                ? 'auto_rim_check'
                : null,
            'likely_miss': collapsed && i == 5,
          },
      ],
    );
    return n;
  }

  for (final tier in ['must', 'suspect', 'excluded', 'all']) {
    testWidgets(
      'mark advances in $tier, skips reviewed rows, undo restores row and status',
      (tester) async {
        final n = project(
          tier == 'all' ? 'suspect' : tier,
          reviewedMiddle: true,
        );
        final p = await launch(tester, n);
        await tester.tap(find.byKey(ValueKey('review-status-$tier')));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.pumpAndSettle();
        expect(n.current.candidates.first['review_status'], 'goal');
        expect(find.text('候选 00:54'), findsOneWidget);
        expect(p.state.position.inMilliseconds, 45000);
        expect(p.state.playing, isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pumpAndSettle();
        expect(find.text('候选 00:36'), findsOneWidget);
        expect(
          n.current.candidates.first['review_status'],
          tier == 'excluded' ? 'excluded' : 'pending',
        );
        expect(p.state.playing, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('mark skips collapsed group and last mark stays put and pauses', (
    tester,
  ) async {
    final n = project('suspect', collapsed: true);
    final p = await launch(tester, n);
    await tester.tap(find.byKey(const Key('inspector-keep')));
    await tester.pumpAndSettle();
    expect(find.text('候选 00:45'), findsOneWidget);
    expect(p.state.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await tester.pumpAndSettle();
    expect(find.text('候选 00:45'), findsOneWidget);
    expect(find.text('本页已审完'), findsOneWidget);
    expect(p.state.playing, isFalse);
    expect(n.current.candidates.last['review_status'], 'pending');
    expect(find.byKey(const ValueKey('candidate-row-c5')), findsNothing);
  });
  testWidgets('filters source and group pause, clicks and S play', (
    tester,
  ) async {
    final n = project('suspect', collapsed: true);
    final p = await launch(tester, n);
    await tester.tap(find.byKey(const ValueKey('tier-dot-c4')));
    await tester.pumpAndSettle();
    expect(p.state.playing, isTrue);
    await tester.tap(find.byKey(const ValueKey('review-tag-option-untagged')));
    await tester.pumpAndSettle();
    expect(p.state.playing, isFalse);
    await tester.tap(find.byKey(const ValueKey('review-tag-option-all')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(p.state.playing, isTrue);
    await tester.tap(find.text('原视频').first);
    await tester.pumpAndSettle();
    expect(p.state.playing, isFalse);
    await tester.tap(find.byKey(const Key('review-likely-miss-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tier-dot-c5')));
    await tester.pumpAndSettle();
    expect(p.state.playing, isTrue);
    await tester.tap(find.byKey(const Key('review-likely-miss-group')));
    await tester.pumpAndSettle();
    expect(p.state.playing, isFalse);
    expect(find.text('候选 00:36'), findsOneWidget);
    expect(p.state.position.inMilliseconds, 27000);
  });
  testWidgets('explicit next plays across video activation; analysis completion still pauses', (tester) async {
    final n = MultiProject();
    final p = await launch(tester, n);
    final current = n.current;
    // Distinct files exercise stop/open across actual source-path changes.
    final second = File('${File(current.videoPath!).parent.path}/second.mp4')..writeAsBytesSync([0]);
    n.initial = current;
    final videos = [
      {...current.video!, 'id': 'v1'},
      {...current.video!, 'id': 'v2', 'source_path': second.path},
    ];
    await tester.pumpWidget(const SizedBox());
    // A new notifier is required because Notifier instances belong to containers.
    final multi = MultiProject();
    multi.initial = current.copyWith(videos: videos, candidates: [
      for (final i in [3, 4]) {...harness.fixture().candidates[i],
        'video_id': i == 3 ? 'v1' : 'v2', 'segment': i == 3 ? 1 : 2},
    ]);
    final player = MemoryPlayback();
    await harness.pump(tester, multi, reviewScreen: ReviewScreen(playbackPlayer: Player(platformPlayer: player)));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(multi.current.video?['id'], 'v2');
    expect(find.text('第 2 段 · 00:45'), findsOneWidget);
    expect(player.state.playing, isTrue);
    expect(player.state.position.inMilliseconds, 36000);
    multi.completeAnalysis();
    await tester.pumpAndSettle();
    expect(player.state.playing, isFalse);
    expect(player.state.position.inMilliseconds, 36000);
    expect(p.state.playing, isFalse);
  });

}
