import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';

class _FakeEngineTransport implements EngineTransport {
  final List<String> commands = [];
  final List<Map<String, dynamic>> payloads = [];
  final Map<String, dynamic> responses = {};
  final List<Map<String, dynamic>> jobResponses = [];

  @override
  Future<Map<String, dynamic>> request(
    String command,
    Map<String, dynamic> payload,
  ) async {
    commands.add(command);
    payloads.add(payload);
    if (command == 'get_job' && jobResponses.isNotEmpty) {
      return jobResponses.removeAt(0);
    }
    return responses[command] as Map<String, dynamic>? ?? <String, dynamic>{};
  }
}

void main() {
  test('EngineSession forwards the protocol commands and payloads', () async {
    final transport = _FakeEngineTransport()
      ..responses['create_project'] = {
        'project': {'id': 'project-1'},
      }
      ..responses['link_video'] = {
        'video': {'id': 'video-1'},
      };
    final session = EngineSession(transport);

    await session.createProject(name: '训练赛', rootPath: '/tmp/project');
    await session.linkVideo(
      projectRoot: '/tmp/project',
      videoPath: '/tmp/game.mp4',
    );

    expect(transport.commands, ['create_project', 'link_video']);
    expect(transport.payloads[0], {
      'name': '训练赛',
      'root_path': '/tmp/project',
      'language': 'zh-CN',
    });
    expect(transport.payloads[1], {
      'project_root': '/tmp/project',
      'video_path': '/tmp/game.mp4',
    });
  });

  test('EngineSession forwards delete_project', () async {
    final transport = _FakeEngineTransport()
      ..responses['delete_project'] = {
        'deleted': true,
        'project_root': '/tmp/project',
      };
    final session = EngineSession(transport);

    final result = await session.deleteProject(projectRoot: '/tmp/project');

    expect(result['deleted'], isTrue);
    expect(transport.commands, ['delete_project']);
    expect(transport.payloads.single, {'project_root': '/tmp/project'});
  });

  test('EngineSession polls get_job until a terminal state', () async {
    final transport = _FakeEngineTransport()
      ..jobResponses.addAll([
        {
          'job': {'id': 'job-1', 'state': 'running', 'progress': 0.5},
        },
        {
          'job': {'id': 'job-1', 'state': 'completed', 'progress': 1.0},
        },
      ]);
    final session = EngineSession(transport);

    final result = await session.waitForJob(
      projectRoot: '/tmp/project',
      jobId: 'job-1',
      interval: Duration.zero,
    );

    expect(result['job']['state'], 'completed');
    expect(transport.commands, ['get_job', 'get_job']);
    expect(transport.payloads.last, {
      'project_root': '/tmp/project',
      'job_id': 'job-1',
    });
  });

  test('EngineSession lists projects from one explicit known root', () async {
    final transport = _FakeEngineTransport()
      ..responses['list_recent_projects'] = {
        'projects': [
          {'project_root': '/tmp/projects/game-1'},
        ],
      };
    final session = EngineSession(transport);

    final result = await session.listRecentProjectsInRoot(
      knownRoot: '/tmp/projects',
      limit: 8,
    );

    expect(result['projects'], isA<List<dynamic>>());
    expect(transport.commands, ['list_recent_projects']);
    expect(transport.payloads.single, {
      'roots': ['/tmp/projects'],
      'limit': 8,
    });
  });

  test('EngineSession forwards automatic ROI suggestion parameters', () async {
    final transport = _FakeEngineTransport()
      ..responses['suggest_roi'] = {
        'roi': {'x1': 100, 'y1': 80, 'x2': 400, 'y2': 500},
        'calibration': {'source': 'auto_hoop_model'},
      };
    final session = EngineSession(transport);

    final result = await session.suggestRoi(
      projectRoot: '/tmp/project',
      videoId: 'video-1',
      sampleFps: 1,
      duration: 20,
      maxSamples: 12,
      confidence: 0.05,
    );

    expect(result['roi'], isA<Map<String, dynamic>>());
    expect(transport.commands, ['suggest_roi']);
    expect(transport.payloads.single, {
      'project_root': '/tmp/project',
      'video_id': 'video-1',
      'sample_fps': 1.0,
      'duration': 20.0,
      'max_samples': 12,
      'confidence': 0.05,
    });
  });

  test('EngineSession exposes recovery and export history commands', () async {
    final transport = _FakeEngineTransport()
      ..responses['get_active_jobs'] = {
        'jobs': [
          {'id': 'job-1', 'recoverable': true},
        ],
      }
      ..responses['list_exports'] = {
        'exports': [
          {'id': 'export-1'},
        ],
      };
    final session = EngineSession(transport);

    final active = await session.getActiveJobs(
      projectRoot: '/tmp/project',
      videoId: 'video-1',
    );
    final exports = await session.listExports(
      projectRoot: '/tmp/project',
      limit: 5,
    );

    expect(active['jobs'], isA<List<dynamic>>());
    expect(exports['exports'], isA<List<dynamic>>());
    expect(transport.payloads, [
      {'project_root': '/tmp/project', 'video_id': 'video-1'},
      {'project_root': '/tmp/project', 'limit': 5},
    ]);
  });

  test('EngineSession forwards relink video command', () async {
    final transport = _FakeEngineTransport()
      ..responses['relink_video'] = {
        'video': {'id': 'video-1', 'source_exists': true},
      };
    final session = EngineSession(transport);

    final result = await session.relinkVideo(
      projectRoot: '/tmp/project',
      videoId: 'video-1',
      videoPath: '/tmp/replacement.mp4',
    );

    expect(result['video']['source_exists'], isTrue);
    expect(transport.commands, ['relink_video']);
    expect(transport.payloads.single, {
      'project_root': '/tmp/project',
      'video_id': 'video-1',
      'video_path': '/tmp/replacement.mp4',
    });
  });

  test('EngineSession forwards asynchronous export command', () async {
    final transport = _FakeEngineTransport()
      ..responses['start_export'] = {
        'job': {'id': 'job-export-1', 'state': 'queued'},
      };
    final session = EngineSession(transport);

    final result = await session.startExport(
      projectRoot: '/tmp/project',
      videoId: 'video-1',
      mode: 'merge',
      outputPath: '/tmp/highlights.mp4',
    );

    expect(result['job']['id'], 'job-export-1');
    expect(transport.commands, ['start_export']);
    expect(transport.payloads.single, {
      'project_root': '/tmp/project',
      'video_id': 'video-1',
      'mode': 'merge',
      'output_path': '/tmp/highlights.mp4',
    });
  });

  test(
    'EngineSession forwards start review command and candidate id',
    () async {
      final transport = _FakeEngineTransport()
        ..responses['start_review'] = {
          'review_started_at': '2026-08-07T01:00:00.000+00:00',
        };
      final session = EngineSession(transport);

      final result = await session.startReview(
        projectRoot: '/tmp/project',
        candidateId: 'candidate-1',
      );

      expect(result['review_started_at'], isNotNull);
      expect(transport.commands, ['start_review']);
      expect(transport.payloads.single, {
        'project_root': '/tmp/project',
        'candidate_id': 'candidate-1',
      });
    },
  );

  test(
    'ProjectSession keeps project and video context for workflow calls',
    () async {
      final transport = _FakeEngineTransport()
        ..responses['create_project'] = {
          'project': {'id': 'project-1'},
        }
        ..responses['link_video'] = {
          'video': {'id': 'video-1'},
        }
        ..responses['list_candidates'] = {'candidates': <dynamic>[]}
        ..responses['review_candidate'] = {'updated': true}
        ..responses['export_clips'] = {
          'files': ['/tmp/exports/merged.mp4'],
        };
      final session = ProjectSession(EngineSession(transport));

      await session.createProject(name: '训练赛', rootPath: '/tmp/project');
      await session.linkVideo('/tmp/game.mp4');
      await session.saveRoi(x1: 10, y1: 20, x2: 100, y2: 120);
      await session.startAnalysis(sampleFps: 10);
      await session.listCandidates();
      await session.reviewCandidate('candidate-1', status: 'goal');
      await session.exportClips(mode: 'merge', outputPath: '/tmp/merged.mp4');

      expect(session.projectId, 'project-1');
      expect(session.videoId, 'video-1');
      expect(transport.payloads[2], {
        'project_root': '/tmp/project',
        'video_id': 'video-1',
        'x1': 10,
        'y1': 20,
        'x2': 100,
        'y2': 120,
      });
      expect(transport.payloads[3], {
        'project_root': '/tmp/project',
        'video_id': 'video-1',
        'sample_fps': 10.0,
      });
      expect(transport.payloads[4], {
        'project_root': '/tmp/project',
        'video_id': 'video-1',
      });
      expect(transport.payloads[5], {
        'project_root': '/tmp/project',
        'candidate_id': 'candidate-1',
        'status': 'goal',
      });
      expect(transport.payloads[6], {
        'project_root': '/tmp/project',
        'video_id': 'video-1',
        'mode': 'merge',
        'output_path': '/tmp/merged.mp4',
      });
    },
  );

  test(
    'ProjectSession rejects workflow calls without required context',
    () async {
      final session = ProjectSession(EngineSession(_FakeEngineTransport()));

      expect(
        () => session.listCandidates(),
        throwsA(isA<SessionStateException>()),
      );
    },
  );

  test('ProjectSession restores an existing project context', () async {
    final transport = _FakeEngineTransport()
      ..responses['open_project'] = {
        'project_root': '/tmp/project',
        'project': {'id': 'project-1'},
        'video': {'id': 'video-1', 'source_path': '/tmp/game.mp4'},
      };
    final session = ProjectSession(EngineSession(transport));

    final payload = await session.openProject('/tmp/project');

    expect(payload['project_root'], '/tmp/project');
    expect(session.projectRoot, '/tmp/project');
    expect(session.projectId, 'project-1');
    expect(session.videoId, 'video-1');
    expect(transport.commands, ['open_project']);
  });

  test(
    'ProjectSession loads recent projects using one explicit known root',
    () async {
      final transport = _FakeEngineTransport()
        ..responses['list_recent_projects'] = {
          'projects': [
            {
              'project_root': '/tmp/projects/game-1',
              'project': {'name': '训练赛'},
            },
          ],
          'scanned_roots': ['/tmp/projects'],
        };
      final session = ProjectSession(EngineSession(transport));

      final projects = await session.loadRecentProjects(
        knownRoot: '/tmp/projects',
      );

      expect(projects, hasLength(1));
      expect(projects.single['project_root'], '/tmp/projects/game-1');
      expect(transport.payloads.single, {
        'roots': ['/tmp/projects'],
        'limit': 20,
      });
    },
  );

  test('ProjectSession rejects an empty known root', () async {
    final session = ProjectSession(EngineSession(_FakeEngineTransport()));

    expect(
      () => session.loadRecentProjects(knownRoot: ' '),
      throwsA(isA<SessionStateException>()),
    );
  });

  test(
    'ProjectSession forwards start review with the active project context',
    () async {
      final transport = _FakeEngineTransport()
        ..responses['open_project'] = {
          'project_root': '/tmp/project',
          'project': {'id': 'project-1'},
        }
        ..responses['start_review'] = {
          'review_started_at': '2026-08-07T01:00:00.000+00:00',
        };
      final session = ProjectSession(EngineSession(transport));

      await session.openProject('/tmp/project');
      await session.startReview('candidate-1');

      expect(transport.payloads.last, {
        'project_root': '/tmp/project',
        'candidate_id': 'candidate-1',
      });
    },
  );
}
