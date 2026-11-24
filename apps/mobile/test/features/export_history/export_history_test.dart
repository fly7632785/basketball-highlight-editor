import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const media = MethodChannel('com.bhe.bhe/mobile_media');
  const provider = MethodChannel('plugins.flutter.io/path_provider');
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  late MobileVideoFixture f;
  var failHistory = false, failGalleryHistory = false, failAfterNative = false;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
    final video = await f.file('BHE Mobile/videos/A/source.mp4', 'original');
    f.state.project = f.project(video.path);
    failHistory = false;
    failGalleryHistory = false;
    failAfterNative = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(provider, (_) async {
          final history = f.state.project.exportHistory;
          if ((failHistory && history.isNotEmpty) ||
              (failGalleryHistory &&
                  history.any(
                    (e) => e.files.any((file) => file.savedToGallery),
                  ))) {
            throw PlatformException(code: 'HISTORY_IO');
          }
          return f.root.path;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, (call) async {
          if (call.method == 'registerMergeExport') return true;
          if (call.method == 'mergeClips') {
            final path = (call.arguments as Map)['outputPath'] as String;
            final file = File(path);
            await file.parent.create(recursive: true);
            await file.writeAsString('video');
            if (failAfterNative) failHistory = true;
            return {'outputPath': path, 'committed': true};
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          share,
          (_) async => 'dev.fluttercommunity.plus/share/success',
        );
  });
  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(media, null);
    messenger.setMockMethodCallHandler(share, null);
    await f.close();
  });

  test(
    'unique local files, gallery flag, reload and real package strips history',
    () async {
      await f.state.mergeClips();
      final first = f.state.exportedPaths.single;
      expect(await File(first).exists(), isTrue);
      expect(f.state.project.exportHistory.length, 1);
      await f.state.mergeClips();
      final second = f.state.exportedPaths.single;
      expect(second, isNot(first));
      expect(await File(first).readAsString(), 'video');
      expect(f.state.project.exportHistory.length, 2);
      await f.state.saveExportedFiles(paths: [second]);
      expect(
        f.state.project.exportHistory.first.files.single.savedToGallery,
        isTrue,
      );
      await f.state.openProject('A');
      expect(f.state.project.exportHistory.length, 2);
      expect(
        f.state.project.exportHistory.first.files.single.savedToGallery,
        isTrue,
      );
      await f.state.exportProjectPackage();
      final package = File('${f.data.path}/A.bhe');
      final archive = ZipDecoder().decodeBytes(await package.readAsBytes());
      final json = String.fromCharCodes(
        archive.files.firstWhere((e) => e.name == 'project.json').content
            as List<int>,
      );
      expect(json, isNot(contains('export_history')));
      f.choose(package);
      await f.state.importProject();
      expect(f.state.project.exportHistory, isEmpty);
    },
  );

  test(
    'history write failure keeps exported file and exposes feedback warning',
    () async {
      failHistory = true;
      await f.state.mergeClips();
      expect(f.state.exportedPaths.length, 1);
      expect(await File(f.state.exportedPaths.single).exists(), isTrue);
      expect(f.state.project.exportHistory, isEmpty);
      expect(f.state.exportHistoryWarning, '视频已导出，历史记录保存失败。');
      expect(f.state.errorMessage, isNull);
      expect(f.state.diagnosticError, isNotNull);
    },
  );

  test('gallery success survives history update failure', () async {
    await f.state.mergeClips();
    failGalleryHistory = true;
    await f.state.saveExportedFiles();
    expect(
      f.state.project.exportHistory.single.files.single.savedToGallery,
      isFalse,
    );
    expect(f.state.exportHistoryWarning, '已保存到相册，历史记录更新失败。');
    expect(f.state.errorMessage, isNull);
    expect(f.state.diagnosticError, isNotNull);
    failGalleryHistory = false;
    await f.state.saveExportedFiles();
    expect(
      f.state.project.exportHistory.single.files.single.savedToGallery,
      isTrue,
    );
    expect(f.state.exportHistoryWarning, isNull);
  });

  test(
    'history actions reject traversal and symbolic links out of project',
    () async {
      final outside = await f.file('outside.mp4', 'other');
      final root = Directory('${f.data.path}/exports/A');
      await root.create(recursive: true);
      await Link('${root.path}/escape.mp4').create(outside.path);
      expect(
        await f.state.exportHistoryFilePath(
          const ExportHistoryFile(name: 'x', relativePath: '../../outside.mp4'),
        ),
        isNull,
      );
      expect(
        await f.state.exportHistoryFilePath(
          const ExportHistoryFile(name: 'x', relativePath: 'escape.mp4'),
        ),
        isNull,
      );
    },
  );
  test('a failed export duration write preserves previous history', () async {
    await f.state.mergeClips();
    final previous = f.state.project.exportHistory.single.id;
    failAfterNative = true;
    await f.state.mergeClips();
    expect(f.state.project.exportHistory.single.id, previous);
    failHistory = false;
    final persisted = const ProjectPackageCodec().decode(
      await File('${f.data.path}/projects/A.json').readAsString(),
      includeLocalHistory: true,
    );
    expect(persisted.exportHistory.single.id, previous);
  });
  test('partial separate export records only committed files', () async {
    f.state.project = f.state.project.copyWith(
      candidates: const [
        Candidate(id: 'one', startMs: 1, endMs: 500, eventMs: 100),
        Candidate(id: 'two', startMs: 600, endMs: 1000, eventMs: 700),
      ],
    );
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, (call) async {
          if (call.method == 'exportClip') {
            if (++calls == 2) throw PlatformException(code: 'IO_FAILURE');
            final target = File(
              (call.arguments as Map)['outputPath'] as String,
            );
            await target.parent.create(recursive: true);
            await target.writeAsString('video');
          }
          return null;
        });
    await f.state.exportClips();
    final entry = f.state.project.exportHistory.single;
    expect(entry.mode, 'clips');
    expect(entry.plannedCount, 2);
    expect(entry.files.length, 1);
    expect(entry.isPartial, isTrue);
    expect(f.state.errorMessage, isNotNull);
  });
  test('late gallery reply cannot update the next project', () async {
    await f.state.mergeClips();
    final entered = Completer<void>(), release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, (call) async {
          if (call.method == 'saveToLibrary') {
            entered.complete();
            await release.future;
          }
          return null;
        });
    final pending = f.state.saveExportedFiles();
    await entered.future;
    await f.state.createNewProject();
    final next = f.state.project.id;
    release.complete();
    await pending;
    expect(f.state.project.id, next);
    expect(f.state.project.exportHistory, isEmpty);
    final old = const ProjectPackageCodec().decode(
      await File('${f.data.path}/projects/A.json').readAsString(),
      includeLocalHistory: true,
    );
    expect(old.exportHistory.single.files.single.savedToGallery, isFalse);
  });
  test(
    'history cap removes metadata only, not previously exported files',
    () async {
      await f.state.mergeClips();
      final oldFile = f.state.exportedPaths.single;
      final oldEntry = f.state.project.exportHistory.single;
      f.state.project = f.state.project.copyWith(
        exportHistory: [
          for (var i = 0; i < 50; i++)
            ExportHistoryEntry(
              id: 'old-$i',
              createdAt: oldEntry.createdAt,
              mode: oldEntry.mode,
              plannedCount: 1,
              durationMs: 1,
              files: oldEntry.files,
            ),
        ],
      );
      await f.state.mergeClips();
      expect(f.state.project.exportHistory.length, 50);
      expect(
        f.state.project.exportHistory
            .where((entry) => entry.id.startsWith('old-'))
            .length,
        49,
      );
      expect(await File(oldFile).exists(), isTrue);
    },
  );
  test(
    'history failure does not hide an earlier partial export failure',
    () async {
      f.state.project = f.state.project.copyWith(
        candidates: const [
          Candidate(id: 'one', startMs: 1, endMs: 500, eventMs: 100),
          Candidate(id: 'two', startMs: 600, endMs: 1000, eventMs: 700),
        ],
      );
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(media, (call) async {
            if (call.method == 'exportClip') {
              if (++calls == 2) {
                failHistory = true;
                throw PlatformException(code: 'IO_FAILURE');
              }
              final target = File(
                (call.arguments as Map)['outputPath'] as String,
              );
              await target.parent.create(recursive: true);
              await target.writeAsString('video');
            }
            return null;
          });
      await f.state.exportClips();
      expect(f.state.exportedPaths.length, 1);
      expect(f.state.errorMessage, isNotNull);
      expect(f.state.exportHistoryWarning, '视频已导出，历史记录保存失败。');
      expect(f.state.project.exportHistory, isEmpty);
    },
  );
  test('renaming a non-current project retains its local history', () async {
    await f.state.mergeClips();
    final entry = f.state.project.exportHistory.single;
    final other = f.state.project.copyWith(
      id: 'B',
      name: 'Other',
      exportHistory: [entry],
    );
    final file = await f.file(
      'BHE Mobile/projects/B.json',
      const ProjectPackageCodec().encode(other, includeLocalHistory: true),
    );
    expect(await f.state.renameManagedProject('B', 'Renamed'), isTrue);
    final loaded = const ProjectPackageCodec().decode(
      await file.readAsString(),
      includeLocalHistory: true,
    );
    expect(loaded.name, 'Renamed');
    expect(loaded.exportHistory.single.id, entry.id);
    expect(f.state.project.id, 'A');
  });
  test(
    'drain timeout persists completed clips without waiting for a hung native call',
    () async {
      final project = f.state.project;
      f.state.dispose();
      f.state = MobileAppState(
        videoProbe: MobileVideoFixture.inspect,
        exportDrainTimeout: const Duration(milliseconds: 30),
        exportCancelTimeout: const Duration(milliseconds: 20),
      );
      await f.state.ready;
      f.state.project = project.copyWith(
        candidates: const [
          Candidate(id: 'one', startMs: 1, endMs: 500, eventMs: 100),
          Candidate(id: 'two', startMs: 600, endMs: 1000, eventMs: 700),
        ],
      );
      final entered = Completer<void>(), release = Completer<Object?>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(media, (call) async {
            if (call.method == 'exportClip') {
              if (++calls == 2) {
                entered.complete();
                return release.future;
              }
              final target = File(
                (call.arguments as Map)['outputPath'] as String,
              );
              await target.parent.create(recursive: true);
              await target.writeAsString('video');
            }
            return null;
          });
      final pending = f.state.exportClips();
      await entered.future;
      await f.state.cancelExport();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await f.state.pendingProjectWrites;
      expect(f.state.hasUncertainExport, isTrue);
      expect(f.state.project.exportHistory.single.isPartial, isTrue);
      expect(f.state.project.exportHistory.single.files.length, 1);
      final persisted = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
        includeLocalHistory: true,
      );
      expect(persisted.exportHistory.single.files.length, 1);
      release.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await pending;
    },
  );
  test(
    'delayed timeout history cannot take paths from a later export',
    () async {
      final project = f.state.project;
      f.state.dispose();
      f.state = MobileAppState(
        videoProbe: MobileVideoFixture.inspect,
        exportDrainTimeout: const Duration(milliseconds: 30),
        exportCancelTimeout: const Duration(milliseconds: 20),
      );
      await f.state.ready;
      f.state.project = project.copyWith(
        candidates: const [
          Candidate(id: 'one', startMs: 1, endMs: 500, eventMs: 100),
          Candidate(id: 'two', startMs: 600, endMs: 1000, eventMs: 700),
        ],
      );
      final entered = Completer<void>(), oldReply = Completer<Object?>();
      final historyEntered = Completer<void>(),
          historyRelease = Completer<void>();
      var calls = 0, blockedHistory = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(provider, (_) async {
            if (f.state.hasUncertainExport && !blockedHistory) {
              blockedHistory = true;
              historyEntered.complete();
              await historyRelease.future;
            }
            return f.root.path;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(media, (call) async {
            if (call.method == 'exportClip') {
              if (++calls == 2) {
                entered.complete();
                return oldReply.future;
              }
              final target = File(
                (call.arguments as Map)['outputPath'] as String,
              );
              await target.parent.create(recursive: true);
              await target.writeAsString('old');
            }
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              final target = File(
                (call.arguments as Map)['outputPath'] as String,
              );
              await target.parent.create(recursive: true);
              await target.writeAsString('new');
              return {'outputPath': target.path, 'committed': true};
            }
            if (call.method == 'isExportActive') return false;
            return null;
          });
      final old = f.state.exportClips();
      await entered.future;
      await f.state.cancelExport();
      await historyEntered.future.timeout(const Duration(seconds: 2));
      expect(await f.state.checkUncertainExport(), TaskStopStatus.stopped);
      await pumpEventQueue();
      await f.state.mergeClips();
      expect(f.state.project.exportHistory.single.mode, 'merged');
      historyRelease.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await f.state.pendingProjectWrites;
      expect(f.state.project.exportHistory.map((entry) => entry.mode), [
        'merged',
        'clips',
      ]);
      expect(
        f.state.project.exportHistory.last.files.single.relativePath,
        contains('clips_'),
      );
      expect(
        f.state.project.exportHistory.first.files.single.relativePath,
        contains('merge_'),
      );
      oldReply.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await old;
    },
  );
  test(
    'export history retains a real label named untagged',
    () async {
      f.state.project = f.state.project.copyWith(
        candidates: const [
          Candidate(
            id: 'one',
            startMs: 1,
            endMs: 500,
            eventMs: 100,
            player: '未标记',
          ),
          Candidate(id: 'two', startMs: 600, endMs: 1000, eventMs: 700),
        ],
      );
      await f.state.exportByLabels();
      expect(
        f.state.project.exportHistory.single.files.map((file) => file.untagged),
        [false],
      );
      await f.state.openProject('A');
      expect(
        f.state.project.exportHistory.single.files.map((file) => file.untagged),
        [false],
      );
    },
  );
  test('gallery timeout cannot create a duplicate export record', () async {
    final project = f.state.project;
    f.state.dispose();
    f.state = MobileAppState(
      videoProbe: MobileVideoFixture.inspect,
      exportDrainTimeout: const Duration(milliseconds: 30),
      exportCancelTimeout: const Duration(milliseconds: 20),
    );
    await f.state.ready;
    f.state.project = project;
    await f.state.mergeClips();
    expect(f.state.project.exportHistory.length, 1);
    final entered = Completer<void>(), release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, (call) async {
          if (call.method == 'saveToLibrary') {
            entered.complete();
            await release.future;
          }
          return null;
        });
    final pending = f.state.saveExportedFiles();
    await entered.future;
    await f.state.cancelExport();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await f.state.pendingProjectWrites;
    expect(f.state.project.exportHistory.length, 1);
    release.complete();
    await pending;
  });
}
