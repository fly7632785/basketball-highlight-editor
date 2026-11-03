import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

FilePickerResult choose(File f) => FilePickerResult([
  PlatformFile(
    name: f.uri.pathSegments.last,
    path: f.path,
    size: f.lengthSync(),
  ),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final later in ['new', 'open', 'delete']) {
    test('old import picker is discarded after later $later', () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f
            .project('${f.root.path}/missing.mp4')
            .copyWith(clearVideo: true);
        expect(await f.state.renameProject('Baseline'), isTrue);
        final b = f.project('missing', id: 'B').copyWith(clearVideo: true);
        f.state.recentProjects = [f.state.project, b];
        await f.file(
          'BHE Mobile/projects/B.json',
          const ProjectPackageCodec().encode(b),
        );
        final incoming = await f.file(
          'import.json',
          const ProjectPackageCodec().encode(
            f.project('missing', id: 'C').copyWith(clearVideo: true),
          ),
        );
        final entered = Completer<void>(),
            result = Completer<FilePickerResult?>();
        f.picker.pick = () {
          entered.complete();
          return result.future;
        };
        final old = f.state.importProject();
        await entered.future;
        expect(f.state.projectTransitioning, isFalse);
        expect(
          await f.state.updateCandidateNote('goal', 'during picker'),
          isTrue,
        );
        expect(
          await f.state.updateSettings(
            f.state.project.settings.copyWith(startMs: 123),
            fields: {'startMs'},
          ),
          isTrue,
        );
        switch (later) {
          case 'new':
            await f.state.createNewProject();
          case 'open':
            await f.state.openProject('B');
          case 'delete':
            await f.state.clearProject();
        }
        final after = f.state.project.id;
        final recent = f.state.recentProjects.map((p) => p.id).toList();
        result.complete(choose(incoming));
        await old;
        expect(f.state.project.id, after);
        expect(f.state.recentProjects.map((p) => p.id), recent);
        expect(await File('${f.data.path}/projects/C.json').exists(), isFalse);
        expect(f.state.diagnosticError, isNull);
      } finally {
        await f.close();
      }
    });
  }
  for (final later in ['new', 'open']) {
    test('old new-video picker is discarded after later $later', () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f
            .project('${f.root.path}/missing.mp4')
            .copyWith(clearVideo: true);
        expect(await f.state.renameProject('Baseline'), isTrue);
        final b = f.project('missing', id: 'B').copyWith(clearVideo: true);
        f.state.recentProjects = [f.state.project, b];
        await f.file(
          'BHE Mobile/projects/B.json',
          const ProjectPackageCodec().encode(b),
        );
        final video = await f.file('video.mp4', 'original');
        final entered = Completer<void>(),
            result = Completer<FilePickerResult?>();
        f.picker.pick = () {
          entered.complete();
          return result.future;
        };
        final old = f.state.createNewProjectAndPickVideo();
        await entered.future;
        expect(f.state.projectTransitioning, isFalse);
        if (later == 'new') {
          await f.state.createNewProject();
        } else {
          await f.state.openProject('B');
        }
        final current = f.state.project.id;
        result.complete(choose(video));
        await old;
        expect(f.state.project.id, current);
        expect(f.state.project.video, isNull);
      } finally {
        await f.close();
      }
    });
  }
  test(
    'two imports in a row honor the newer picker even if the older fails',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('missing').copyWith(clearVideo: true);
        final incoming = await f.file(
          'new.json',
          const ProjectPackageCodec().encode(
            f.project('missing', id: 'C').copyWith(clearVideo: true),
          ),
        );
        // 选择窗口互斥：占用中再点会被忽略，所以两次导入必须一次接一次。
        final entered = Completer<void>(),
            result = Completer<FilePickerResult?>();
        f.picker.pick = () {
          entered.complete();
          return result.future;
        };
        final old = f.state.importProject();
        await entered.future;
        expect(f.state.pickerBusy, isTrue);
        result.completeError(
          PlatformException(code: 'obsolete_picker_failure'),
        );
        await old;
        expect(f.state.pickerBusy, isFalse);

        f.choose(incoming);
        await f.state.importProject();
        expect(f.state.project.id, 'C');
        expect(f.state.pickerBusy, isFalse);
      } finally {
        await f.close();
      }
    },
  );
  test('canceling a picker keeps edits made during preparation', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      f.state.project = f.project('missing').copyWith(clearVideo: true);
      final entered = Completer<void>(),
          result = Completer<FilePickerResult?>();
      f.picker.pick = () {
        entered.complete();
        return result.future;
      };
      final old = f.state.importProject();
      await entered.future;
      expect(await f.state.updateCandidateNote('goal', 'kept'), isTrue);
      result.complete(null);
      await old;
      expect(f.state.project.candidates.single.note, 'kept');
      expect(f.state.projectTransitioning, isFalse);
    } finally {
      await f.close();
    }
  });
  test(
    'two opens: newer intent wins even if the older read is blocked',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('missing').copyWith(clearVideo: true);
        expect(await f.state.renameProject('Baseline'), isTrue);
        final b = f.project('missing', id: 'B').copyWith(clearVideo: true);
        await f.file(
          'BHE Mobile/projects/B.json',
          const ProjectPackageCodec().encode(b),
        );
        final entered = Completer<void>(), release = Completer<void>();
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                }
                return f.root.path;
              },
            );
        final old = f.state.openProject('B');
        await entered.future;
        final latest = f.state.openProject('A');
        release.complete();
        await Future.wait([old, latest]);
        expect(f.state.project.id, 'A');
        expect(f.state.project.name, 'Baseline');
      } finally {
        await f.close();
      }
    },
  );

  test('newer canceled import still expires an older pending picker', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      f.state.project = f.project('missing').copyWith(clearVideo: true);
      final incoming = await f.file(
        'old.json',
        const ProjectPackageCodec().encode(
          f.project('missing', id: 'C').copyWith(clearVideo: true),
        ),
      );
      final entered = Completer<void>(),
          result = Completer<FilePickerResult?>();
      f.picker.pick = () {
        entered.complete();
        return result.future;
      };
      final old = f.state.importProject();
      await entered.future;
      f.choose(null);
      await f.state.importProject();
      expect(await f.state.updateCandidateNote('goal', 'still here'), isTrue);
      result.complete(choose(incoming));
      await old;
      expect(f.state.project.id, 'A');
      expect(f.state.project.candidates.single.note, 'still here');
      expect(await File('${f.data.path}/projects/C.json').exists(), isFalse);
    } finally {
      await f.close();
    }
  });

  test(
    'old replace-video picker cannot attach its file to a newer project',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('missing').copyWith(clearVideo: true);
        final video = await f.file('video.mp4', 'original');
        final entered = Completer<void>(),
            result = Completer<FilePickerResult?>();
        f.picker.pick = () {
          entered.complete();
          return result.future;
        };
        final old = f.state.pickVideo();
        await entered.future;
        await f.state.createNewProject();
        final id = f.state.project.id;
        result.complete(choose(video));
        await old;
        expect(f.state.project.id, id);
        expect(f.state.project.video, isNull);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'old new-video validation cannot commit after a newer new project',
    () async {
      final f = MobileVideoFixture();
      final entered = Completer<void>(), release = Completer<void>();
      await f.init(
        probe: (file) async {
          entered.complete();
          await release.future;
          return MobileVideoFixture.inspect(file);
        },
      );
      try {
        f.state.project = f.project('missing').copyWith(clearVideo: true);
        final video = await f.file('video.mp4', 'original');
        f.choose(video);
        final old = f.state.createNewProjectAndPickVideo();
        await entered.future;
        final oldId = f.state.project.id;
        await f.state.createNewProject();
        final id = f.state.project.id;
        expect(id, isNot(oldId));
        release.complete();
        await old;
        expect(f.state.project.id, id);
        expect(f.state.project.video, isNull);
        expect(
          await File('${f.data.path}/projects/$oldId.json').exists(),
          isFalse,
        );
        final videoDirectory = Directory('${f.data.path}/videos/$oldId');
        if (await videoDirectory.exists()) {
          expect(await videoDirectory.list().toList(), isEmpty);
        }
      } finally {
        if (!release.isCompleted) release.complete();
        await f.close();
      }
    },
  );
}
