import 'dart:async';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
    final file = await f.file('original.mp4', 'original');
    f.state.project = f
        .project(file.path)
        .copyWith(
          candidates: const [
            Candidate(
              id: 'a',
              startMs: 100,
              endMs: 1000,
              eventMs: 500,
              player: 'Alice',
            ),
            Candidate(
              id: 'b',
              startMs: 1200,
              endMs: 2000,
              eventMs: 1500,
              player: 'Bob',
            ),
            Candidate(id: 'u', startMs: 2200, endMs: 3000, eventMs: 2500),
            Candidate(
              id: 'x',
              startMs: 3200,
              endMs: 4000,
              eventMs: 3500,
              player: 'Alice',
              selection: CandidateSelection.excluded,
            ),
          ],
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await f.close();
  });
  test('one admitted batch merges tags in order and skips untagged clips', () async {
    final clips = <List<dynamic>>[], paths = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map?;
          if (call.method == 'registerMergeExport') return true;
          if (call.method == 'mergeClips') {
            clips.add(args!['clips'] as List<dynamic>);
            paths.add(args['outputPath'] as String);
            return {
              'outputPath': paths.last,
              'committed': true,
              'mergedOverlapCount': 0,
            };
          }
          return null;
        });
    await f.state.exportByLabels();
    expect(clips.map((c) => c.length), [1, 1]);
    expect(paths.toSet().length, 2);
    expect(f.state.exportBatchFiles.map((e) => e.label), [
      'Alice',
      'Bob',
    ]);
    expect(f.state.exportedPaths, paths);
    expect(f.state.exportBatchTotal, 2);
    expect(f.state.exporting, isFalse);
  });
  test('cancel after a committed file stops the remaining groups', () async {
    final releaseStarted = Completer<void>(), release = Completer<void>();
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map?;
          if (call.method == 'registerMergeExport') return true;
          if (call.method == 'mergeClips') {
            calls++;
            return {'outputPath': args!['outputPath'], 'committed': true};
          }
          if (call.method == 'releaseMergeExport') {
            releaseStarted.complete();
            await release.future;
          }
          return null;
        });
    final pending = f.state.exportByLabels();
    await releaseStarted.future;
    await f.state.cancelExport();
    release.complete();
    await pending;
    expect(calls, 1);
    expect(f.state.exportBatchFiles.length, 1);
    expect(f.state.exportBatchTotal, 2);
    expect(f.state.exporting, isFalse);
  });
  test(
    'second group failure keeps first output and records diagnostic',
    () async {
      final batchGroups = <int>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              batchGroups.add(args!['batchGroup'] as int);
              if (batchGroups.length == 2) {
                throw PlatformException(code: 'FAILED');
              }
              return {'outputPath': args['outputPath'], 'committed': true};
            }
            return null;
          });
      await f.state.exportByLabels();
      expect(batchGroups, [1, 2]);
      expect(f.state.exportBatchFiles.length, 1);
      expect(f.state.errorMessage, isNotNull);
      expect(f.state.exporting, isFalse);
    },
  );
  test(
    'batch holds admission before registration and prevents double click',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var registrations = 0, merges = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            if (call.method == 'registerMergeExport') {
              if (++registrations == 1) {
                entered.complete();
                await release.future;
              }
              return true;
            }
            if (call.method == 'mergeClips') {
              merges++;
              return {'outputPath': args!['outputPath'], 'committed': true};
            }
            return null;
          });
      final pending = f.state.exportByLabels();
      await entered.future;
      await f.state.exportByLabels();
      await f.state.mergeClips();
      expect(registrations, 1);
      release.complete();
      await pending;
      expect(merges, 2);
    },
  );
  test(
    'late old batch result cannot populate a newly opened project',
    () async {
      final entered = Completer<void>(), result = Completer<Object?>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              calls++;
              entered.complete();
              return result.future;
            }
            return null;
          });
      final pending = f.state.exportByLabels();
      await entered.future;
      await f.state.createNewProject();
      final newId = f.state.project.id;
      result.complete({'outputPath': 'old.mp4', 'committed': true});
      await pending;
      expect(f.state.project.id, newId);
      expect(f.state.exportedPaths, isEmpty);
      expect(f.state.exportBatchFiles, isEmpty);
      expect(calls, 1);
    },
  );
  test(
    'other engine waits for the entire label batch, not only one group',
    () async {
      final releaseStarted = Completer<void>(), release = Completer<void>();
      final paths = <String>[];
      var releases = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              final path = args!['outputPath'] as String;
              paths.add(path);
              return {'outputPath': path, 'committed': true};
            }
            if (call.method == 'releaseMergeExport' && ++releases == 1) {
              releaseStarted.complete();
              await release.future;
            }
            return null;
          });
      final other = MobileAppState(videoProbe: MobileVideoFixture.inspect);
      await other.ready;
      try {
        other.project = f.state.project.copyWith(id: 'B');
        final batch = f.state.exportByLabels();
        await releaseStarted.future;
        final following = other.mergeClips();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(paths.length, 1);
        release.complete();
        await batch;
        await following;
        expect(paths.length, 3);
        expect(
          paths.take(2).every((path) => path.contains('/labels_')),
          isTrue,
        );
        expect(paths.last, contains('B_merged.mp4'));
      } finally {
        other.dispose();
      }
    },
  );
  test(
    'status check freezes the whole batch before a new export is admitted',
    () async {
      final releaseStarted = Completer<void>(), release = Completer<void>();
      final queryStarted = Completer<void>(), query = Completer<bool>();
      var registrations = 0, merges = 0, releases = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            if (call.method == 'registerMergeExport') {
              registrations++;
              return true;
            }
            if (call.method == 'mergeClips') {
              merges++;
              return {'outputPath': args!['outputPath'], 'committed': true};
            }
            if (call.method == 'releaseMergeExport' && ++releases == 1) {
              releaseStarted.complete();
              await release.future;
            }
            if (call.method == 'isExportActive') {
              queryStarted.complete();
              return query.future;
            }
            return null;
          });
      final batch = f.state.exportByLabels();
      await releaseStarted.future;
      final engine = f.state.exportEngine as NativeMediaExportEngine;
      final status = engine.checkPreviousExport();
      await queryStarted.future;
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(registrations, 1);
      query.complete(false);
      expect(
        await status,
        anyOf(TaskStopStatus.stopped, TaskStopStatus.unknown),
      );
      await batch;
      await pumpEventQueue();
      expect(NativeMediaExportEngine.activeDrain, isNull);
      expect(merges, 1);
      expect(f.state.exportBatchFiles.length, 1);
    },
  );
  test(
    'committed file survives release timeout and protects later exports',
    () async {
      final project = f.state.project;
      f.state.dispose();
      final engine = NativeMediaExportEngine(
        drainTimeout: const Duration(milliseconds: 30),
      );
      f.state = MobileAppState(
        exportEngine: engine,
        videoProbe: MobileVideoFixture.inspect,
      );
      await f.state.ready;
      f.state.project = project;
      final never = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              return {'outputPath': args!['outputPath'], 'committed': true};
            }
            if (call.method == 'releaseMergeExport') {
              await never.future;
              return null;
            }
            if (call.method == 'isExportActive') return false;
            return null;
          });
      await f.state.exportByLabels();
      expect(f.state.exportBatchFiles.length, 1);
      expect(f.state.hasUncertainExport, isTrue);
      expect(f.state.errorMessage, isNull);
      expect(await f.state.checkUncertainExport(), TaskStopStatus.stopped);
      await pumpEventQueue();
      expect(f.state.hasUncertainExport, isFalse);
    },
  );
}
