import 'dart:async';
import 'dart:io';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/core/video_segments.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/session_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _GameEngine engine;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('bhe-queue-');
    engine = _GameEngine(directory);
    container = ProviderContainer(
      overrides: [
        projectSessionProvider.overrideWithValue(
          ProjectSession(EngineSession(engine)),
        ),
        engineBootstrapProvider.overrideWith(_StubEngineBootstrap.new),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    directory.deleteSync(recursive: true);
  });

  ProjectNotifier notifier() => container.read(projectProvider.notifier);
  ProjectState state() => container.read(projectProvider);

  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  test('analyses every segment with a hoop in order and skips the rest', () async {
    engine.addVideo('v1', roi: true);
    engine.addVideo('v2', roi: true);
    engine.addVideo('v3');
    expect(await notifier().openProject(directory.path), isTrue);
    expect(state().videos, hasLength(3));
    expect(state().multiVideo, isTrue);

    await notifier().startAnalysisQueue(beforeSeconds: 5, afterSeconds: 2);
    await settle(() => state().analysisQueue.isEmpty && !state().busy);

    expect(engine.started, ['v1', 'v2']);
    expect(engine.startPayloads.map((item) => item['before_seconds']), [5.0, 5.0]);
    expect(engine.startPayloads.map((item) => item['after_seconds']), [2.0, 2.0]);
    expect(engine.queue['video_ids'], isEmpty);
    expect(
      container.read(noticeProvider).map((item) => item.title),
      containsAll(['第 1 段分析完成', '第 2 段分析完成', '全部视频段分析完成']),
    );
  });

  test('pausing lets the running segment finish without starting the next', () async {
    engine.addVideo('v1', roi: true);
    engine.addVideo('v2', roi: true);
    engine.hold = Completer<void>();
    await notifier().openProject(directory.path);

    await notifier().startAnalysisQueue(beforeSeconds: 6, afterSeconds: 3);
    await settle(() => engine.started.length == 1);
    await notifier().pauseAnalysisQueue();
    engine.hold!.complete();
    await settle(() => state().analysisQueue.length == 1 && !state().analysisRunning);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(engine.started, ['v1']);
    expect(state().queuePaused, isTrue);
    expect(engine.queue['video_ids'], ['v2']);

    await notifier().resumeAnalysisQueue();
    await settle(() => state().analysisQueue.isEmpty && !state().busy);
    expect(engine.started, ['v1', 'v2']);
  });

  test('an export requested while the queue runs goes between two segments', () async {
    engine.addVideo('v1', roi: true);
    engine.addVideo('v2', roi: true);
    engine.hold = Completer<void>();
    await notifier().openProject(directory.path);

    await notifier().startAnalysisQueue(beforeSeconds: 6, afterSeconds: 3);
    await settle(() => state().analysisRunning && !state().busy);
    await notifier().export('merge', outputPath: '${directory.path}/game.mp4');
    expect(state().exportQueued, isTrue);
    expect(engine.commands, isNot(contains('start_export')));

    engine.hold!.complete();
    await settle(() => state().analysisQueue.isEmpty && !state().busy && !state().exportRunning);

    final order = [
      for (final command in engine.commands)
        if (command == 'start_analysis' || command == 'start_export') command,
    ];
    expect(order, ['start_analysis', 'start_export', 'start_analysis']);
    expect(engine.started, ['v1', 'v2']);
    expect(state().exportQueued, isFalse);
  });

  test('added videos reuse a continuous hoop or trust only a stable detection', () async {
    engine.addVideo('v1', roi: true, recordedAt: '2026-10-17T10:00:00Z', durationMs: 600000);
    await notifier().openProject(directory.path);
    final continuous = engine.file('part2.mp4', recordedAt: '2026-10-17T10:10:02Z');
    final unstable = engine.file('later.mp4', recordedAt: '2026-10-17T11:30:00Z', confidence: 0.3);
    final stable = engine.file('other.mp4', recordedAt: '2026-10-17T12:00:00Z', confidence: 0.82);

    await notifier().addVideos([stable, continuous, unstable]);

    expect(
      [for (final video in state().videos) video['source_path'].toString().split('/').last],
      ['v1.mp4', 'part2.mp4', 'later.mp4', 'other.mp4'],
    );
    final saved = {
      for (final entry in engine.savedRois.entries)
        engine.videoName(entry.key): (entry.value['calibration'] as Map)['source'],
    };
    expect(saved, {
      'part2.mp4': 'reused',
      'later.mp4': 'suggested',
      'other.mp4': 'auto',
    });
    final auto = engine.savedRois.entries
        .firstWhere((entry) => engine.videoName(entry.key) == 'other.mp4')
        .value;
    expect((auto['calibration'] as Map)['net_roi'], isA<Map>());
    expect(engine.suggested, ['later.mp4', 'other.mp4']);
  });

  test('confirming a part hands its hoop to the following continuous parts', () async {
    engine.addVideo('v1', roi: true, recordedAt: '2026-10-17T10:00:00Z', durationMs: 300000);
    engine.addVideo('v2', recordedAt: '2026-10-17T10:05:00Z', durationMs: 300000, source: 'suggested');
    engine.addVideo('v3', recordedAt: '2026-10-17T10:10:01Z', durationMs: 300000);
    engine.addVideo('v4', recordedAt: '2026-10-17T11:00:00Z', durationMs: 300000, source: 'suggested');
    engine.addVideo('v5', recordedAt: '2026-10-17T11:05:00Z', durationMs: 300000);
    await notifier().openProject(directory.path);
    expect(
      [for (final video in state().videos) needsHoopConfirmation(video)],
      [false, true, true, true, true],
    );

    await notifier().propagateHoopToFollowingParts('v1');

    expect(engine.savedRois.keys, ['v2', 'v3']);
    expect((engine.savedRois['v3']!['calibration'] as Map)['reused_from'], 'v2');
    expect(
      [for (final video in state().videos) needsHoopConfirmation(video)],
      [false, false, false, true, true],
    );
    await notifier().startAnalysisQueue(beforeSeconds: 6, afterSeconds: 3);
    await settle(() => state().analysisQueue.isEmpty && !state().busy);
    expect(engine.started, ['v1', 'v2', 'v3']);
  });

  test('resuming after a restart replaces the interrupted job', () async {
    engine.addVideo('v1', roi: true);
    engine.addVideo('v2', roi: true);
    engine.jobs['job-old'] = {
      'id': 'job-old',
      'type': 'analysis',
      'state': 'running',
      'video_id': 'v1',
      'stale': true,
    };
    engine.queue = {'video_ids': ['v1', 'v2'], 'before_seconds': 6, 'after_seconds': 3};
    await notifier().openProject(directory.path);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(state().queuePaused, isTrue);

    await notifier().resumeAnalysisQueue();
    await settle(() => state().analysisQueue.isEmpty && !state().busy);
    expect(engine.jobs['job-old']!['state'], 'cancelled');
    expect(engine.started, ['v1', 'v2']);
  });

  test('recording time helpers', () {
    JsonMap video(String? recordedAt, String name, {int duration = 60000}) => {
      'recorded_at': recordedAt,
      'source_path': '/v/$name',
      'duration_ms': duration,
      'width': 1920,
      'height': 1440,
    };
    final videos = [
      video(null, 'b.mp4'),
      video('2026-10-17T10:05:00Z', 'z.mp4'),
      video('2026-10-17T10:00:00Z', 'y.mp4'),
      video(null, 'a.mp4'),
    ]..sort(compareByRecordingTime);
    expect(
      [for (final item in videos) item['source_path']],
      ['/v/y.mp4', '/v/z.mp4', '/v/a.mp4', '/v/b.mp4'],
    );
    final first = video('2026-10-17T10:00:00Z', 'a.mp4', duration: 300000);
    expect(continuesRecording(first, video('2026-10-17T10:05:04Z', 'b.mp4')), isTrue);
    expect(continuesRecording(first, video('2026-10-17T10:06:00Z', 'b.mp4')), isFalse);
    expect(continuesRecording(first, {...video('2026-10-17T10:05:00Z', 'b.mp4'), 'width': 1280}), isFalse);
    expect(continuesRecording(first, video(null, 'b.mp4')), isFalse);
    expect(reliableRoiSuggestion({'confidence': 0.6, 'stability': 0.8}), isTrue);
    expect(reliableRoiSuggestion({'confidence': 0.6, 'stability': 0.3}), isFalse);
    expect(reliableRoiSuggestion({'confidence': 0.2, 'stability': 1.0}), isFalse);
  });
}

class _StubEngineBootstrap extends EngineBootstrapNotifier {
  @override
  AsyncValue<bool> build() => const AsyncData<bool>(true);

  @override
  Future<void> ensure({
    String? runtimeRootOverride,
    String? pythonExecutableOverride,
  }) async {}
}

/// 用内存状态模拟引擎：一次只跑一个任务，get_job 在 [hold] 放行前保持 running。
class _GameEngine implements EngineTransport {
  _GameEngine(this.directory);

  final Directory directory;
  final List<JsonMap> videos = [];
  final Map<String, JsonMap> files = {};
  final Map<String, JsonMap> jobs = {};
  final Map<String, JsonMap> savedRois = {};
  final List<String> commands = [];
  final List<String> started = [];
  final List<JsonMap> startPayloads = [];
  final List<String> suggested = [];
  JsonMap queue = {'video_ids': <String>[], 'before_seconds': 6, 'after_seconds': 3};
  Completer<void>? hold;

  String _path(String name) => '${directory.path}/$name';

  void addVideo(
    String id, {
    bool roi = false,
    String? recordedAt,
    int durationMs = 300000,
    String? source,
  }) {
    final path = _path('$id.mp4');
    File(path).writeAsStringSync('video');
    videos.add({
      'id': id,
      'source_path': path,
      'source_exists': true,
      'duration_ms': durationMs,
      'width': 1920,
      'height': 1440,
      'recorded_at': recordedAt,
      'analysis_start_ms': 0,
      'analysis_end_ms': durationMs,
      'roi': roi || source != null ? _roi({'source': source ?? 'manual'}) : null,
      'analysis_job': null,
      'candidate_count': 0,
    });
  }

  String file(String name, {String? recordedAt, double confidence = 0.9}) {
    final path = _path(name);
    File(path).writeAsStringSync('video');
    files[path] = {
      'source_path': path,
      'duration_ms': 300000,
      'width': 1920,
      'height': 1440,
      'recorded_at': recordedAt,
      'confidence': confidence,
    };
    return path;
  }

  String videoName(String id) => videos
      .firstWhere((video) => video['id'] == id)['source_path']
      .toString()
      .split('/')
      .last;

  JsonMap _roi(JsonMap calibration) => {
    'x1': 700,
    'y1': 300,
    'x2': 1260,
    'y2': 1000,
    'calibration': calibration,
  };

  JsonMap _context() => {
    'project_root': directory.path,
    'project': {'id': 'project-1', 'name': '周六比赛'},
    'analysis_mode': 'standard',
    'workflow_draft': null,
    'video': videos.isEmpty ? null : videos.first,
    'roi': videos.isEmpty ? null : videos.first['roi'],
    'videos': videos,
    'analysis_queue': queue,
    'statistics': <String, dynamic>{},
  };

  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    commands.add(command);
    switch (command) {
      case 'open_project':
        return _context();
      case 'set_analysis_queue':
        queue = {
          'video_ids': List<String>.from(payload['video_ids'] as List),
          'before_seconds': payload['before_seconds'],
          'after_seconds': payload['after_seconds'],
        };
        return {'analysis_queue': queue};
      case 'start_analysis':
      case 'start_export':
        if (jobs.values.any((job) => job['state'] == 'running')) {
          throw StateError('JOB_ALREADY_RUNNING');
        }
        final id = 'job-${jobs.length + 1}';
        final videoId = payload['video_id']?.toString();
        jobs[id] = {
          'id': id,
          'type': command == 'start_export' ? 'export' : 'analysis',
          'state': 'running',
          'video_id': videoId,
        };
        if (command == 'start_analysis') {
          started.add(videoId!);
          startPayloads.add(payload);
        }
        return {'job': {'id': id, 'state': 'queued'}};
      case 'get_job':
        final job = jobs[payload['job_id']]!;
        if (job['type'] == 'export' || hold == null || hold!.isCompleted) {
          job['state'] = 'completed';
          final video = videos.where((item) => item['id'] == job['video_id']);
          for (final item in video) {
            item['analysis_job'] = {'id': job['id'], 'state': 'completed'};
          }
        }
        return {'job': Map<String, dynamic>.from(job)};
      case 'inspect_video':
        return Map<String, dynamic>.from(files[payload['video_path']]!);
      case 'link_video':
        final metadata = files[payload['video_path']]!;
        final video = <String, dynamic>{
          ...metadata,
          'id': 'v${videos.length + 1}',
          'source_exists': true,
          'roi': null,
          'analysis_job': null,
          'candidate_count': 0,
        }..remove('confidence');
        videos.add(video);
        return {'video': video};
      case 'suggest_roi':
        final video = videos.firstWhere((item) => item['id'] == payload['video_id']);
        final name = videoName(video['id'].toString());
        suggested.add(name);
        final confidence = files[video['source_path']]!['confidence'];
        return {
          'roi': {'x1': 700, 'y1': 300, 'x2': 1260, 'y2': 1000},
          'calibration': {
            'source': 'auto_hoop_model',
            'confidence': confidence,
            'stability': 0.9,
            'hoop_bbox': [960, 560, 1000, 610],
          },
        };
      case 'save_roi':
        final videoId = payload['video_id'].toString();
        savedRois[videoId] = payload;
        videos.firstWhere((item) => item['id'] == videoId)['roi'] = _roi(
          Map<String, dynamic>.from(payload['calibration'] as Map),
        );
        return {'roi': payload};
      case 'list_candidates':
        return {'candidates': <dynamic>[], 'players': <dynamic>[]};
      case 'get_statistics':
        return {'statistics': <String, dynamic>{}};
      case 'list_exports':
        return {'exports': <dynamic>[]};
      case 'get_active_jobs':
        return {
          'jobs': [
            for (final job in jobs.values)
              if (job['state'] == 'running' && job['type'] == 'analysis')
                {...job, 'recovery_state': job['stale'] == true ? 'stale_recoverable' : 'worker_attached'},
          ],
        };
      case 'cancel_job':
        jobs[payload['job_id']]!['state'] = 'cancelled';
        return {'job': jobs[payload['job_id']]};
      case 'get_latest_job':
        return {'job': null};
      case 'get_analysis_mode':
        return {'mode': 'standard'};
      case 'extract_preview':
        return {'path': '${directory.path}/preview.jpg'};
      default:
        return <String, dynamic>{};
    }
  }
}
