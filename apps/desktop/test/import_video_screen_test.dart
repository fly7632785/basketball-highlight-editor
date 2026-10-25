import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:desktop/providers/pending_import_provider.dart';
import 'package:desktop/providers/project_state.dart';

import 'package:desktop/features/import_video/import_video_screen.dart';

void main() {
  for (final frame in [
    const Size(1440, 1080),
    const Size(1920, 1080),
    const Size(1080, 1920),
  ]) {
    testWidgets('analysis range preview follows source ratio $frame', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            projectProvider.overrideWith(() => _RangeNotifier(frame)),
          ],
          child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final preview = find.byKey(const Key('analysis-range-video-frame'));
      expect(preview, findsOneWidget);
      final size = tester.getSize(preview);
      expect(size.aspectRatio, closeTo(frame.aspectRatio, 0.001));
      // Tall sources must not push the timeline and footer off screen.
      expect(size.height, lessThanOrEqualTo(440));
      expect(size.width, greaterThan(frame.aspectRatio > 1 ? 500 : 200));
      expect(
        tester.getRect(find.byKey(const Key('import-footer'))).bottom,
        lessThanOrEqualTo(700),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('imports a video dropped on the home screen', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _DropNotifier();
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(pendingImportProvider.notifier).set(['/v/game.MP4']);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(notifier.selectedPaths, ['/v/game.MP4']);
    expect(container.read(pendingImportProvider), isNull);
  });

  testWidgets('lists every segment of a multi-video project and queues them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _SegmentsNotifier();
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    await tester.pumpAndSettle();

    for (final id in ['v1', 'v2', 'v3']) {
      expect(find.byKey(ValueKey('video-segment-$id')), findsOneWidget);
    }
    expect(find.text('已完成 · 12 个候选'), findsOneWidget);
    expect(find.text('沿用上一段的篮筐'), findsOneWidget);
    expect(find.text('需要设置篮筐'), findsOneWidget);
    expect(find.text('分析全部（1）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('import-analyze-all')));
    await tester.pump();
    expect(notifier.queued, [(3.0, 1.0)]);

    await tester.tap(find.byKey(const ValueKey('video-segment-edit-v3')));
    await tester.pump();
    expect(notifier.edited, ['v3']);
  });

  testWidgets('several dropped videos become one project', (tester) async {
    final notifier = _SegmentsNotifier();
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(pendingImportProvider.notifier).set(['/v/a.mp4', '/v/b.mp4']);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(notifier.dropped, [
      ['/v/a.mp4', '/v/b.mp4'],
    ]);
  });

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

class _RangeNotifier extends ProjectNotifier {
  _RangeNotifier(this.frame);
  final Size frame;

  @override
  ProjectState build() => ProjectState(
    video: {
      'id': 'v1',
      'duration_ms': 60000,
      'width': frame.width,
      'height': frame.height,
    },
    workflowDraft: const {'step': 1},
  );
}

class _SegmentsNotifier extends ProjectNotifier {
  final queued = <(double, double)>[];
  final edited = <String>[];
  final dropped = <List<String>>[];

  @override
  ProjectState build() => ProjectState(
    video: _segment('v1'),
    videoPath: '/v/v1.mp4',
    videos: [
      {..._segment('v1'), 'roi': _roi('manual'), 'analysis_job': {'state': 'completed'}, 'candidate_count': 12},
      {..._segment('v2'), 'roi': _roi('reused'), 'analysis_job': null, 'candidate_count': 0},
      {..._segment('v3'), 'roi': null, 'analysis_job': null, 'candidate_count': 0},
    ],
  );

  static Map<String, dynamic> _segment(String id) => {
    'id': id,
    'source_path': '/v/$id.mp4',
    'source_exists': true,
    'duration_ms': 300000,
    'width': 1920,
    'height': 1440,
  };

  static Map<String, dynamic> _roi(String source) => {
    'x1': 700,
    'y1': 300,
    'x2': 1260,
    'y2': 1000,
    'calibration': {'source': source},
  };

  @override
  Future<Map<String, dynamic>?> loadWorkflowDraft() async => null;

  @override
  Future<void> createProjectFromVideos(List<String> paths) async =>
      dropped.add(paths);

  @override
  Future<void> startAnalysisQueue({
    required double beforeSeconds,
    required double afterSeconds,
  }) async => queued.add((beforeSeconds, afterSeconds));

  @override
  void activateVideo(String videoId) => edited.add(videoId);
}

class _DropNotifier extends ProjectNotifier {
  final selectedPaths = <String>[];

  @override
  ProjectState build() => const ProjectState();

  @override
  Future<Map<String, dynamic>?> loadWorkflowDraft() async => null;

  @override
  Future<void> selectVideo(String path) async => selectedPaths.add(path);
}
