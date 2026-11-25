// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart'
    as diag;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class Sink implements diag.DiagnosticBackend {
  final lines = <String>[];
  @override
  Future<void> initialize(String a, String b) async {}
  @override
  Future<void> append(String m, String? k) async {
    lines.add(m);
  }

  @override
  Future<diag.DiagnosticSnapshot> snapshot() async =>
      diag.DiagnosticSnapshot(lines: lines, available: true);
}

Future<void> until(bool Function() c, String text) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!c()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(text);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native analysis cancellation interleavings',
    () async {
      final outcomes = <Map<String, Object?>>[];
      final count = regressionSeedCount('P6_COUNT');
      const native = MethodChannel('com.bhe.bhe/mobile_analysis'),
          events = MethodChannel('com.bhe.bhe/mobile_analysis_progress'),
          paths = MethodChannel('plugins.flutter.io/path_provider');
      final oldDiag = diag.MobileDiagnostics.instance;
      for (var seed = 0; seed < count; seed++) {
        final random = Random(seed + 61000),
            phase = [
              'prepare',
              'dispatch',
              'progress',
              'clear',
            ][random.nextInt(4)],
            action = ['cancel', 'retry', 'switch'][random.nextInt(3)];
        final cancelFails =
            phase != 'prepare' && action == 'cancel' && random.nextInt(4) == 0;
        final f = MobileVideoFixture(),
            sink = Sink(),
            modelEntered = Completer<void>(),
            modelRelease = Completer<String>(),
            nativeEntered = Completer<void>(),
            nativeResult = Completer<Object?>(),
            clearEntered = Completer<void>(),
            clearRelease = Completer<void>();
        final errors = <String>[];
        var initialized = false, preps = 0, starts = 0, cancels = 0;
        var workerActive = true;
        Future<void>? old, transition, retry;
        diag.MobileDiagnostics.instance = diag.MobileDiagnostics(sink);
        try {
          final engine = NativeAnalysisEngine(
            modelPreparer: () {
              preps++;
              if (phase == 'prepare' && preps == 1) {
                modelEntered.complete();
                return modelRelease.future;
              }
              return Future.value('/model-$preps');
            },
          );
          await f.init(engine: engine);
          initialized = true;
          final file = await f.file('original.mp4', 'original');
          f.state.project = f.project(file.path);
          if (!await f.state.updateCandidateNote('goal', 'keep')) {
            throw StateError('baseline note failed');
          }
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(events, (_) async => null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(native, (call) async {
                if (call.method == 'analyzeVideo') {
                  starts++;
                  if (starts == 1 && !(phase == 'prepare' && preps > 1)) {
                    nativeEntered.complete();
                    return nativeResult.future;
                  }
                  return {'candidates': <Object>[]};
                }
                if (call.method == 'isAnalysisActive') return workerActive;
                if (call.method == 'cancelAnalysis') {
                  cancels++;
                  if (cancelFails) {
                    throw PlatformException(
                      code: 'injected_native_cancel_failure',
                    );
                  }
                }
                return null;
              });
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(paths, (_) async {
                if (phase == 'clear' &&
                    !clearEntered.isCompleted &&
                    f.state.project.lastAnalysisStatus == 'running') {
                  clearEntered.complete();
                  await clearRelease.future;
                }
                return f.root.path;
              });
          old = f.state.startAnalysis(
            rosterPlayers: random.nextBool() ? ['Bob'] : null,
          );
          if (phase == 'prepare') {
            await modelEntered.future.timeout(const Duration(seconds: 5));
          } else {
            await nativeEntered.future.timeout(const Duration(seconds: 5));
            if (phase == 'progress' || phase == 'clear') {
              final data = const StandardMethodCodec().encodeSuccessEnvelope({
                'stage': 'coarseScan',
                'progress': 0.1,
                'message': 'running',
              });
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .handlePlatformMessage(
                    'com.bhe.bhe/mobile_analysis_progress',
                    data,
                    (_) {},
                  );
              if (phase == 'clear') {
                await clearEntered.future.timeout(const Duration(seconds: 5));
              } else {
                await until(
                  () =>
                      f.state.project.lastAnalysisStatus == 'running' &&
                      !f.state.canUndoReview,
                  'first progress commit',
                );
              }
            }
          }
          if (action == 'switch') {
            transition = f.state.createNewProject();
          } else {
            transition = f.state.cancelAnalysis();
          }
          if (phase == 'clear') {
            await until(
              () => !f.state.analysing || cancelFails,
              'cancel accepted while clear blocked',
            );
            clearRelease.complete();
          }
          await transition.timeout(const Duration(seconds: 10));
          if (cancelFails) {
            if (!f.state.analysing ||
                f.state.diagnosticError == null ||
                !sink.lines.any((x) => x.contains('analysis.cancel'))) {
              errors.add('failed native cancel not surfaced');
            }
          } else if (phase == 'prepare' ||
              phase == 'dispatch' ||
              phase == 'clear') {
            final saved = const ProjectPackageCodec().decode(
              await File('${f.data.path}/projects/A.json').readAsString(),
            );
            if (saved.candidates.length != 1 ||
                saved.candidates.single.note != 'keep') {
              errors.add('old disk review lost before startup completed');
            }
            if (action != 'switch' &&
                (f.state.project.candidates.length != 1 ||
                    f.state.project.candidates.single.note != 'keep' ||
                    !f.state.canUndoReview)) {
              errors.add('old live review/undo lost before startup completed');
            }
          }
          if (phase == 'prepare' && !cancelFails && starts != 0) {
            errors.add('cancelled preparation started native');
          }
          if (phase != 'prepare' && cancels == 0) {
            errors.add('native dispatch was not cancelled');
          }
          if (action == 'retry' && phase == 'prepare') {
            retry = f.state.startAnalysis();
            await retry.timeout(const Duration(seconds: 10));
            if (starts != 1) errors.add('new retry failed to start');
          } else if (action == 'retry') {
            await f.state.startAnalysis();
            if (starts != 1) {
              errors.add('retry started before native exit confirmed');
            }
          }
          if (!modelRelease.isCompleted) modelRelease.complete('/old-model');
          if (!nativeResult.isCompleted) {
            nativeResult.complete({'candidates': <Object>[]});
          }
          await old.timeout(const Duration(seconds: 10));
          workerActive = false;
          for (var i = 0; i < 50 && f.state.hasUncertainAnalysis; i++) {
            await f.state.checkUncertainAnalysis();
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
          if (action == 'retry' && phase != 'prepare') {
            retry = f.state.startAnalysis();
            await retry.timeout(const Duration(seconds: 10));
            if (starts != 2) {
              errors.add('new retry failed after confirmed exit');
            }
          }
          await f.state.pendingProjectWrites.timeout(
            const Duration(seconds: 10),
          );
          if (phase == 'prepare' && action != 'retry' && starts != 0) {
            errors.add('old model caused late native start');
          }
          if (action == 'switch' && f.state.project.id == 'A') {
            errors.add('switch failed');
          }
          if (action == 'retry' && f.state.stage != AnalysisStage.completed) {
            errors.add('retry did not complete');
          }
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (!modelRelease.isCompleted) modelRelease.complete('/old-model');
          if (!nativeResult.isCompleted) {
            nativeResult.complete({'candidates': <Object>[]});
          }
          if (!clearRelease.isCompleted) clearRelease.complete();
          try {
            if (old != null) await old.timeout(const Duration(seconds: 5));
            if (transition != null) {
              await transition.timeout(const Duration(seconds: 5));
            }
            if (retry != null) await retry.timeout(const Duration(seconds: 5));
          } catch (e) {
            errors.add('HARNESS drain $e');
          }
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(native, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(events, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(paths, (_) async => f.root.path);
            try {
              await f.close();
            } catch (e) {
              errors.add('HARNESS close $e');
            }
          }
        }
        outcomes.add({
          'seed': seed,
          'phase': phase,
          'action': action,
          'cancelFails': cancelFails,
          'starts': starts,
          'cancels': cancels,
          'preparations': preps,
          'errors': errors,
        });
      }
      diag.MobileDiagnostics.instance = oldDiag;
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final result = {
        'commit': 'de28260',
        'outcomes': outcomes,
        'failures': failures,
      };
      final p = Platform.environment['P6_RESULTS'];
      if (p != null) {
        await File(
          p,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      }
      print('ANALYSIS_SUMMARY count=$count failures=${failures.length}');
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST ${jsonEncode(failures.first)}',
        );
      }
      expect(failures.length, 0);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
  test(
    'overlapping model preparation leaves current model and no stale temp files',
    () async {
      final dir = await Directory.systemTemp.createTemp('p6_native_model_');
      final both = Completer<void>(), release = Completer<void>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async {
              calls++;
              if (calls == 2) both.complete();
              await release.future;
              return dir.path;
            },
          );
      try {
        final engine = NativeAnalysisEngine();
        final first = engine.prepareAnalysis().then<Object?>(
          (v) => v,
          onError: (Object e) => e,
        );
        final second = engine.prepareAnalysis();
        await both.future.timeout(const Duration(seconds: 10));
        release.complete();
        final firstResult = await first.timeout(const Duration(seconds: 30));
        final secondResult = await second.timeout(const Duration(seconds: 30));
        expect(secondResult, isNotNull);
        final model = File(secondResult!.modelPath);
        expect(await model.exists(), isTrue);
        final bytes = await rootBundle.load('assets/models/bball_model.onnx');
        expect(await model.length(), bytes.lengthInBytes);
        final temporary = await model.parent
            .list()
            .where((item) => item.path.endsWith('.tmp'))
            .toList();
        expect(temporary, isEmpty);
        print(
          'MODEL_OVERLAP first=${firstResult.runtimeType} second_exists=true temp_remaining=0',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
