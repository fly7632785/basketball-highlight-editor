// test/providers/project_state_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/session_provider.dart';

void main() {
  group('ProjectNotifier.selectVideo', () {
    test('更新 videoPath/previewPath,自动 ROI 失败时记录 roiSuggestionError,push 成功 notice',
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
    });
  });

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
      expect(notices.last.title, '已确认进球');
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
  });

  group('ProjectNotifier.updateClipRange', () {
    test('updateClipRange 更新候选的 start_ms/end_ms 并 push 片段范围 notice', () async {
      final fakeSession = _FakeProjectSession()
        ..seedCandidates(<JsonMap>[
          <String, dynamic>{
            'id': 'c1',
            'review_status': 'goal',
            'start_ms': 0,
            'end_ms': 1000,
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
      expect(candidate['start_ms'], 100);
      expect(candidate['end_ms'], 900);
      final notices = container.read(noticeProvider);
      expect(notices.last.title, '片段范围已更新');
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
  _FakeProjectSession() : super(EngineSession(_NeverTransport()));

  final List<JsonMap> _candidates = <JsonMap>[];
  bool throwOnReviewCandidate = false;

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
  }) async =>
      <String, dynamic>{};

  @override
  Future<JsonMap> openProject(String projectRoot) async => <String, dynamic>{
        'project_root': projectRoot,
        'project': <String, dynamic>{'id': 'proj-1'},
      };

  @override
  Future<List<JsonMap>> loadRecentProjects({
    required String knownRoot,
    int limit = 20,
  }) async =>
      <JsonMap>[];

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
  Future<JsonMap> extractPreview({int timeMs = 1000}) async =>
      <String, dynamic>{'path': '/tmp/preview.jpg'};

  @override
  Future<JsonMap> suggestRoi({
    String? modelPath,
    double? sampleFps,
    double? duration,
    int? maxSamples,
    double? confidence,
  }) async {
    throw StateError('no roi available');
  }

  @override
  Future<JsonMap> saveRoi({
    required num x1,
    required num y1,
    required num x2,
    required num y2,
    String? name,
    JsonMap? calibration,
  }) async =>
      <String, dynamic>{};

  @override
  Future<JsonMap> startAnalysis({
    double? sampleFps,
    double? windowSeconds,
    double? beforeSeconds,
    double? afterSeconds,
    int? proxyWidth,
    int? proxyHeight,
    double? proxyFps,
    String? modelPath,
  }) async =>
      <String, dynamic>{};

  @override
  Future<JsonMap> retryAnalysis({
    required String jobId,
    double? sampleFps,
    double? windowSeconds,
    double? beforeSeconds,
    double? afterSeconds,
    int? proxyWidth,
    int? proxyHeight,
    double? proxyFps,
    String? modelPath,
  }) async =>
      <String, dynamic>{};

  @override
  Future<JsonMap> cancelJob({required String jobId}) async =>
      <String, dynamic>{'job': <String, dynamic>{'id': jobId, 'state': 'cancelled'}};

  @override
  Future<JsonMap> listCandidates() async => <String, dynamic>{
        'candidates': List<JsonMap>.from(_candidates),
      };

  @override
  Future<JsonMap> reviewCandidate(
    String candidateId, {
    required String status,
    String? note,
  }) async {
    if (throwOnReviewCandidate) {
      throw StateError('review_candidate failed');
    }
    final idx = _candidates.indexWhere((c) => c['id'] == candidateId);
    if (idx >= 0) {
      _candidates[idx] = <String, dynamic>{
        ..._candidates[idx],
        'review_status': status,
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
        'start_ms': startMs,
        'end_ms': endMs,
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<JsonMap> startExport({
    String mode = 'separate',
    String? outputDir,
    String? outputPath,
  }) async =>
      <String, dynamic>{
        'job': <String, dynamic>{'id': 'export-1', 'state': 'running'},
      };

  @override
  Future<List<JsonMap>> getActiveJobs({String jobType = 'analysis'}) async =>
      <JsonMap>[];

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
