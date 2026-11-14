// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

Future<void> waitFor(
  bool Function() test,
  String label, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '2-3 export actions while native worker has not returned',
    () async {
      final count = regressionSeedCount('P6_SEQUENCE_COUNT'),
          start =
              int.tryParse(Platform.environment['P6_SEQUENCE_START'] ?? '') ??
              0;
      final outcomes = <Map<String, Object?>>[];
      const channel = MethodChannel('com.bhe.bhe/mobile_media'),
          pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      for (var seed = start; seed < start + count; seed++) {
        final random = Random(seed + 81000),
            scenario = random.nextInt(6),
            oldMode = random.nextBool() ? 'merge' : 'separate',
            newMode = random.nextBool() ? 'merge' : 'separate';
        final f = MobileVideoFixture(),
            entered = Completer<void>(),
            oldResult = Completer<Object?>();
        final issues = <String>[],
            trace = <String>[],
            cancels = <String?>[],
            ids = <String>[],
            paths = <String>[];
        final futures = <Future<void>>[];
        var initialized = false, calls = 0, active = 0, maxActive = 0;
        Future<void>? old;
        bool oldReleased = false, queued = false, timeoutObserved = false;
        try {
          await f.init(
            exportEngine: NativeMediaExportEngine(
              drainTimeout: const Duration(milliseconds: 100),
            ),
            exportCancelTimeout: const Duration(milliseconds: 50),
            exportDrainTimeout: const Duration(milliseconds: 70),
          );
          initialized = true;
          final file = await f.file('original.mp4', 'original');
          f.state.project = f.project(file.path);
          if (!await f.state.renameProject('Baseline')) {
            throw StateError('baseline save failed');
          }
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'registerMergeExport') {
                  ids.add((call.arguments as Map)['exportId'] as String);
                  return true;
                }
                if (call.method == 'cancelExport') {
                  cancels.add((call.arguments as Map?)?['exportId'] as String?);
                  return null;
                }
                if (call.method == 'mergeClips' ||
                    call.method == 'exportClip') {
                  calls++;
                  active++;
                  maxActive = max(maxActive, active);
                  paths.add((call.arguments as Map)['outputPath'] as String);
                  if (calls == 1) {
                    entered.complete();
                    try {
                      return await oldResult.future;
                    } finally {
                      active--;
                    }
                  }
                  active--;
                  return {
                    'outputPath': (call.arguments as Map)['outputPath'],
                    'committed': true,
                  };
                }
                return null;
              });
          old = oldMode == 'merge'
              ? f.state.mergeClips()
              : f.state.exportClips();
          await entered.future.timeout(const Duration(seconds: 3));
          trace.add('start $oldMode (native held)');
          Future<void> switchB() async {
            trace.add('switch B');
            await f.state.createNewProject();
            f.state.project = f.project(file.path, id: 'B');
            queued = false;
          }

          Future<void> returnA() async {
            trace.add('return A');
            await f.state.openProject('A');
            queued = false;
            if (f.state.project.id != 'A') issues.add('return A failed');
          }

          Future<void> click(String mode, {bool expectWait = true}) async {
            trace.add('click $mode');
            var done = false;
            final task = mode == 'merge'
                ? f.state.mergeClips()
                : f.state.exportClips();
            futures.add(task);
            unawaited(
              task.then(
                (_) => done = true,
                onError: (Object _, StackTrace _) {
                  done = true;
                },
              ),
            );
            await waitFor(
              () => done || f.state.progressMessage == '正在结束上一次导出',
              'waiter admission',
            );
            if (done && expectWait) {
              issues.add('waiter ended before wait was observed');
            }
            if (!done && f.state.progressMessage == '正在结束上一次导出') {
              queued = true;
              if (!f.state.exporting) issues.add('waiting UI exporting false');
            }
          }

          Future<void> cancel() async {
            trace.add('cancel');
            final before = cancels.length,
                wasQueued = queued && f.state.exporting;
            await f.state.cancelExport();
            if (wasQueued && cancels.length != before) {
              issues.add('cancelled waiter touched old native task');
            }
            if (wasQueued) queued = false;
          }

          Future<void> checkHeld() async {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            if (calls != 1 || active != 1 || maxActive > 1) {
              issues.add(
                'native overlapped while old worker held calls=$calls active=$active max=$maxActive',
              );
            }
          }

          // Every scenario executes 2 or 3 explicit actions; modes and variant are seeded.
          switch (scenario) {
            case 0:
              await switchB();
              await click(newMode);
              await cancel();
            case 1:
              await switchB();
              await returnA();
              await click(newMode);
            case 2:
              await cancel();
              await waitFor(() => !f.state.exporting, 'cancel drain timer');
              await click(newMode, expectWait: !f.state.hasUncertainExport);
              await cancel();
            case 3:
              await switchB();
              await click(newMode);
              await click(
                newMode == 'merge' ? 'separate' : 'merge',
                expectWait: false,
              );
            case 4:
              await switchB();
              await click(newMode);
              trace.add('hold past drain timeout');
              await waitFor(
                () => !f.state.exporting,
                'queued timeout',
                timeout: const Duration(seconds: 2),
              );
              timeoutObserved = true;
              if (f.state.errorMessage != '上一次导出尚未结束，请稍后重试。') {
                issues.add(
                  'no actionable timeout message: ${f.state.errorMessage}',
                );
              }
            case 5:
              await switchB();
              await click(newMode);
          }
          await checkHeld();
          oldResult.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
          oldReleased = true;
          await old.timeout(const Duration(seconds: 5));
          for (final future in futures) {
            await future.timeout(const Duration(seconds: 5));
          }
          await f.state.pendingProjectWrites.timeout(
            const Duration(seconds: 5),
          );
          if ((scenario == 0 || scenario == 2 || scenario == 4) && calls != 1) {
            issues.add('cancelled or timed-out waiter later started native');
          }
          if ((scenario == 1 || scenario == 3 || scenario == 5) && calls != 2) {
            issues.add('eligible waiter failed to start after drain');
          }
          if (active != 0) issues.add('native still active after cleanup');
          if (maxActive > 1) issues.add('native overlap max=$maxActive');
        } catch (e, st) {
          issues.add('HARNESS $e\n$st');
        } finally {
          if (!oldReleased && !oldResult.isCompleted) {
            oldResult.completeError(
              PlatformException(code: 'EXPORT_CANCELLED'),
            );
          }
          try {
            if (old != null) await old.timeout(const Duration(seconds: 5));
            for (final future in futures) {
              await future.timeout(const Duration(seconds: 5));
            }
          } catch (e) {
            issues.add('HARNESS drain $e');
          }
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  pathChannel,
                  (_) async => f.root.path,
                );
            try {
              await f.close();
            } catch (e) {
              issues.add('HARNESS close $e');
            }
          }
        }
        outcomes.add({
          'seed': seed,
          'scenario': scenario,
          'oldMode': oldMode,
          'newMode': newMode,
          'trace': trace,
          'calls': calls,
          'maxActive': maxActive,
          'cancels': cancels,
          'ids': ids,
          'paths': paths,
          'timeoutObserved': timeoutObserved,
          'errors': issues,
        });
      }
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      if (start <= 5 && start + count > 5) {
        final seed5 = outcomes.singleWhere((outcome) => outcome['seed'] == 5);
        expect(
          seed5['errors'],
          isEmpty,
          reason:
              'fixed regression: queued export after switch and return (seed 5)',
        );
      }
      final data = {
        'base': 'current checkout',
        'outcomes': outcomes,
        'failures': failures,
      };
      final p = Platform.environment['P6_SEQUENCE_RESULT'];
      if (p != null) {
        await File(
          p,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      }
      print('SEQUENCE_SUMMARY seeds=$count failures=${failures.length}');
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST ${jsonEncode(failures.first)}',
        );
      }
      expect(failures.length, 0);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
