import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reads metadata from a BHE with a 201 MiB stored video',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final video = File('${f.root.path}/embedded.mp4');
        final handle = await video.open(mode: FileMode.write);
        await handle.truncate(201 * 1024 * 1024);
        await handle.close();
        final source = await f.file('source.mp4', 'original');
        final original = f.project(source.path, id: 'large');
        final metadata = await f.file(
          'metadata.json',
          const ProjectPackageCodec().encode(original),
        );
        final package = File('${f.root.path}/large.bhe');
        final encoder = ZipFileEncoder()
          ..create(package.path, level: ZipFileEncoder.store);
        try {
          final input = InputFileStream(video.path);
          try {
            encoder.addArchiveFile(
              ArchiveFile.stream('videos/embedded.mp4', input)
                ..compression = CompressionType.none,
            );
          } finally {
            input.closeSync();
          }
          encoder.addFileSync(metadata, 'project.json');
        } finally {
          encoder.closeSync();
        }
        await video.delete();
        expect(await package.length(), greaterThan(200 * 1024 * 1024));
        f.choose(package);
        await f.state.importProject();
        expect(f.state.errorMessage, isNull);
        expect(f.state.project.id, 'large');
        expect(f.state.project.candidates.single.id, 'goal');
        // An existing external reference still goes through the usual video-store
        // migration. The large embedded video must never be extracted.
        expect(
          await File(f.state.project.video!.path).readAsString(),
          'original',
        );
        final extracted = f.root
            .list(recursive: true)
            .where((entry) => entry.uri.pathSegments.last == 'embedded.mp4');
        expect(await extracted.isEmpty, isTrue);
      } finally {
        await f.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('accepts Android picker metadata without a filesystem path', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      const project = ProjectSnapshot(
        id: 'direct',
        name: 'URI import',
        video: null,
      );
      final metadata = utf8.encode(const ProjectPackageCodec().encode(project));
      f.picker.pick = () async => FilePickerResult([
        PlatformFile(
          name: 'project.json',
          size: metadata.length,
          bytes: metadata,
        ),
      ]);
      await f.state.importProject();
      expect(f.state.project.name, 'URI import');
      expect(f.state.errorMessage, '项目已打开，请重新选择原视频后继续。');
    } finally {
      await f.close();
    }
  });
}
