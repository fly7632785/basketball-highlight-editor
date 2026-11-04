import 'dart:async';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/features/import_video/hoop_example.dart';
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:desktop/providers/pending_import_provider.dart';
import 'package:desktop/components/cs_button.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:desktop/features/import_video/import_video_screen.dart';

void main() {
  // 默认当作已看过引导，免得遮罩挡住别的用例；引导本身在专门的用例里测。
  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
    }),
  );
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

  testWidgets('import stage 0 guides the first visit and remembers each step', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(() => _DropNotifier())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('导入分四步'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pump();
    await tester.pump();
    expect(find.text('先选原始视频'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pump();
    expect(find.byKey(const Key('onboarding-overlay')), findsNothing);
    expect(
      container.read(onboardingProvider).seen,
      {'import.steps', 'import.pick'},
    );
  });

  testWidgets('range stage shows only its own guide step', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(() => _RangeNotifier(const Size(1920, 1080))),
        ],
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('只分析需要的一段'), findsOneWidget);
    expect(find.text('导入分四步'), findsNothing);
    expect(find.text('1/1'), findsOneWidget);
  });

  for (final language in ['zh', 'en']) {
    testWidgets('detection area guide has two localized illustrated steps: $language', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(language == 'en' ? 1440 : 1200, language == 'en' ? 900 : 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [projectProvider.overrideWith(() => _RoiGuideNotifier())],
        child: MaterialApp(
          locale: Locale(language),
          localizationsDelegates: BheLocalizations.localizationsDelegates,
          supportedLocales: BheLocalizations.supportedLocales,
          home: const Scaffold(body: ImportVideoScreen()),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text(language == 'zh' ? '先框投篮分析区（橙色）' : 'First: shot analysis area (orange)'), findsOneWidget);
      expect(find.text('框出篮筐'), findsNothing);
      expect(find.textContaining(language == 'zh' ? '橙色框覆盖球靠近篮圈上方' : 'The orange box covers the entire ball path'), findsOneWidget);
      await tester.runAsync(() async {
        final context = tester.element(find.byType(HoopExampleGallery));
        for (final example in HoopExample.values) {
          await precacheImage(AssetImage(example.asset), context);
        }
      });
      await tester.pump();
      for (final example in shotExamples) {
        expect(find.byKey(ValueKey('hoop-example-${example.name}')), findsOneWidget);
        expect(tester.getSize(find.byKey(ValueKey('hoop-example-${example.name}'))).width, greaterThanOrEqualTo(220));
      }
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pump();
      expect(find.text(language == 'zh' ? '再框篮网检测区（白色）' : 'Next: net detection area (white)'), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '点下面的「篮网检测区」按钮' : 'Click the Net detection area button'), findsOneWidget);
      for (final example in netExamples) {
        expect(find.byKey(ValueKey('hoop-example-${example.name}')), findsOneWidget);
      }
      if (language == 'en') {
        final overlay = find.byKey(const Key('onboarding-overlay'));
        final texts = tester.widgetList<Text>(find.descendant(of: overlay, matching: find.byType(Text)));
        expect(texts.where((text) => RegExp(r'[\u4e00-\u9fff]').hasMatch(text.data ?? '')), isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelling the file picker does not create a project', (tester) async {
    final previous = FileSelectorPlatform.instance;
    final selector = _CancelledSelector();
    FileSelectorPlatform.instance = selector;
    addTearDown(() => FileSelectorPlatform.instance = previous);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _DropNotifier();
    final container = ProviderContainer(overrides: [projectProvider.overrideWith(() => notifier)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CsButton, '选择视频'));
    await tester.pumpAndSettle();
    expect(selector.calls, 1);
    expect(notifier.selectedPaths, isEmpty);
  });

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

  testWidgets('缺失段显示重新定位按钮，点击后激活该段再走重新定位', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _MissingSourceNotifier();
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

    expect(find.text('原视频已移动'), findsOneWidget);
    final relink = find.byKey(const ValueKey('video-segment-relink-v2'));
    expect(relink, findsOneWidget);
    expect(
      find.byKey(const ValueKey('video-segment-relink-v1')),
      findsNothing,
      reason: '源视频正常的段不应有重新定位按钮',
    );

    await tester.tap(relink);
    await tester.pump();
    expect(notifier.activated, ['v2']);
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

  Future<_QueueNotifier> pumpQueueApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _QueueNotifier();
    final router = GoRouter(
      initialLocation: '/import',
      routes: [
        GoRoute(
          path: '/import',
          builder: (_, _) => const Scaffold(body: ImportVideoScreen()),
        ),
        GoRoute(path: '/review', builder: (_, _) => const Text('review page')),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-analyze-all')));
    await tester.pumpAndSettle();
    return notifier;
  }

  testWidgets('multi-video analysis goes to the review page when all parts finish', (
    tester,
  ) async {
    final notifier = await pumpQueueApp(tester);
    expect(find.text('review page'), findsNothing);
    notifier.finishQueue();
    await tester.pumpAndSettle();
    expect(find.text('review page'), findsOneWidget);
  });

  testWidgets('multi-video analysis does not jump while a dialog is open', (
    tester,
  ) async {
    final notifier = await pumpQueueApp(tester);
    final context = tester.element(find.byType(ImportVideoScreen));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('正在操作的弹窗')),
      ),
    );
    await tester.pumpAndSettle();
    notifier.finishQueue();
    await tester.pumpAndSettle();
    expect(find.text('review page'), findsNothing);
    expect(find.text('正在操作的弹窗'), findsOneWidget);
  });

  testWidgets('multi-video analysis stays on import when every part failed', (
    tester,
  ) async {
    final notifier = await pumpQueueApp(tester);
    notifier.finishQueue(completed: false);
    await tester.pumpAndSettle();
    expect(find.text('review page'), findsNothing);
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

class _RoiGuideNotifier extends ProjectNotifier {
  @override
  ProjectState build() => ProjectState(
    video: {'id': 'v1', 'duration_ms': 60000, 'width': 1920, 'height': 1080},
    workflowDraft: const {'step': 2},
  );
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

class _MissingSourceNotifier extends ProjectNotifier {
  final activated = <String>[];

  @override
  ProjectState build() => ProjectState(
    video: _missingSegment('v1', true),
    videoPath: '/v/v1.mp4',
    videos: [
      ..._missingSegmentWithRoi('v1'),
      ..._missingSegmentWithRoi('v2', exists: false),
    ],
  );

  static Map<String, dynamic> _missingSegment(String id, bool exists) => {
    'id': id,
    'source_path': '/v/$id.mp4',
    'source_exists': exists,
    'duration_ms': 300000,
    'width': 1920,
    'height': 1440,
  };

  static List<Map<String, dynamic>> _missingSegmentWithRoi(
    String id, {
    bool exists = true,
  }) => [
    {
      ..._missingSegment(id, exists),
      'roi': {
        'x1': 700,
        'y1': 300,
        'x2': 1260,
        'y2': 1000,
        'calibration': {'source': 'manual'},
      },
    },
  ];

  @override
  Future<Map<String, dynamic>?> loadWorkflowDraft() async => null;

  @override
  void activateVideo(String videoId) => activated.add(videoId);
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

class _QueueNotifier extends _SegmentsNotifier {
  @override
  Future<void> startAnalysisQueue({
    required double beforeSeconds,
    required double afterSeconds,
  }) async {
    state = state.copyWith(analysisQueue: ['v2', 'v3']);
  }

  /// 模拟整条队列跑完：队列清空、各段已完成、完成计数加一。
  void finishQueue({bool completed = true}) {
    state = state.copyWith(
      analysisQueue: const [],
      videos: [
        for (final video in state.videos)
          {...video, 'analysis_job': {'state': completed ? 'completed' : 'failed'}},
      ],
      queueFinishedCount: state.queueFinishedCount + 1,
      lastQueueAllCompleted: completed,
    );
  }
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

class _CancelledSelector extends FileSelectorPlatform {
  int calls = 0;
  @override
  Future<List<XFile>> openFiles({List<XTypeGroup>? acceptedTypeGroups, String? initialDirectory, String? confirmButtonText}) async {
    calls++;
    return [];
  }
}
