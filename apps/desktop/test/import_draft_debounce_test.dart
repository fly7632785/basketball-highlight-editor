import 'dart:async';

import 'package:desktop/core/draft_flush_registry.dart';
import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/features/import_video/import_video_screen.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录草稿保存调用，可让保存挂起（模拟在途）或失败一次。
class _DraftNotifier extends ProjectNotifier {
  final saves = <Map<String, dynamic>>[];
  Completer<void>? gate;
  bool failNextSave = false;

  ProjectState? initialState;

  @override
  ProjectState build() => initialState ?? _defaultState();

  ProjectState _defaultState() => ProjectState(
    video: {
      'id': 'v1',
      'duration_ms': 60000,
      'width': 1920,
      'height': 1080,
      'source_path': '/v/v1.mp4',
      'analysis_start_ms': 0,
      'analysis_end_ms': 60000,
    },
    // 直接落在确认页（step 3），那里有能连续点击的秒数加减。
    workflowDraft: const {
      'step': 3,
      'roi': {'x1': 100, 'y1': 100, 'x2': 900, 'y2': 900},
      'before_seconds': 3,
      'after_seconds': 1,
    },
  );


  /// 多段项目：两段视频，让最后一步出现「保存这一段的设置」。
  static ProjectState multiVideoState() => ProjectState(
    video: const {
      'id': 'v1',
      'duration_ms': 60000,
      'width': 1920,
      'height': 1080,
      'source_path': '/v/v1.mp4',
      'analysis_start_ms': 0,
      'analysis_end_ms': 60000,
    },
    videos: const [
      {
        'id': 'v1',
        'duration_ms': 60000,
        'source_path': '/v/v1.mp4',
        'analysis_start_ms': 0,
        'analysis_end_ms': 60000,
      },
      {
        'id': 'v2',
        'duration_ms': 30000,
        'source_path': '/v/v2.mp4',
        'analysis_start_ms': 0,
        'analysis_end_ms': 30000,
      },
    ],
    workflowDraft: const {
      'step': 3,
      'roi': {'x1': 100, 'y1': 100, 'x2': 900, 'y2': 900},
      'before_seconds': 3,
      'after_seconds': 1,
    },
  );

  int applyCalls = 0;

  @override
  Future<bool> applyWorkflowDraft(Map<String, dynamic> draft) async {
    applyCalls++;
    return true;
  }

  @override
  Future<void> propagateHoopToFollowingParts(String videoId) async {}

  @override
  Future<void> clearWorkflowDraft() async {
    clearCalls++;
  }

  int clearCalls = 0;

  /// 模拟切换当前视频（草稿只在同一个视频里有效）。给一个没有路径的视频，
  /// 免得页面去起真实播放器。
  void switchVideo(String id) {
    state = state.copyWith(
      video: {'id': id, 'duration_ms': 30000},
      videoPath: null,
    );
  }

  @override
  Future<Map<String, dynamic>?> loadWorkflowDraft() async => null;

  @override
  Future<void> saveWorkflowDraft(Map<String, dynamic> draft) async {
    saves.add(Map<String, dynamic>.from(draft));
    final pending = gate;
    if (pending != null) await pending.future;
    if (failNextSave) {
      failNextSave = false;
      throw StateError('引擎写盘失败');
    }
  }
}

/// 不真的连引擎：日志/草稿相关调用都不会落到这里。
class _SilentTransport implements EngineTransport {
  @override
  Future<Map<String, dynamic>> request(
    String command,
    Map<String, dynamic> payload,
  ) async => <String, dynamic>{};
}

/// 可控的项目会话：`restore` 模拟切项目/切视频，脚本据它判断草稿归属。
ProjectSession _fakeSession({String? projectId, String? videoId}) =>
    ProjectSession(EngineSession(_SilentTransport()))
      ..restore(
        ProjectSessionCheckpoint(
          projectRoot: projectId == null ? null : '/projects/$projectId',
          projectId: projectId,
          videoId: videoId,
        ),
      );

Finder _increase(String selector) => find.descendant(
  of: find.byKey(Key(selector)),
  matching: find.byKey(const ValueKey('increase')),
);

int _shownSeconds(WidgetTester tester, String selector) {
  final text = tester
      .widgetList<Text>(
        find.descendant(of: find.byKey(Key(selector)), matching: find.byType(Text)),
      )
      .map((widget) => widget.data ?? '')
      .firstWhere((data) => data.contains('秒'));
  return int.parse(RegExp(r'\d+').firstMatch(text)!.group(0)!);
}

Future<(_DraftNotifier, ProviderContainer)> _pumpImport(
  WidgetTester tester, {
  _DraftNotifier? notifier,
  ProjectSession? session,
}) async {
  SharedPreferences.setMockInitialValues({
    onboardingStepsPrefsKey: allOnboardingStepIds,
  });
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = notifier ?? _DraftNotifier();
  final container = ProviderContainer(
    overrides: [
      projectProvider.overrideWith(() => fake),
      if (session != null) projectSessionProvider.overrideWithValue(session),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return (fake, container);
}

void main() {
  testWidgets('快速连续改动只保存少数几次，最后保存的是最新内容', (tester) async {
    final (notifier, _) = await _pumpImport(tester);
    for (var i = 0; i < 50; i++) {
      await tester.tap(_increase('clip-before'), warnIfMissed: false);
      await tester.pump();
    }
    final latest = _shownSeconds(tester, 'clip-before');
    // 去抖窗口内不该发保存请求。
    expect(notifier.saves, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves.length, lessThanOrEqualTo(3));
    expect(notifier.saves.last['before_seconds'], latest);
  });

  testWidgets('切步骤立即保存并等待完成，不丢未落盘的改动', (tester) async {
    final (notifier, _) = await _pumpImport(tester);
    await tester.tap(_increase('clip-after'), warnIfMissed: false);
    await tester.pump();
    final latest = _shownSeconds(tester, 'clip-after');
    expect(notifier.saves, isEmpty);

    // 回上一步：这一步是离散操作，必须马上保存，不能等去抖。
    await tester.tap(find.textContaining('上一步').last);
    await tester.pump();
    expect(notifier.saves, isNotEmpty);
    expect(notifier.saves.last['after_seconds'], latest);
    expect(notifier.saves.last['step'], 2);
  });

  testWidgets('保存在途时的新改动不会被丢掉', (tester) async {
    final notifier = _DraftNotifier();
    final (fake, _) = await _pumpImport(tester, notifier: notifier);
    expect(fake, same(notifier));
    final gate = Completer<void>();
    notifier.gate = gate;

    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves.length, 1);
    final first = notifier.saves.last['before_seconds'];

    // 第一次保存还挂着，此时再改一次。
    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump();
    final latest = _shownSeconds(tester, 'clip-before');
    expect(latest, isNot(first));
    await tester.pump(const Duration(milliseconds: 500));
    // 同一时刻只能有一个保存在途，第二次改动要排队而不是并发发出去。
    expect(notifier.saves.length, 1);

    gate.complete();
    notifier.gate = null;
    await tester.pump();
    await tester.pump();
    expect(notifier.saves.length, 2);
    expect(notifier.saves.last['before_seconds'], latest);
  });

  testWidgets('保存失败会提示，且不会反复重试', (tester) async {
    final notifier = _DraftNotifier()..failNextSave = true;
    final (_, container) = await _pumpImport(tester, notifier: notifier);

    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves.length, 1);
    expect(
      container
          .read(noticeProvider)
          .any((notice) => notice.title.contains('配置草稿保存失败')),
      isTrue,
    );

    // 失败后仍能继续保存，但失败的那次不会自动重试。
    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves.length, 2);
  });

  testWidgets('多段「保存这一段的设置」后，到点的旧草稿不会再写一次', (tester) async {
    final notifier = _DraftNotifier()
      ..initialState = _DraftNotifier.multiVideoState();
    final (fake, _) = await _pumpImport(tester, notifier: notifier);
    expect(fake, same(notifier));

    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.byKey(const Key('import-save-segment')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(notifier.applyCalls, 1);
    final afterApply = notifier.saves.length;
    expect(notifier.saves.last['before_seconds'], 4);

    // 定时器到点：已应用并清除的草稿不能再被写回。
    await tester.pump(const Duration(seconds: 2));
    expect(notifier.saves.length, afterApply);
  });

  testWidgets('卸载页面时最新草稿接在在途保存后面写出，顺序正确', (tester) async {
    final (notifier, _) = await _pumpImport(tester);
    final gate = Completer<void>();
    notifier.gate = gate;

    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves.length, 1);

    // 旧保存还挂着时再改一次，然后离开页面。
    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();
    expect(notifier.saves.length, 1);

    gate.complete();
    notifier.gate = null;
    await tester.pump();
    await tester.pump();
    expect(notifier.saves.length, 2);
    expect(notifier.saves[0]['before_seconds'], 4);
    expect(notifier.saves[1]['before_seconds'], 5);
  });

  testWidgets('离开页面时保存失败会推全局通知', (tester) async {
    final notifier = _DraftNotifier()..failNextSave = true;
    final (_, container) = await _pumpImport(tester, notifier: notifier);
    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();
    await tester.pump();
    expect(notifier.saves.length, 1);
    expect(
      container
          .read(noticeProvider)
          .any((notice) => notice.title.contains('配置草稿保存失败')),
      isTrue,
    );
  });

  testWidgets('调度后切换视频，到点不写入旧会话', (tester) async {
    final session = _fakeSession(projectId: 'p1', videoId: 'v1');
    final (notifier, _) = await _pumpImport(tester, session: session);
    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump();
    // 真实切换视频会同时改状态和会话，这里两个都改。
    notifier.switchVideo('v2');
    session.restore(
      const ProjectSessionCheckpoint(
        projectRoot: '/projects/p1',
        projectId: 'p1',
        videoId: 'v2',
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves, isEmpty);
  });

  testWidgets('离页排队的旧草稿不会写进切换后的项目', (tester) async {
    final session = _fakeSession(projectId: 'p1', videoId: 'v1');
    final notifier = _DraftNotifier();
    await _pumpImport(tester, notifier: notifier, session: session);
    final gate = Completer<void>();
    notifier.gate = gate;

    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves.length, 1); // 属于 p1/v1 的保存在途

    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();
    expect(notifier.saves.length, 1); // 离页的那次排在后面

    // 换项目：会话身份变了，排队中的旧草稿不能再写。
    session.restore(
      const ProjectSessionCheckpoint(
        projectRoot: '/projects/p2',
        projectId: 'p2',
        videoId: 'v2',
      ),
    );
    gate.complete();
    notifier.gate = null;
    await tester.pump();
    await tester.pump();
    expect(notifier.saves.length, 1);
  });

  testWidgets('在途保存没完成时，应用草稿要等它结束', (tester) async {
    final notifier = _DraftNotifier()
      ..initialState = _DraftNotifier.multiVideoState();
    await _pumpImport(tester, notifier: notifier);
    final gate = Completer<void>();
    notifier.gate = gate;

    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(notifier.saves.length, 1);

    await tester.tap(find.byKey(const Key('import-save-segment')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(notifier.applyCalls, 0); // 保存还挂着，apply 不能先跑

    gate.complete();
    notifier.gate = null;
    await tester.pump();
    await tester.pump();
    expect(notifier.applyCalls, 1);
  });

  testWidgets('关闭应用前 flush 把待写草稿写出去', (tester) async {
    resetDraftFlushForTest();
    final (notifier, _) = await _pumpImport(tester);
    await tester.tap(_increase('clip-before'), warnIfMissed: false);
    await tester.pump();
    expect(notifier.saves, isEmpty);

    await flushDraftBeforeShutdown();
    await tester.pump();
    expect(notifier.saves.length, 1);
    expect(notifier.saves.single['before_seconds'], 4);
  });

  test('关闭前 flush 超时也放行退出', () async {
    resetDraftFlushForTest();
    var finished = false;
    registerDraftFlush(() async {
      await Future<void>.delayed(const Duration(seconds: 30));
      finished = true;
    });
    final watch = Stopwatch()..start();
    await flushDraftBeforeShutdown(timeout: const Duration(milliseconds: 50));
    watch.stop();
    expect(finished, isFalse);
    expect(watch.elapsedMilliseconds, lessThan(2000));
    resetDraftFlushForTest();
  });
}
