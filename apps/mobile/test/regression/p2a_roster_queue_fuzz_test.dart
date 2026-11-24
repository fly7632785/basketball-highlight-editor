// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart'
    as diag;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class Engine extends MobileAnalysisEngineUnavailable {
  int calls = 0;
  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    Roi? rimRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) async* {
    calls++;
    yield const AnalysisProgress(
      stage: AnalysisStage.completed,
      progress: 1,
      message: 'done',
      candidates: [],
    );
  }
}

class LogSink implements diag.DiagnosticBackend {
  final lines = <String>[];
  @override
  Future<void> initialize(String v, String l) async {}
  @override
  Future<void> append(String m, String? k) async {
    lines.add(m);
  }

  @override
  Future<diag.DiagnosticSnapshot> snapshot() async =>
      diag.DiagnosticSnapshot(lines: lines, available: true);
}

Future<void> until(bool Function() condition, String label) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

List<String> names(ProjectSnapshot p) => p.players;
Future<ProjectSnapshot> disk(MobileVideoFixture f, String id) async =>
    const ProjectPackageCodec().decode(
      await File('${f.data.path}/projects/$id.json').readAsString(),
    );

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'queued roster intent is revalidated before mutation',
    () async {
      final start =
          int.tryParse(Platform.environment['P2A_INTERLEAVE_START'] ?? '') ?? 0;
      final count = regressionSeedCount('P2A_INTERLEAVE_COUNT');
      final outcomes = <Map<String, Object?>>[], coverage = <String, int>{};
      final previous = diag.MobileDiagnostics.instance;
      for (var seed = start; seed < start + count; seed++) {
        final random = Random(seed + 73000);
        final action = [
          'cancel',
          'replace',
          'delete',
          'recreate',
          'switch',
          'members',
          'valid',
        ][random.nextInt(7)];
        final first = ['note', 'rename', 'add'][random.nextInt(3)];
        final fail = random.nextBool();
        final description =
            'seed=$seed first=$first first_fails=$fail invalidation=$action';
        coverage['$action/$first/${fail ? 'fail' : 'success'}'] =
            (coverage['$action/$first/${fail ? 'fail' : 'success'}'] ?? 0) + 1;
        final f = MobileVideoFixture(), engine = Engine(), log = LogSink();
        diag.MobileDiagnostics.instance = diag.MobileDiagnostics(log);
        var initialized = false;
        Completer<void>? release;
        Future<bool>? prior;
        Future<void>? pendingAnalysis, invalidation;
        Future<bool>? recreate;
        final errors = <String>[];
        Map<String, Object?> observed = {};
        try {
          await f.init(engine: engine);
          initialized = true;
          final video = await f.file('original.mp4', 'original');
          f.state.project = f.project(video.path).copyWith(players: []);
          f.state.playerGroups = [
            (name: 'Team', players: ['Bob']),
          ];
          final draft = f.state.rosterSelection;
          draft.choose('Team', ['Bob']);
          if (!await f.state.renameProject('Baseline')) {
            throw StateError('baseline write failed');
          }
          final baseline = f.state.project;
          if (action == 'replace') {
            f.choose(await f.file('replacement.mp4', 'replacement'));
          }
          final entered = Completer<void>();
          release = Completer<void>();
          var firstPath = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (_) async {
                  if (firstPath) {
                    firstPath = false;
                    entered.complete();
                    await release!.future;
                    if (fail) {
                      throw PlatformException(code: 'injected_prior_write');
                    }
                  }
                  return f.root.path;
                },
              );
          prior = switch (first) {
            'note' => f.state.updateCandidateNote('goal', 'queued note'),
            'rename' => f.state.renameProject('Queued name'),
            _ => f.state.addPlayer('Seed'),
          };
          await entered.future.timeout(const Duration(seconds: 5));
          final beforeQueue = f.state.pendingProjectWrites;
          pendingAnalysis = f.state.startAnalysis(
            rosterPlayers: ['Bob'],
            expectedRosterGroup: 'Team',
            expectedProjectId: f.state.project.id,
            expectedSession: f.state.projectSession,
            expectedVideoGeneration: f.state.videoPreparationGeneration,
          );
          await until(
            () => !identical(beforeQueue, f.state.pendingProjectWrites),
            'roster did not enter project queue',
          );
          if (engine.calls != 0) {
            throw StateError('engine started while queue blocked');
          }
          switch (action) {
            case 'cancel':
              invalidation = f.state.cancelAnalysis();
              await until(() => !f.state.analysing, 'cancel intent');
            case 'replace':
              invalidation = f.state.pickVideo();
              await until(
                () => !f.state.analysing,
                'replace cancelled analysis',
              );
            case 'switch':
              invalidation = f.state.createNewProject();
              await until(() => f.state.projectTransitioning, 'switch barrier');
            case 'delete':
              if (!await f.state.deletePlayerGroup('Team')) {
                throw StateError('delete failed');
              }
            case 'recreate':
              if (!await f.state.deletePlayerGroup('Team')) {
                throw StateError('delete failed');
              }
              recreate = f.state.savePlayerGroup('Team');
            case 'members':
              if (!await f.state.editPlayerGroup('Team', 'Team', ['Carol'])) {
                throw StateError('edit failed');
              }
            case 'valid':
              break;
          }
          release.complete();
          final firstOk = await prior.timeout(const Duration(seconds: 10));
          if (firstOk == fail) {
            errors.add('first write result expected ${!fail} got $firstOk');
          }
          await pendingAnalysis.timeout(const Duration(seconds: 10));
          if (invalidation != null) {
            await invalidation.timeout(const Duration(seconds: 10));
          }
          if (recreate != null &&
              !await recreate.timeout(const Duration(seconds: 10))) {
            throw StateError('recreate failed');
          }
          await f.state.pendingProjectWrites.timeout(
            const Duration(seconds: 10),
          );
          final persisted = await disk(f, 'A');
          final oldExpected = <String>[
            if (first == 'add' && !fail) 'Seed',
            if (action == 'valid') 'Bob',
          ];
          final liveExpected = action == 'switch' ? <String>[] : oldExpected;
          final expectedEngine = action == 'valid' ? 1 : 0;
          // Replacement intentionally clears the old candidate; switching creates a new empty project.
          final oldCandidateExpected = action == 'valid' || action == 'replace'
              ? 0
              : 1;
          final liveCandidateExpected = action == 'switch'
              ? 0
              : oldCandidateExpected;
          final originalExpectedNote = first == 'note' && !fail
              ? 'queued note'
              : baseline.candidates.single.note;
          observed = {
            'live': names(f.state.project),
            'disk': names(persisted),
            'engine': engine.calls,
            'live_candidates': f.state.project.candidates.length,
            'disk_candidates': persisted.candidates.length,
            'disk_note': persisted.candidates.isEmpty
                ? null
                : persisted.candidates.single.note,
            'active_project': f.state.project.id,
            'first_ok': firstOk,
          };
          void check(bool ok, String label) {
            if (!ok) errors.add(label);
          }

          check(
            jsonEncode(names(f.state.project)) == jsonEncode(liveExpected),
            'live roster expected=$liveExpected got=${names(f.state.project)}',
          );
          check(
            jsonEncode(names(persisted)) == jsonEncode(oldExpected),
            'disk roster expected=$oldExpected got=${names(persisted)}',
          );
          check(
            engine.calls == expectedEngine,
            'engine expected=$expectedEngine got=${engine.calls}',
          );
          check(
            persisted.candidates.length == oldCandidateExpected,
            'disk candidates expected=$oldCandidateExpected got=${persisted.candidates.length}',
          );
          check(
            f.state.project.candidates.length == liveCandidateExpected,
            'live candidates expected=$liveCandidateExpected got=${f.state.project.candidates.length}',
          );
          if (oldCandidateExpected == 1 && persisted.candidates.length == 1) {
            check(
              persisted.candidates.single.note == originalExpectedNote,
              'prior note was not preserved',
            );
          }
          if (oldCandidateExpected == 1 && persisted.candidates.length == 1) {
            final normalized = const ProjectPackageCodec()
                .decode(const ProjectPackageCodec().encode(baseline))
                .candidates
                .single;
            final candidateExpected = first == 'note' && !fail
                ? normalized.copyWith(note: 'queued note')
                : normalized;
            check(
              jsonEncode(persisted.candidates.single.toJson()) ==
                  jsonEncode(candidateExpected.toJson()),
              'disk candidate content mismatch expected=${jsonEncode(candidateExpected.toJson())} actual=${jsonEncode(persisted.candidates.single.toJson())}',
            );
            if (action != 'switch' && f.state.project.candidates.length == 1) {
              check(
                jsonEncode(
                      const ProjectPackageCodec()
                          .decode(
                            const ProjectPackageCodec().encode(f.state.project),
                          )
                          .candidates
                          .single
                          .toJson(),
                    ) ==
                    jsonEncode(candidateExpected.toJson()),
                'live candidate content mismatch',
              );
            }
          }
          if (action == 'replace') {
            check(
              f.state.project.video?.name == 'replacement.mp4',
              'replacement did not finish',
            );
          }
          check(
            persisted.name ==
                (first == 'rename' && !fail ? 'Queued name' : 'Baseline'),
            'prior project name mismatch',
          );
          if (fail) {
            check(
              log.lines.any((line) => line.contains('app error: project')),
              'prior failure has no diagnostic',
            );
          }
          if (action == 'switch') {
            check(f.state.project.id != 'A', 'switch did not complete');
          }
        } catch (e, stack) {
          errors.add('HARNESS $e\n$stack');
        } finally {
          if (release != null && !release.isCompleted) release.complete();
          try {
            if (prior != null) await prior.timeout(const Duration(seconds: 10));
            if (pendingAnalysis != null) {
              await pendingAnalysis.timeout(const Duration(seconds: 10));
            }
            if (invalidation != null) {
              await invalidation.timeout(const Duration(seconds: 10));
            }
            if (initialized) {
              await f.state.pendingProjectWrites.timeout(
                const Duration(seconds: 10),
              );
            }
          } catch (e) {
            errors.add('HARNESS cleanup wait $e');
          }
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/path_provider'),
                  (_) async => f.root.path,
                );
            try {
              await f.close();
            } catch (e) {
              errors.add('HARNESS cleanup $e');
            }
          }
        }
        outcomes.add({
          'seed': seed,
          'scenario': description,
          'action': action,
          'first': first,
          'first_fails': fail,
          'observed': observed,
          'errors': errors,
        });
      }
      diag.MobileDiagnostics.instance = previous;
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final result = {
        'base': 'current checkout',
        'count': count,
        'coverage': coverage,
        'failures': failures,
        'outcomes': outcomes,
      };
      final path = Platform.environment['P2A_INTERLEAVE_RESULT'];
      if (path != null) {
        await File(
          path,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      }
      print('INTERLEAVE_SUMMARY seeds=$count failures=${failures.length}');
      for (final action in [
        'cancel',
        'replace',
        'delete',
        'recreate',
        'switch',
        'members',
        'valid',
      ]) {
        final subset = outcomes.where((o) => o['action'] == action).toList();
        final failed = subset
            .where((o) => (o['errors'] as List).isNotEmpty)
            .length;
        print('ACTION $action count=${subset.length} failures=$failed');
      }
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST_FAILURE ${jsonEncode(failures.first)}',
        );
      }
      expect(
        failures.length,
        0,
        reason: 'see P2A_INTERLEAVE_RESULT for each reproducible scenario',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
