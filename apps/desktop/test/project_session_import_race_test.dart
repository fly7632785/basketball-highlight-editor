import 'dart:async';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _GatedTransport implements EngineTransport {
  final create = Completer<Map<String, dynamic>>();
  final link = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> request(String command, Map<String, dynamic> payload) {
    if (command == 'create_project') return create.future;
    if (command == 'link_video') return link.future;
    throw StateError('Unexpected command $command');
  }
}

void main() {
  test('late project creation cannot replace a newer session', () async {
    final transport = _GatedTransport();
    final session = ProjectSession(EngineSession(transport));
    final pending = session.createProject(name: 'old', rootPath: '/old');
    session.restore(const ProjectSessionCheckpoint(projectRoot: '/new', projectId: 'new', videoId: 'new-video'));
    transport.create.complete({'project': {'id': 'old', 'root_path': '/old'}});
    await pending;
    expect(session.projectRoot, '/new');
    expect(session.projectId, 'new');
    expect(session.videoId, 'new-video');
  });

  test('late video link cannot replace a newer session, including same root', () async {
    final transport = _GatedTransport();
    final session = ProjectSession(EngineSession(transport));
    session.restore(const ProjectSessionCheckpoint(projectRoot: '/same', projectId: 'old', videoId: 'old-video'));
    final pending = session.linkVideo('/old.mp4');
    session.restore(const ProjectSessionCheckpoint(projectRoot: '/same', projectId: 'new', videoId: 'new-video'));
    transport.link.complete({'video': {'id': 'late-old-video'}});
    await pending;
    expect(session.projectRoot, '/same');
    expect(session.projectId, 'new');
    expect(session.videoId, 'new-video');
  });
}
