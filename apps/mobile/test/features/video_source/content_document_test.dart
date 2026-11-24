import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/project_list/project_video_metadata.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saving and reopening a document keeps its URI and creates no source copy', () async {
    final fixture = MobileVideoFixture();
    await fixture.init();
    addTearDown(fixture.close);
    final previous = VideoPlayerPlatform.instance;
    final player = FakeVideoPlatform();
    VideoPlayerPlatform.instance = player;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() {
      VideoPlayerPlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(projectMediaChannel, null);
    });
    const uri = 'content://test.documents/document/video';
    messenger.setMockMethodCallHandler(projectMediaChannel, (call) async {
      expect(call.method, 'videoMetadata');
      expect(call.arguments, {'path': uri});
      return {'sizeBytes': 3000000000, 'fingerprint': 'test-fingerprint'};
    });
    fixture.picker.pick = () async => FilePickerResult([
      PlatformFile(name: 'recording.mp4', path: uri, size: 3000000000),
    ]);

    await fixture.state.createNewProjectAndPickVideo(locale: 'en');
    final project = fixture.state.project;
    expect(project.video?.path, uri);
    expect(project.video?.name, 'recording.mp4');
    expect(project.video?.sha256, 'test-fingerprint');
    expect(await Directory('${fixture.data.path}/videos').exists(), isFalse);
    final saved = File('${fixture.data.path}/projects/${project.id}.json');
    expect(const ProjectPackageCodec().decode(await saved.readAsString()).video?.path, uri);
    await fixture.state.openProject(project.id);
    expect(fixture.state.project.video?.path, uri);
    expect(fixture.state.videoSourceFailure, isNull);
    expect(player.sources.values, hasLength(2));
    expect(player.sources.values.every((source) =>
        source.sourceType == DataSourceType.contentUri && source.uri == uri), isTrue);
  });
}
