import 'dart:io';
import 'dart:async';

import 'package:bhe_mobile/features/video_source/video_source_store.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

class FaultFiles extends VideoFileOperations {
  FaultFiles(this.fail);
  final String fail;
  @override
  Future<void> copy(File from, File to, {bool Function()? isCurrent}) async {
    if (fail == 'copy') {
      await to.writeAsString('partial');
      throw const FileSystemException('injected copy failure');
    }
    return super.copy(from, to, isCurrent: isCurrent);
  }

  @override
  Future<void> move(File from, File to) async {
    if ((fail == 'restore' && from.path.contains('.backup_')) ||
        (fail == 'install' && from.path.contains('.import_')) ||
        (fail == 'move' && from.path.contains('file_picker'))) {
      throw const FileSystemException('injected rename failure');
    }
    return super.move(from, to);
  }
}

class CapturingDiagnostics extends MobileDiagnostics {
  final records = <DiagnosticErrorRecord>[];
  @override
  DiagnosticErrorRecord error(
    Object error,
    StackTrace? stack, {
    String operation = 'app',
  }) {
    final record = super.error(error, stack, operation: operation);
    records.add(record);
    return record;
  }
}

void main() {
  late Directory root;
  late Directory data;
  late Directory cache;
  late VideoSourceStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('bhe_source_');
    data = await Directory('${root.path}/data').create();
    cache = await Directory('${root.path}/cache').create();
    store = VideoSourceStore(
      dataDirectory: () async => data,
      temporaryDirectory: () async => cache,
    );
  });
  tearDown(() async => root.delete(recursive: true));

  Future<File> input(String path, String text) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    return file;
  }

  test(
    'picker cache cleanup preserves project references and unrelated files',
    () async {
      final kept = await input('cache/file_picker/123/kept.mp4', 'referenced');
      final stale = await input('cache/file_picker/123/stale.mov', 'unused');
      final recent = await input('cache/file_picker/456/recent.mp4', 'recent');
      final package = await input(
        'cache/file_picker/123/project.bhe',
        'package',
      );
      final older = DateTime.now().subtract(const Duration(days: 3));
      await kept.setLastModified(older);
      await stale.setLastModified(older);
      await package.setLastModified(older);
      await store.cleanUnusedPickerCache({kept.path});
      expect(await kept.exists(), isTrue);
      expect(await stale.exists(), isFalse);
      expect(await recent.exists(), isTrue);
      expect(await package.exists(), isTrue);
    },
  );

  Future<String> save(
    File file, {
    String id = 'A',
    String? old,
    bool picker = false,
    Future<String> Function(File)? validate,
    Future<void> Function(String, String)? persist,
    bool Function()? current,
  }) => store.save(
    sourcePath: file.path,
    projectId: id,
    fromPicker: picker,
    previousPath: old,
    isCurrent: current ?? () => true,
    validate: validate ?? (file) => file.readAsString(),
    persist: persist ?? (_, _) async {},
  );

  test('import another project copies its sole durable source', () async {
    final a = await input('data/videos/A/source.mp4', 'A original');
    await save(a, id: 'B');
    expect(await a.readAsString(), 'A original');
    expect(
      await File('${data.path}/videos/B/source.mp4').readAsString(),
      'A original',
    );
  });
  test(
    'only selected file_picker cache can move; package hints must copy',
    () async {
      final chosen = await input('cache/file_picker/one/picked.mp4', 'picked');
      await save(chosen, picker: true);
      expect(await chosen.exists(), isFalse);
      final hint = await input('cache/file_picker/two/picked.mp4', 'hint');
      await save(hint, id: 'B');
      expect(await hint.exists(), isTrue);
      final outside = await input('other/video.mp4', 'outside');
      await save(outside, id: 'C', picker: true);
      expect(await outside.exists(), isTrue);
    },
  );
  test(
    'same owned path validates without replacing or deleting other entries',
    () async {
      final source = await input('data/videos/A/source.mp4', 'same');
      final sentinel = await input('data/videos/A/keep/notes.txt', 'keep');
      await save(source);
      expect(await source.readAsString(), 'same');
      expect(await sentinel.readAsString(), 'keep');
    },
  );
  for (final failure in ['validate', 'copy', 'install', 'persist', 'cancel']) {
    test('$failure preserves old same-extension file and record', () async {
      final old = await input('data/videos/A/source.mp4', 'old');
      final chosen = await input('new.mp4', 'new');
      store = VideoSourceStore(
        dataDirectory: () async => data,
        temporaryDirectory: () async => cache,
        files: FaultFiles(failure),
      );
      var record = 'old';
      var current = true;
      await expectLater(
        save(
          chosen,
          old: old.path,
          current: () => current,
          validate: (file) async {
            if (failure == 'validate') {
              throw const FormatException('invalid media');
            }
            if (failure == 'cancel') current = false;
            return file.readAsString();
          },
          persist: (_, value) async {
            if (failure == 'persist') {
              throw const FileSystemException('save failed');
            }
            record = value;
          },
        ),
        throwsA(anything),
      );
      expect(await old.readAsString(), 'old');
      expect(record, 'old');
      expect(await chosen.readAsString(), 'new');
      expect(
        (await old.parent.list().toList()).map((e) => e.uri.pathSegments.last),
        ['source.mp4'],
      );
    });
  }
  test(
    'failed moved cache validation restores its original cache path',
    () async {
      final source = await input('cache/file_picker/one/picked.mp4', 'picked');
      await expectLater(
        save(
          source,
          picker: true,
          validate: (_) async => throw const FormatException('invalid'),
        ),
        throwsFormatException,
      );
      expect(await source.readAsString(), 'picked');
    },
  );
  test(
    'rollback failure preserves the original exception and reports recoverable backup',
    () async {
      final previous = MobileDiagnostics.instance;
      final diagnostics = CapturingDiagnostics();
      MobileDiagnostics.instance = diagnostics;
      try {
        final old = await input('data/videos/A/source.mp4', 'old');
        final chosen = await input('new.mp4', 'new');
        store = VideoSourceStore(
          dataDirectory: () async => data,
          temporaryDirectory: () async => cache,
          files: FaultFiles('restore'),
        );
        await expectLater(
          save(
            chosen,
            old: old.path,
            persist: (_, _) async =>
                throw const FormatException('original persist error'),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'original error',
              'original persist error',
            ),
          ),
        );
        final backups = await Directory(
          '${data.path}/videos/A',
        ).list().where((entry) => entry.path.contains('.backup_')).toList();
        expect(backups, hasLength(1));
        expect(await File(backups.single.path).readAsString(), 'old');
        expect(diagnostics.records.single.operation, 'video.restore');
        expect(diagnostics.records.single.stack, isNotNull);
      } finally {
        MobileDiagnostics.instance = previous;
      }
    },
  );

  test('rename failure falls back to copy', () async {
    final source = await input('cache/file_picker/one/picked.mp4', 'picked');
    store = VideoSourceStore(
      dataDirectory: () async => data,
      temporaryDirectory: () async => cache,
      files: FaultFiles('move'),
    );
    await save(source, picker: true);
    expect(await source.exists(), isTrue);
    expect(
      await File('${data.path}/videos/A/source.mp4').readAsString(),
      'picked',
    );
  });
  test(
    'different extension retires only exact old source after persistence',
    () async {
      final old = await input('data/videos/A/source.mp4', 'old');
      final sentinel = await input('data/videos/A/source.backup', 'keep');
      final chosen = await input('new.mov', 'new');
      await save(
        chosen,
        old: old.path,
        persist: (path, _) async {
          expect(await old.readAsString(), 'old');
          expect(await File(path).readAsString(), 'new');
        },
      );
      expect(await old.exists(), isFalse);
      expect(await sentinel.readAsString(), 'keep');
    },
  );
  test('reject unsafe IDs without touching neighbouring metadata', () async {
    final sentinel = await input('data/projects/A.json', 'keep');
    await expectLater(
      save(await input('new.mp4', 'new'), id: '../projects'),
      throwsFormatException,
    );
    expect(await sentinel.readAsString(), 'keep');
  });

  test(
    'concurrent operation cannot replace a pending project source',
    () async {
      final first = await input('first.mp4', 'first');
      final second = await input('second.mp4', 'second');
      final entered = Completer<void>();
      final release = Completer<void>();
      final pending = save(
        first,
        validate: (file) async {
          entered.complete();
          await release.future;
          return file.readAsString();
        },
      );
      await entered.future;
      await expectLater(save(second), throwsA(isA<VideoSourceCancelled>()));
      release.complete();
      await pending;
      expect(
        await File('${data.path}/videos/A/source.mp4').readAsString(),
        'first',
      );
      expect(await second.readAsString(), 'second');
    },
  );
  test('large copies observe cancellation between bounded chunks', () async {
    final source = File('${root.path}/large.mp4');
    await source.writeAsBytes(List.filled(3 * 1024 * 1024, 7));
    final target = File('${root.path}/partial.mp4');
    var checks = 0;
    await expectLater(
      const VideoFileOperations().copy(
        source,
        target,
        isCurrent: () => ++checks <= 1,
      ),
      throwsA(isA<VideoSourceCancelled>()),
    );
    expect(await source.length(), 3 * 1024 * 1024);
    expect(await target.length(), lessThan(await source.length()));
  });
}
