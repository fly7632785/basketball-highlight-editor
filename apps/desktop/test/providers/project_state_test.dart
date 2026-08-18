// test/providers/project_state_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show Rect;

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/engine_client.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/session_provider.dart';

void main() {
  test('将 ROI 后端错误转换成可操作提示', () {
    expect(
      userFacingNotice(
        const EngineException('ROI_INVALID', 'ROI_COORDINATES_INVALID'),
      ),
      (title: '检测区域无法保存', description: '请从左上向右下拖出一个有效矩形，再松开鼠标。'),
    );
    expect(
      userFacingNotice(
        const EngineException('ROI_INVALID', 'ROI_TOO_SMALL: 检测区域太小'),
      ),
      (title: '投篮分析区太小', description: '请扩大橙色区域，覆盖篮筐、篮网和球落下的位置。'),
    );
  });

  group('ProjectNotifier.selectVideo', () {
    test(
      '更新 videoPath/previewPath,自动 ROI 失败时记录 roiSuggestionError,push 成功 notice',
      () async {
        final fakeSession = _FakeProjectSession();
        final container = ProviderContainer(
          overrides: <Override>[
            projectSessionProvider.overrideWithValue(fakeSession),
            engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(projectProvider.notifier);
        await notifier.selectVideo('/path/sample.mp4');

        final state = container.read(projectProvider);
        expect(state.videoPath, '/path/sample.mp4');
        expect(state.previewPath, '/tmp/preview.jpg');
        expect(state.video?['id'], 'vid-1');
        // suggestRoi 默认抛错,selectVideo 内部捕获,不应阻塞导入。
        expect(state.roiSuggestionError, isNotNull);
        expect(state.roiSource, isNull);
        expect(state.candidates, isEmpty);
        // 成功 notice 已 push(取最后一条)。
        final notices = container.read(noticeProvider);
        expect(notices, isNotEmpty);
        expect(notices.last.severity, NoticeSeverity.success);
        expect(notices.last.title, contains('视频已加载'));
      },
    );

    test('创建视频项目后刷新最近项目列表', () async {
      final fakeSession = _FakeProjectSession()
        ..recentProjects = <JsonMap>[
          <String, dynamic>{
            'project_root': '/tmp/projects/sample-1',
            'project': <String, dynamic>{'name': 'sample'},
          },
        ];
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(projectProvider.notifier)
          .selectVideo('/path/sample.mp4');

      expect(fakeSession.loadRecentProjectsCalls, greaterThan(0));
      expect(
        container.read(projectProvider).recentProjects.single['project_root'],
        '/tmp/projects/sample-1',
      );
    });

    test('切换标记画面时显示处理提示', () async {
      final fakeSession = _FakeProjectSession()
        ..previewDelay = const Duration(milliseconds: 20);
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(projectProvider.notifier);
      await notifier.selectVideo('/tmp/sample.mp4');

      final refresh = notifier.refreshPreviewAt(5000);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(container.read(projectProvider).previewRefreshing, isTrue);
      expect(container.read(projectProvider).busyMessage, isNull);
      await refresh;
      expect(container.read(projectProvider).previewRefreshing, isFalse);
    });

    test('自动 ROI 返回最佳帧时更新标记画面时间', () async {
      final fakeSession = _FakeProjectSession()..returnRoiSuggestion = true;
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(projectProvider.notifier)
          .selectVideo('/path/sample.mp4');

      expect(container.read(projectProvider).previewTimeMs, 4000);
    });

    test('opening an invalid project keeps the current UI state', () async {
      final fakeSession = _FakeProjectSession();
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(projectProvider.notifier);
      await notifier.selectVideo('/path/current.mp4');
      fakeSession.throwOnOpenProject = true;

      await notifier.openProject('/path/invalid-project');

      final state = container.read(projectProvider);
      expect(state.videoPath, '/path/current.mp4');
      expect(state.video?['id'], 'vid-1');
      expect(
        container.read(noticeProvider).last.severity,
        NoticeSeverity.error,
      );
    });
  });

  test(
    'startAnalysis replaces a recoverable queued job when requested',
    () async {
      final fakeSession = _FakeProjectSession()
        ..activeAnalysisJobs = <JsonMap>[
          <String, dynamic>{
            'id': 'old-job',
            'state': 'queued',
            'recovery_state': 'queued_recoverable',
            'recoverable': true,
          },
        ]
        ..retryAnalysisResult = <String, dynamic>{
          'job': <String, dynamic>{'id': 'new-job', 'state': 'queued'},
        };
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final started = await container
          .read(projectProvider.notifier)
          .startAnalysis(replaceRecoverable: true);

      expect(started, isTrue);
      expect(fakeSession.retryAnalysisCalls, ['old-job']);
      expect(fakeSession.startAnalysisCalls, 0);
      expect(container.read(projectProvider).job?['id'], 'new-job');
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'retryAnalysis keeps the previous candidate result while the new job runs',
    () async {
      final fakeSession = _FakeProjectSession()..clearCandidatesOnRetry = true;
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectProvider.notifier);
      await notifier.startAnalysis();
      fakeSession.seedCandidates(<JsonMap>[
        <String, dynamic>{'id': 'old-candidate', 'review_status': 'goal'},
      ]);
      await notifier.refreshCandidates();
      expect(container.read(projectProvider).candidates, isNotEmpty);

      await notifier.retryAnalysis();

      final state = container.read(projectProvider);
      expect(state.job?['id'], 'retry-job');
      expect(state.candidates, isNotEmpty);
      expect(fakeSession.lastRetryBeforeSeconds, isNull);
      expect(fakeSession.lastRetryAfterSeconds, isNull);
    },
  );

  test('startAnalysis forwards the selected clip window', () async {
    final fakeSession = _FakeProjectSession();
    final container = ProviderContainer(
      overrides: <Override>[
        projectSessionProvider.overrideWithValue(fakeSession),
        engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(projectProvider.notifier)
        .startAnalysis(beforeSeconds: 5, afterSeconds: 4);

    expect(fakeSession.lastStartBeforeSeconds, 5);
    expect(fakeSession.lastStartAfterSeconds, 4);
  });

  test('retryAnalysis uses the mode persisted on the previous job', () async {
    final fakeSession = _FakeProjectSession()
      ..activeAnalysisJobs = <JsonMap>[
        <String, dynamic>{
          'id': 'old-job',
          'state': 'failed',
          'checkpoint': <String, dynamic>{'mode': 'fast'},
        },
      ]
      ..retryAnalysisResult = <String, dynamic>{
        'job': <String, dynamic>{'id': 'retry-job', 'state': 'queued'},
      };
    final container = ProviderContainer(
      overrides: <Override>[
        projectSessionProvider.overrideWithValue(fakeSession),
        engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(projectProvider.notifier);
    await notifier.startAnalysis();
    await notifier.retryAnalysis();

    expect(fakeSession.lastRetryMode, 'fast');
  });

  test(
    'engine transport failure makes a running analysis recoverable',
    () async {
      final fakeSession = _FakeProjectSession();
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(projectProvider.notifier);
      await notifier.startAnalysis();
      await Future<void>.delayed(Duration.zero);
      final scope = ProjectSessionScope(
        engine: EngineSession(_ThrowingTransport()),
        projectRoot: '/tmp/project',
        videoId: 'video-1',
      );

      await notifier.pollJob('start-job', scope: scope);

      final state = container.read(projectProvider);
      expect(state.analysisRunning, isFalse);
      expect(state.job?['recoverable'], isTrue);
      expect(state.job?['recovery_state'], 'stale_recoverable');
      expect(state.job?['error_code'], 'ENGINE_EXITED');
      expect(container.read(engineBootstrapProvider).hasError, isTrue);
    },
  );

  test('transport timeout restores an attached analysis worker', () async {
    final fakeSession = _FakeProjectSession();
    final container = ProviderContainer(
      overrides: <Override>[
        projectSessionProvider.overrideWithValue(fakeSession),
        engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(projectProvider.notifier);
    await notifier.startAnalysis();
    await Future<void>.delayed(Duration.zero);

    final scope = ProjectSessionScope(
      engine: EngineSession(_RecoveringTransport()),
      projectRoot: '/tmp/project',
      videoId: 'video-1',
    );
    await notifier.pollJob('start-job', scope: scope);
    await Future<void>.delayed(Duration.zero);

    final state = container.read(projectProvider);
    expect(state.job?['state'], 'completed');
    expect(state.job?['recoverable'], isNot(true));
    expect(state.job?['recovery_state'], isNull);
    expect(
      container
          .read(noticeProvider)
          .where((notice) => notice.title.contains('ENGINE_TIMEOUT'))
          .isEmpty,
      isTrue,
    );
  });

  test(
    'cancel analysis reports cancelling until the engine reaches terminal state',
    () async {
      final fakeSession = _FakeProjectSession()
        ..cancelJobResult = <String, dynamic>{
          'job': <String, dynamic>{
            'id': 'start-job',
            'state': 'running',
            'stage': 'cancelling',
          },
        };
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(projectProvider.notifier);
      await notifier.startAnalysis();
      await Future<void>.delayed(Duration.zero);

      await notifier.cancelAnalysis();

      expect(container.read(projectProvider).job?['stage'], 'cancelling');
      expect(container.read(noticeProvider).last.title, '正在取消分析…');
      expect(container.read(noticeProvider).last.severity, NoticeSeverity.info);
    },
  );

  group('ProjectNotifier.reviewCandidate', () {
    test('reviewCandidate(id,"goal") 更新候选 status 并 push 成功 notice', () async {
      final fakeSession = _FakeProjectSession()
        ..seedCandidates(<JsonMap>[
          <String, dynamic>{'id': 'c1', 'review_status': 'pending'},
        ]);
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectProvider.notifier);
      await notifier.refreshCandidates();
      expect(
        container.read(projectProvider).candidates.first['review_status'],
        'pending',
      );

      await notifier.reviewCandidate('c1', 'goal');

      final state = container.read(projectProvider);
      expect(state.candidates.first['review_status'], 'goal');
      final notices = container.read(noticeProvider);
      expect(notices.last.severity, NoticeSeverity.success);
      expect(notices.last.title, '已保留片段');
    });

    test('reviewCandidate(id,"rejected") push 排除 notice', () async {
      final fakeSession = _FakeProjectSession()
        ..seedCandidates(<JsonMap>[
          <String, dynamic>{'id': 'c2', 'review_status': 'pending'},
        ]);
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectProvider.notifier);
      await notifier.refreshCandidates();
      await notifier.reviewCandidate('c2', 'rejected');

      final state = container.read(projectProvider);
      expect(state.candidates.first['review_status'], 'rejected');
      final notices = container.read(noticeProvider);
      expect(notices.last.title, '已排除候选');
    });

    test('reviewCandidate(id,"deferred") pushes a deferred notice', () async {
      final fakeSession = _FakeProjectSession()
        ..seedCandidates(<JsonMap>[
          <String, dynamic>{'id': 'c3', 'review_status': 'pending'},
        ]);
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectProvider.notifier);
      await notifier.refreshCandidates();
      await notifier.reviewCandidate('c3', 'deferred', reason: 'uncertain');

      final notices = container.read(noticeProvider);
      expect(notices.last.title, '已暂缓审核');
    });

    test('loadReviewHistory returns persisted review actions', () async {
      final fakeSession = _FakeProjectSession()
        ..reviewHistory = <JsonMap>[
          <String, dynamic>{
            'candidate_id': 'c4',
            'status': 'excluded',
            'reason': 'rebound',
          },
        ];
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final history = await container
          .read(projectProvider.notifier)
          .loadReviewHistory('c4');

      expect(history.single['reason'], 'rebound');
    });

    test(
      'refreshStatistics stores backend statistics without requiring duration fields',
      () async {
        final fakeSession = _FakeProjectSession()
          ..statistics = <String, dynamic>{'candidate_count': 3};
        final container = ProviderContainer(
          overrides: <Override>[
            projectSessionProvider.overrideWithValue(fakeSession),
            engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
          ],
        );
        addTearDown(container.dispose);

        await container.read(projectProvider.notifier).refreshStatistics();

        expect(container.read(projectProvider).statistics, {
          'candidate_count': 3,
        });
      },
    );

    test(
      'startReview restarts timing when the candidate is revisited',
      () async {
        final fakeSession = _FakeProjectSession();
        final container = ProviderContainer(
          overrides: <Override>[
            projectSessionProvider.overrideWithValue(fakeSession),
            engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(projectProvider.notifier);
        await notifier.startReview('c1');
        await notifier.startReview('c1');
        await notifier.startReview('c2');

        expect(fakeSession.startReviewCalls, ['c1', 'c1', 'c2']);
      },
    );

    test(
      'rapid review operations are serialized without dropping input',
      () async {
        final fakeSession =
            _FakeProjectSession(reviewDelay: const Duration(milliseconds: 20))
              ..seedCandidates(<JsonMap>[
                <String, dynamic>{'id': 'c1', 'review_status': 'pending'},
                <String, dynamic>{'id': 'c2', 'review_status': 'pending'},
              ]);
        final container = ProviderContainer(
          overrides: <Override>[
            projectSessionProvider.overrideWithValue(fakeSession),
            engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(projectProvider.notifier);
        await notifier.refreshCandidates();

        final first = notifier.reviewCandidate(
          'c1',
          'included',
          showNotice: false,
        );
        final second = notifier.reviewCandidate(
          'c2',
          'excluded',
          showNotice: false,
        );

        expect(await Future.wait([first, second]), [true, true]);
        expect(fakeSession.reviewCalls, ['c1', 'c2']);
        expect(
          container
              .read(projectProvider)
              .candidates
              .map((candidate) => candidate['review_status']),
          ['goal', 'excluded'],
        );
      },
    );
  });

  group('ProjectNotifier.updateClipRange', () {
    test(
      'updateClipRange 更新候选的 review_start_ms/review_end_ms 并 push 片段范围 notice',
      () async {
        final fakeSession = _FakeProjectSession()
          ..seedCandidates(<JsonMap>[
            <String, dynamic>{
              'id': 'c1',
              'review_status': 'goal',
              'review_start_ms': 0,
              'review_end_ms': 1000,
            },
          ]);
        final container = ProviderContainer(
          overrides: <Override>[
            projectSessionProvider.overrideWithValue(fakeSession),
            engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(projectProvider.notifier);
        await notifier.refreshCandidates();
        await notifier.updateClipRange('c1', 100, 900);

        final candidate = container.read(projectProvider).candidates.first;
        expect(candidate['review_start_ms'], 100);
        expect(candidate['review_end_ms'], 900);
        final notices = container.read(noticeProvider);
        expect(notices.last.title, '片段范围已更新');
      },
    );
  });

  group('ProjectNotifier.saveRoi', () {
    test('Engine 拒绝保存 ROI 时返回 false', () async {
      final fakeSession = _FakeProjectSession()..throwOnSaveRoi = true;
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectProvider.notifier);
      await notifier.selectVideo('/path/sample.mp4');
      final saved = await notifier.saveRoi(
        const Rect.fromLTWH(0.1, 0.1, 0.3, 0.3),
      );

      expect(saved, isFalse);
      expect(container.read(projectProvider).roiSource, isNull);
    });
  });

  group('ProjectNotifier.export', () {
    test('后台导出不会锁死后续审核操作', () async {
      final fakeSession = _FakeProjectSession()
        ..seedCandidates(<JsonMap>[
          <String, dynamic>{'id': 'c-export', 'review_status': 'pending'},
        ]);
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectProvider.notifier);
      await notifier.refreshCandidates();
      await notifier.export('separate', outputDir: '/tmp/highlights');

      expect(container.read(projectProvider).busy, isFalse);
      expect(container.read(projectProvider).exportRunning, isTrue);

      final succeeded = await notifier.reviewCandidate(
        'c-export',
        'included',
        showNotice: false,
      );

      expect(succeeded, isTrue);
      expect(
        container.read(projectProvider).candidates.single['review_status'],
        'goal',
      );
    });
  });

  group('ProjectNotifier.deleteProject', () {
    test('删除项目后保留最近项目列表并提示成功', () async {
      final fakeSession = _FakeProjectSession();
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(projectProvider.notifier)
          .deleteProject('/tmp/project');

      expect(fakeSession.deletedRoots, ['/tmp/project']);
      expect(container.read(noticeProvider).last.title, contains('项目已删除'));
    });
  });

  group('ProjectNotifier 错误路径', () {
    test('action 抛错时 push error notice,busy 复位 false', () async {
      final fakeSession = _FakeProjectSession()
        ..throwOnReviewCandidate = true
        ..seedCandidates(<JsonMap>[
          <String, dynamic>{'id': 'c1', 'review_status': 'pending'},
        ]);
      final container = ProviderContainer(
        overrides: <Override>[
          projectSessionProvider.overrideWithValue(fakeSession),
          engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(projectProvider.notifier);
      await notifier.refreshCandidates();
      await notifier.reviewCandidate('c1', 'goal');

      final state = container.read(projectProvider);
      expect(state.busy, isFalse);
      // 候选 status 未变(fake 抛错,listCandidates 返回旧值)。
      expect(state.candidates.first['review_status'], 'pending');
      final notices = container.read(noticeProvider);
      expect(notices.last.severity, NoticeSeverity.error);
    });
  });
}

/// 测试专用 EngineBootstrap:build() 直接返回 AsyncData(true),ensure() 空操作。
class _StubEngineBootstrap extends EngineBootstrapNotifier {
  @override
  AsyncValue<bool> build() => const AsyncData<bool>(true);

  @override
  Future<void> ensure() async {}
}

/// 子类化 ProjectSession(方案 A)。重写所有被 ProjectNotifier 调用的高层方法,
/// 返回预设 JsonMap;底层 engine.client 永不触达(_NeverTransport 兜底)。
class _FakeProjectSession extends ProjectSession {
  _FakeProjectSession({this.reviewDelay = Duration.zero})
    : super(EngineSession(_NeverTransport()));

  final Duration reviewDelay;
  Duration previewDelay = Duration.zero;

  final List<JsonMap> _candidates = <JsonMap>[];
  List<JsonMap> reviewHistory = <JsonMap>[];
  JsonMap statistics = <String, dynamic>{};
  final List<String> startReviewCalls = <String>[];
  final List<String> retryAnalysisCalls = <String>[];
  final List<String> deletedRoots = <String>[];
  final List<String> reviewCalls = <String>[];
  int startAnalysisCalls = 0;
  double? lastStartBeforeSeconds;
  double? lastStartAfterSeconds;
  double? lastRetryBeforeSeconds;
  double? lastRetryAfterSeconds;
  List<JsonMap> activeAnalysisJobs = <JsonMap>[];
  String? lastRetryMode;
  JsonMap retryAnalysisResult = <String, dynamic>{
    'job': <String, dynamic>{'id': 'retry-job', 'state': 'queued'},
  };
  JsonMap cancelJobResult = <String, dynamic>{};
  bool throwOnReviewCandidate = false;
  bool throwOnSaveRoi = false;
  bool throwOnOpenProject = false;
  bool clearCandidatesOnRetry = false;
  bool returnRoiSuggestion = false;
  int loadRecentProjectsCalls = 0;
  List<JsonMap> recentProjects = <JsonMap>[];

  void seedCandidates(List<JsonMap> seed) {
    _candidates
      ..clear()
      ..addAll(seed);
  }

  @override
  Future<JsonMap> createProject({
    required String name,
    required String rootPath,
    String? projectId,
    String language = 'zh-CN',
  }) async {
    startAnalysisCalls++;
    return <String, dynamic>{
      'job': <String, dynamic>{'id': 'start-job', 'state': 'queued'},
    };
  }

  @override
  Future<JsonMap> deleteProject(String projectRoot) async {
    deletedRoots.add(projectRoot);
    return <String, dynamic>{'deleted': true};
  }

  @override
  Future<JsonMap> openProject(String projectRoot) async {
    if (throwOnOpenProject) throw StateError('invalid project');
    return <String, dynamic>{
      'project_root': projectRoot,
      'project': <String, dynamic>{'id': 'proj-1'},
    };
  }

  @override
  Future<List<JsonMap>> loadRecentProjects({
    required String knownRoot,
    int limit = 20,
  }) async {
    loadRecentProjectsCalls++;
    return recentProjects;
  }

  @override
  Future<JsonMap> linkVideo(String videoPath) async => <String, dynamic>{
    'video': <String, dynamic>{
      'id': 'vid-1',
      'source_path': videoPath,
      'duration_ms': 5000,
      'width': 1920,
      'height': 1080,
    },
  };

  @override
  Future<JsonMap> extractPreview({int timeMs = 1000}) async {
    if (previewDelay > Duration.zero) await Future<void>.delayed(previewDelay);
    return <String, dynamic>{'path': '/tmp/preview.jpg'};
  }

  @override
  Future<JsonMap> suggestRoi({
    String? modelPath,
    double? sampleFps,
    double? duration,
    int? maxSamples,
    double? confidence,
  }) async {
    if (!returnRoiSuggestion) throw StateError('no roi available');
    return <String, dynamic>{
      'roi': <String, dynamic>{'x1': 400, 'y1': 200, 'x2': 900, 'y2': 900},
      'calibration': <String, dynamic>{
        'confidence': 0.8,
        'hoop_bbox': <num>[600, 400, 640, 440],
      },
      'preview_time_ms': 4000,
    };
  }

  @override
  Future<JsonMap> saveRoi({
    required num x1,
    required num y1,
    required num x2,
    required num y2,
    String? name,
    JsonMap? calibration,
  }) async {
    if (throwOnSaveRoi) throw StateError('save_roi failed');
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> startAnalysis({
    String? mode,
    double? sampleFps,
    double? windowSeconds,
    double? beforeSeconds,
    double? afterSeconds,
    int? proxyWidth,
    int? proxyHeight,
    double? proxyFps,
    String? modelPath,
  }) async {
    startAnalysisCalls++;
    lastStartBeforeSeconds = beforeSeconds;
    lastStartAfterSeconds = afterSeconds;
    return <String, dynamic>{
      'job': <String, dynamic>{'id': 'start-job', 'state': 'queued'},
    };
  }

  @override
  Future<JsonMap> retryAnalysis({
    required String jobId,
    String? mode,
    double? sampleFps,
    double? windowSeconds,
    double? beforeSeconds,
    double? afterSeconds,
    int? proxyWidth,
    int? proxyHeight,
    double? proxyFps,
    String? modelPath,
  }) async {
    retryAnalysisCalls.add(jobId);
    lastRetryMode = mode;
    lastRetryBeforeSeconds = beforeSeconds;
    lastRetryAfterSeconds = afterSeconds;
    if (clearCandidatesOnRetry) _candidates.clear();
    return retryAnalysisResult;
  }

  @override
  Future<JsonMap> cancelJob({required String jobId}) async =>
      cancelJobResult.isNotEmpty
      ? cancelJobResult
      : <String, dynamic>{
          'job': <String, dynamic>{'id': jobId, 'state': 'cancelled'},
        };

  @override
  Future<JsonMap> listCandidates() async => <String, dynamic>{
    'candidates': List<JsonMap>.from(_candidates),
  };

  @override
  Future<JsonMap> listReviewHistory(String candidateId) async =>
      <String, dynamic>{'history': reviewHistory};

  @override
  Future<JsonMap> getStatistics() async => <String, dynamic>{
    'statistics': statistics,
  };

  @override
  Future<JsonMap> startReview(
    String candidateId, {
    String? reviewStartedAt,
  }) async {
    startReviewCalls.add(candidateId);
    return <String, dynamic>{
      'review_started_at': '2026-08-07T01:00:00.000+00:00',
    };
  }

  @override
  Future<JsonMap> reviewCandidate(
    String candidateId, {
    required String status,
    String? note,
    String? reason,
  }) async {
    reviewCalls.add(candidateId);
    await Future<void>.delayed(reviewDelay);
    if (throwOnReviewCandidate) {
      throw StateError('review_candidate failed');
    }
    final idx = _candidates.indexWhere((c) => c['id'] == candidateId);
    if (idx >= 0) {
      _candidates[idx] = <String, dynamic>{
        ..._candidates[idx],
        'review_status': status,
        'review_reason': reason,
        'note': note,
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> updateClipRange({
    required String candidateId,
    required int startMs,
    required int endMs,
  }) async {
    final idx = _candidates.indexWhere((c) => c['id'] == candidateId);
    if (idx >= 0) {
      _candidates[idx] = <String, dynamic>{
        ..._candidates[idx],
        'review_start_ms': startMs,
        'review_end_ms': endMs,
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> startExport({
    String mode = 'separate',
    String? outputDir,
    String? outputPath,
    List<String>? playerIds,
    bool? includeUnassigned,
  }) async => <String, dynamic>{
    'job': <String, dynamic>{'id': 'export-1', 'state': 'running'},
  };

  @override
  Future<List<JsonMap>> getActiveJobs({String jobType = 'analysis'}) async =>
      jobType == 'analysis' ? activeAnalysisJobs : <JsonMap>[];

  @override
  Future<List<JsonMap>> listExports({int limit = 20}) async => <JsonMap>[];

  @override
  Stream<JsonMap> pollJob({
    required String jobId,
    Duration interval = const Duration(seconds: 1),
  }) async* {}
}

class _NeverTransport implements EngineTransport {
  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    throw StateError('unexpected engine call: $command');
  }
}

class _ThrowingTransport implements EngineTransport {
  @override
  Future<JsonMap> request(String command, JsonMap payload) {
    throw const EngineException('ENGINE_EXITED', 'Engine 已退出');
  }
}

class _RecoveringTransport implements EngineTransport {
  var _jobPolls = 0;

  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    if (command == 'get_active_jobs') {
      return <String, dynamic>{
        'jobs': <JsonMap>[
          <String, dynamic>{
            'id': 'start-job',
            'state': 'running',
            'stage': 'prepare_proxy',
            'recovery_state': 'worker_attached',
            'recoverable': false,
          },
        ],
      };
    }
    if (command == 'get_job') {
      if (_jobPolls++ == 0) {
        throw const EngineException('ENGINE_TIMEOUT', '请求处理超时：get_job');
      }
      return <String, dynamic>{
        'job': <String, dynamic>{
          'id': 'start-job',
          'state': 'completed',
          'stage': 'persist_candidates',
          'progress': 1.0,
        },
      };
    }
    throw StateError('unexpected engine call: $command');
  }
}
