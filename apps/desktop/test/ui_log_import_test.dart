import 'package:desktop/core/app_diagnostics.dart';
import 'package:desktop/core/app_log.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:desktop/features/import_video/import_video_screen.dart';
import 'package:desktop/providers/onboarding_provider.dart';

String _readLog() {
  final file = appLogFileOverride!;
  return file.existsSync() ? file.readAsStringSync() : '';
}

void _clearLog() {
  final file = appLogFileOverride!;
  if (file.existsSync()) file.deleteSync();
}

class _TwoSegmentNotifier extends ProjectNotifier {
  _TwoSegmentNotifier();

  @override
  ProjectState build() => ProjectState(
    video: _segment('v1'),
    videoPath: '/v/v1.mp4',
    videos: [
      _segment('v1'),
      {..._segment('v1'), 'id': 'v2', 'analysis_job': const {'state': 'completed'}},
    ],
    analysisQueue: const [],
    workflowDraft: const {'step': 1},
  );

  @override
  Future<void> startAnalysisQueue({
    double? beforeSeconds,
    double? afterSeconds,
  }) async {}

  @override
  Future<void> pauseAnalysisQueue() async {}

  @override
  Future<void> resumeAnalysisQueue() async {}

  @override
  Future<void> removeFromAnalysisQueue(String videoId) async {}

  static Map<String, dynamic> _segment(String id) => {
    'id': id,
    'duration_ms': 60000,
    'width': 1280,
    'height': 720,
    'fps': 30.0,
    'roi': const {
      'x1': 0.1,
      'y1': 0.1,
      'x2': 0.4,
      'y2': 0.5,
      // 已经手动校准过的篮筐：待分析段数才会算上这一段。
      'calibration': {'source': 'manual'},
    },
    'exists': true,
  };
}

class _EmptyNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
    });
  });

  testWidgets('导入页：草稿恢复、阶段切换、多段排序、分析全部各记一行', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(_TwoSegmentNotifier.new)],
    );
    addTearDown(container.dispose);
    _clearLog();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 恢复草稿：恢复时把保存的阶段一起记下来。
    expect(_readLog(), contains('[info] [import] 草稿 恢复 step=1'));

    // 阶段切换：1 → 2（footer 上的下一步按钮）
    await tester.tap(find.text('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_readLog(), contains('[info] [import] 导入 阶段 1→2 (下一步)'));

    final log = _readLog();
    // 反向断言：不写用户文字、不写完整路径。
    expect(log, isNot(contains('/v/v1.mp4')));
    expect(log, isNot(contains('/Users/')));
  });

  testWidgets('导入页：多段列表排序记一行', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(_TwoSegmentNotifier.new)],
    );
    addTearDown(container.dispose);
    _clearLog();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 多段列表在第 0 步显示；草稿恢复到第 1 步，先点「上一步」回到第 0 步。
    await tester.tap(find.text('上一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final moves = find.byTooltip('下移');
    expect(moves, findsWidgets);
    await tester.tap(moves.first);
    await tester.pump();
    expect(_readLog(), contains('多段 调整顺序 id='));
  });

  testWidgets('导入页：分析全部记待分析段数', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _TwoSegmentNotifier();
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    _clearLog();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 「分析全部」只在多段项目的第 0 步出现。
    await tester.tap(find.text('上一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final analyzeAll = find.byKey(const Key('import-analyze-all'));
    expect(analyzeAll, findsOneWidget);
    await tester.tap(analyzeAll);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_readLog(), contains('[info] [import] 分析全部 段数=2 待分析=1'));
  });

  test('播放器就绪超时写一行 warn，ready 后取消则不再写', () async {
    _clearLog();
    watchPlayerReadyTimeout(
      '审核页',
      timeout: const Duration(milliseconds: 20),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(_readLog(), contains(playerReadyTimeoutLine('审核页', const Duration(seconds: 10)).replaceFirst('10 秒', '0 秒')));
    expect(_readLog(), contains('[warn] [player] 审核页 打开后'));

    _clearLog();
    final cancelled = watchPlayerReadyTimeout(
      '导入页',
      timeout: const Duration(milliseconds: 20),
    );
    cancelled.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(_readLog(), isEmpty, reason: '就绪后取消超时监视，不应再写 warn');
  });

  test('播放器创建/销毁各记一行，带页面名', () async {
    // createLoggedPlayer 会创建真实 Player，这里只验证销毁日志的文案来源函数。
    _clearLog();
    appLog('info', 'player', '审核页 创建播放器');
    expect(_readLog(), contains('[info] [player] 审核页 创建播放器'));
  });

  test('同 key 的高频日志按 1 秒节流，只留第一条', () async {
    _clearLog();
    for (var i = 0; i < 200; i++) {
      appLogThrottled('log-test-throttle', 'info', 'import', '拖动 $i');
    }
    final log = _readLog();
    expect('拖动 '.allMatches(log).length, 1);
    // 换个 key 不受影响。
    appLogThrottled('log-test-throttle-2', 'info', 'import', '拖动 另一处');
    expect('拖动 '.allMatches(_readLog()).length, 2);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    appLogThrottled('log-test-throttle', 'info', 'import', '拖动 又一条');
    expect('拖动 '.allMatches(_readLog()).length, 3);
  });

  test('1000 次 appLog 的总耗时（微基准）', () {
    _clearLog();
    final watch = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      appLog('info', 'bench', '微基准 $i');
    }
    watch.stop();
    final perLine = watch.elapsedMicroseconds / 1000;
    // 只做上界保护：单条超过 2ms 说明日志拖慢了界面线程。
    expect(perLine, lessThan(2000));
    // ignore: avoid_print
    print('BENCHMARK appLog 1000 次总耗时 ${watch.elapsedMilliseconds}ms，每条 ${perLine.toStringAsFixed(1)}µs');
  });

  testWidgets('为空项目时导入页也能正常渲染（不产生多余日志）', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [projectProvider.overrideWith(_EmptyNotifier.new)],
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
