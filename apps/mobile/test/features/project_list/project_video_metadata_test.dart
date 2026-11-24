import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/project_list/project_video_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recording titles use chosen language, recording time and duration', () {
    final time = DateTime(2026, 8, 22, 9, 22);
    expect(projectRecordingTitle(time, 1020000, 'zh'), '8月22日 上午9:22 · 17分钟');
    expect(
      projectRecordingTitle(time, 1020000, 'en'),
      'Aug 22, 9:22 AM · 17 min',
    );
  });

  test('new metadata survives saved project serialization', () {
    final time = DateTime.utc(2026, 8, 22, 1, 22);
    final original = ProjectSnapshot(
      id: 'metadata',
      name: 'game',
      video: VideoInfo(
        path: '/video.mov',
        name: 'original.mov',
        sizeBytes: 18,
        durationMs: 16000,
        width: 1920,
        height: 1080,
        capturedAt: time,
        frameRate: 29.97,
        codec: 'video/dolby-vision',
      ),
    );
    const codec = ProjectPackageCodec();
    final video = codec
        .decode(
          codec.encode(original, includeLocalHistory: true),
          includeLocalHistory: true,
        )
        .video!;
    expect(video.capturedAt, time);
    expect(video.frameRate, 29.97);
    expect(video.codec, 'video/dolby-vision');
  });
}
