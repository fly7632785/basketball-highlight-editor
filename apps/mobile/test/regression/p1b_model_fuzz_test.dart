// ignore_for_file: curly_braces_in_flow_control_structures, unnecessary_underscores

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/review_undo/review_action_result.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class LogBackend implements DiagnosticBackend {
  final lines = <String>[];
  @override
  Future<void> initialize(String v, String l) async {}
  @override
  Future<void> append(String m, String? k) async {
    lines.add(m);
  }

  @override
  Future<DiagnosticSnapshot> snapshot() async =>
      DiagnosticSnapshot(lines: lines, available: true);
}

class EmptyEngine extends MobileAnalysisEngineUnavailable {
  const EmptyEngine();
  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    Roi? rimRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) async* {
    yield const AnalysisProgress(
      stage: AnalysisStage.completed,
      progress: 1,
      message: 'done',
    );
  }
}

class RefCandidate {
  RefCandidate(
    this.id,
    this.start,
    this.end,
    this.event,
    this.edited,
    this.selection,
    this.reviewed,
    this.player,
    this.note,
  );
  final String id;
  int start, end, event;
  bool edited, reviewed;
  String selection;
  String? player, note;
  RefCandidate clone() => RefCandidate(
    id,
    start,
    end,
    event,
    edited,
    selection,
    reviewed,
    player,
    note,
  );
  Map<String, Object?> get value => {
    'id': id,
    'start': start,
    'end': end,
    'event': event,
    'edited': edited,
    'selection': selection,
    'reviewed': reviewed,
    'player': player,
    'note': note,
  };
}

class Entry {
  Entry(this.kind, this.before);
  final String kind;
  final Map<String, RefCandidate> before;
}

class Model {
  Model(this.id)
    : name = id,
      players = ['Alice'],
      cs = {
        'goal': RefCandidate(
          'goal',
          1000,
          3000,
          2000,
          true,
          'included',
          true,
          'Alice',
          null,
        ),
        'second': RefCandidate(
          'second',
          4000,
          6000,
          5000,
          false,
          'included',
          false,
          null,
          null,
        ),
      };
  final String id;
  String name;
  List<String> players;
  Map<String, RefCandidate> cs;
  final history = <Entry>[];
  Map<String, RefCandidate> snapshot() => {
    for (final e in cs.entries) e.key: e.value.clone(),
  };
  void historyAdd(String kind, Map<String, RefCandidate> old) {
    final changed = <String, RefCandidate>{};
    for (final id in cs.keys) {
      if (jsonEncode(old[id]!.value) != jsonEncode(cs[id]!.value))
        changed[id] = old[id]!;
    }
    if (changed.isNotEmpty) {
      history.add(Entry(kind, changed));
      if (history.length > 20) history.removeAt(0);
    }
  }

  void undo() {
    if (history.isEmpty) return;
    final e = history.removeLast();
    for (final item in e.before.entries) {
      final c = cs[item.key];
      if (c == null) continue;
      final old = item.value;
      switch (e.kind) {
        case 'selection':
          c.selection = old.selection;
          c.reviewed = old.reviewed;
        case 'player':
          c.player = old.player;
        case 'note':
          c.note = old.note;
        case 'range':
          c.start = old.start;
          c.end = old.end;
          c.edited = old.edited;
      }
    }
  }

  void replacePlayer(String old, String? next) {
    players = [
      for (final n in players)
        if (n == old) ...[?next] else n,
    ];
    for (final c in cs.values) {
      if (c.player == old) c.player = next;
    }
    for (final e in history) {
      if (e.kind == 'player') {
        for (final c in e.before.values) {
          if (c.player == old) c.player = next;
        }
      }
    }
  }

  Map<String, Object?> get value => {
    'id': id,
    'name': name,
    'players': players,
    'candidates': [for (final c in cs.values) c.value],
  };
}

Map<String, Object?> projectValue(ProjectSnapshot p) => {
  'id': p.id,
  'name': p.name,
  'players': p.players,
  'candidates': [
    for (final c in p.candidates)
      {
        'id': c.id,
        'start': c.startMs,
        'end': c.endMs,
        'event': c.eventMs,
        'edited': c.rangeEdited,
        'selection': c.selection.name,
        'reviewed': c.reviewed,
        'player': c.player,
        'note': c.note,
      },
  ],
};
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

const chan = MethodChannel('plugins.flutter.io/path_provider');
void provider(
  MobileVideoFixture f, {
  bool fail = false,
  bool delay = false,
  int failAt = 1,
  void Function()? hit,
}) {
  var calls = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(chan, (_) async {
        if (++calls == failAt) {
          hit?.call();
          if (delay)
            await Future<void>.delayed(const Duration(milliseconds: 1));
          if (fail) throw PlatformException(code: 'injected_storage_failure');
        }
        return f.root.path;
      });
}

Future<void> checkState(MobileVideoFixture f, Model m) async {
  await f.state.pendingProjectWrites;
  check(
    jsonEncode(projectValue(f.state.project)) == jsonEncode(m.value),
    'memory/model: actual=${jsonEncode(projectValue(f.state.project))} expected=${jsonEncode(m.value)}',
  );
  check(f.state.canUndoReview == m.history.isNotEmpty, 'undo availability');
  final entries = f.state.reviewHistory.allEntries.toList();
  check(entries.length == m.history.length, 'undo depth');
  for (var i = 0; i < entries.length; i++) {
    final actual = entries[i], expected = m.history[i];
    check(actual.kind.name == expected.kind, 'undo kind at $i');
    check(
      actual.before.keys.toSet().containsAll(expected.before.keys) &&
          expected.before.keys.toSet().containsAll(actual.before.keys),
      'undo ids at $i',
    );
    for (final id in expected.before.keys) {
      final a = actual.before[id]!, e = expected.before[id]!;
      final same = switch (expected.kind) {
        'selection' =>
          a.selection?.name == e.selection && a.reviewed == e.reviewed,
        'player' => jsonEncode(a.players) == jsonEncode([?e.player]),
        'note' => a.note == e.note,
        'range' =>
          a.startMs == e.start && a.endMs == e.end && a.rangeEdited == e.edited,
        _ => false,
      };
      check(same, 'undo contents at $i/$id ${expected.kind}');
    }
  }
  final disk = const ProjectPackageCodec().decode(
    await File('${f.data.path}/projects/${m.id}.json').readAsString(),
  );
  final persistedMemory = const ProjectPackageCodec().decode(
    const ProjectPackageCodec().encode(f.state.project),
  );
  check(
    jsonEncode(disk.toJson()) == jsonEncode(persistedMemory.toJson()),
    'disk/memory project mismatch: disk=${jsonEncode(disk.toJson())} memory=${jsonEncode(f.state.project.toJson())}',
  );
  final index = jsonDecode(
    await File('${f.data.path}/project_index.json').readAsString(),
  );
  check(
    jsonEncode(index) ==
        jsonEncode(f.state.recentProjects.map((p) => p.id).toList()),
    'recent index/memory mismatch',
  );
  final recent = f.state.recentProjects.firstWhere((p) => p.id == m.id);
  check(
    jsonEncode(
          const ProjectPackageCodec()
              .decode(const ProjectPackageCodec().encode(recent))
              .toJson(),
        ) ==
        jsonEncode(persistedMemory.toJson()),
    'recent project/memory mismatch',
  );
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'minimal race: failed note then queued addPlayer must preserve rollback',
    () async {
      final f = MobileVideoFixture(),
          backend = LogBackend(),
          previous = MobileDiagnostics.instance;
      MobileDiagnostics.instance = MobileDiagnostics(backend);
      await f.init();
      try {
        final video = await f.file('original.mp4', 'original');
        f.state.project = f.project(video.path);
        await f.state.renameProject('initial');
        final entered = Completer<void>(), release = Completer<void>();
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(chan, (_) async {
              if (first) {
                first = false;
                entered.complete();
                await release.future;
                throw PlatformException(code: 'injected_storage_failure');
              }
              return f.root.path;
            });
        final note = f.state.updateCandidateNote('goal', 'failed-note');
        await entered.future;
        f.state.addPlayer('Bob');
        release.complete();
        check(!await note, 'failed note returned success');
        await f.state.pendingProjectWrites;
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        check(
          f.state.project.candidates.single.note == null,
          'failed note remained in memory',
        );
        check(
          disk.candidates.single.note == null,
          'failed note persisted to disk after addPlayer',
        );
        check(
          f.state.project.players.contains('Bob') &&
              disk.players.contains('Bob'),
          'successful addPlayer missing',
        );
        await Future<void>.delayed(Duration.zero);
        check(
          backend.lines.any((l) => l.startsWith('app error:')),
          'failure was not logged',
        );
      } finally {
        provider(f);
        await f.close();
        MobileDiagnostics.instance = previous;
      }
    },
  );
  test('minimal failed addPlayer must roll back and log', () async {
    final f = MobileVideoFixture(),
        backend = LogBackend(),
        previous = MobileDiagnostics.instance;
    MobileDiagnostics.instance = MobileDiagnostics(backend);
    await f.init();
    try {
      final video = await f.file('original.mp4', 'original');
      f.state.project = f.project(video.path);
      await f.state.renameProject('initial');
      provider(f, fail: true);
      f.state.addPlayer('Bob');
      await f.state.pendingProjectWrites;
      await Future<void>.delayed(Duration.zero);
      final disk = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      final failures = <String>[];
      if (f.state.project.players.contains('Bob'))
        failures.add('failed addPlayer remained in memory');
      if (disk.players.contains('Bob'))
        failures.add('failed addPlayer reached disk');
      if (!backend.lines.any((l) => l.startsWith('app error:')))
        failures.add('failed addPlayer missing diagnostic');
      check(failures.isEmpty, failures.join('; '));
    } finally {
      provider(f);
      await f.close();
      MobileDiagnostics.instance = previous;
    }
  });
  test('seeded model sequences', () async {
    final oldDiagnostics = MobileDiagnostics.instance;
    final counts = <String, int>{},
        executed = <String, int>{},
        failuresByOperation = <String, int>{};
    final failures = <Map<String, Object?>>[];
    var injectedFailures = 0, delayedCalls = 0;
    final seedStart =
        int.tryParse(Platform.environment['BHE_FUZZ_SEED'] ?? '') ?? 0;
    final count = regressionSeedCount('BHE_FUZZ_COUNT');
    for (var seed = seedStart; seed < seedStart + count; seed++) {
      final random = Random(seed),
          f = MobileVideoFixture(),
          backend = LogBackend();
      MobileDiagnostics.instance = MobileDiagnostics(backend);
      final trace = <String>[];
      var active = 'A';
      final models = {'A': Model('A'), 'B': Model('B')};
      try {
        await f.init(engine: const EmptyEngine());
        final video = await f.file('original.mp4', 'original');
        for (final id in ['A', 'B']) {
          final p = f
              .project(video.path, id: id)
              .copyWith(
                candidates: [
                  ...f.project(video.path, id: id).candidates,
                  const Candidate(
                    id: 'second',
                    startMs: 4000,
                    endMs: 6000,
                    eventMs: 5000,
                  ),
                ],
              );
          await f.file(
            'BHE Mobile/projects/$id.json',
            const ProjectPackageCodec().encode(p),
          );
        }
        await f.file('BHE Mobile/project_index.json', '["A","B"]');
        await f.state.openProject('A');
        // Seed both recent objects via the same public loading path.
        await f.state.openProject('B');
        await f.state.openProject('A');
        await checkState(f, models[active]!);
        for (var step = 0; step < 24; step++) {
          final op = random.nextInt(18), m = models[active]!;
          final label = [
            'selection',
            'player',
            'note',
            'range',
            'batch',
            'undo',
            'rename-project',
            'rename-player',
            'delete-player',
            'add-player',
            'relink-ok',
            'relink-mismatch',
            'relink-cancel',
            'switch',
            'analysis',
            'race-note-add',
            'race-undo-note',
            'race-rename-note',
          ][op];
          final id = random.nextBool() ? 'goal' : 'second';
          final canCandidate = m.cs.containsKey(id);
          final fail = random.nextInt(5) == 0 && (op <= 10 || op >= 15);
          final delayed = random.nextBool();
          var hit = false;
          final beforeLog = backend.lines
              .where((x) => x.startsWith('app error:'))
              .length;
          provider(
            f,
            fail: fail,
            delay: delayed,
            failAt: op == 10 ? 3 : 1,
            hit: () {
              hit = true;
            },
          );
          trace.add('$label(id=$id, fail=$fail, delay=$delayed)');
          counts[label] = (counts[label] ?? 0) + 1;
          final willExecute =
              !(op <= 3 && !canCandidate) &&
              !(op == 4 && m.cs.isEmpty) &&
              !(op == 5 && m.history.isEmpty) &&
              !((op == 7 || op == 8) && m.players.isEmpty) &&
              !(op == 15 && !canCandidate) &&
              !((op == 16 || op == 17) &&
                  (!canCandidate || (op == 16 && m.history.isEmpty)));
          if (willExecute) executed[label] = (executed[label] ?? 0) + 1;
          if (op == 0 && canCandidate) {
            final target = m.cs[id]!.selection == 'included'
                ? 'excluded'
                : 'included';
            final old = m.snapshot();
            final ok = await f.state.toggleCandidate(
              id,
              target == 'included'
                  ? CandidateSelection.included
                  : CandidateSelection.excluded,
            );
            if (!fail) {
              check(
                ok == ReviewActionResult.changed,
                'selection expected success',
              );
              m.cs[id]!
                ..selection = target
                ..reviewed = true;
              m.historyAdd('selection', old);
            } else {
              check(
                ok == ReviewActionResult.rejected,
                'failed selection returned success',
              );
            }
          } else if (op == 1 && canCandidate) {
            final c = m.cs[id]!,
                player = c.player == null && m.players.isNotEmpty
                    ? m.players.first
                    : null;
            final old = m.snapshot();
            final changed = c.player != player,
                ok = await f.state.setCandidatePlayer(id, player);
            if (changed && !fail) {
              check(ok, 'player expected success');
              c.player = player;
              m.historyAdd('player', old);
            } else {
              check(!ok, 'player no-op/failure returned success');
            }
          } else if (op == 2 && canCandidate) {
            final note = 's${seed}_$step', old = m.snapshot();
            final ok = await f.state.updateCandidateNote(id, note);
            if (!fail) {
              check(ok, 'note expected success');
              m.cs[id]!.note = note;
              m.historyAdd('note', old);
            } else {
              check(!ok, 'failed note returned success');
            }
          } else if (op == 3 && canCandidate) {
            final old = m.snapshot(), c = m.cs[id]!, n = (step % 4) * 100;
            final actual = f.state.project.candidates.firstWhere(
              (x) => x.id == id,
            );
            final changed = c.start != n || c.end != n + 1000 || !c.edited;
            final ok = await f.state.updateCandidate(
              actual.copyWith(startMs: n, endMs: n + 1000, rangeEdited: true),
            );
            if (changed && !fail) {
              check(ok, 'range expected success');
              c
                ..start = n
                ..end = n + 1000
                ..edited = true;
              m.historyAdd('range', old);
            } else {
              check(!ok, 'range no-op/failure returned success');
            }
          } else if (op == 4 && m.cs.isNotEmpty) {
            final old = m.snapshot();
            final changed = m.cs.values.any(
              (c) =>
                  c.start != (c.event - 1000).clamp(0, 10000) ||
                  c.end != (c.event + 1000).clamp(0, 10000) ||
                  c.edited,
            );
            final n = await f.state.applyBatchClipRange(
              beforeSeconds: 1,
              afterSeconds: 1,
              overwriteManual: true,
            );
            if (changed && !fail) {
              check(n > 0, 'batch expected success');
              for (final c in m.cs.values) {
                c.start = (c.event - 1000).clamp(0, 10000);
                c.end = (c.event + 1000).clamp(0, 10000);
                c.edited = false;
              }
              m.historyAdd('range', old);
            } else {
              check(n == 0, 'batch no-op/failure returned success');
            }
          } else if (op == 5) {
            await f.state.undoReview();
            if (!fail) m.undo();
          } else if (op == 6) {
            final name = 'Project_${seed}_$step';
            final ok = await f.state.renameProject(name);
            if (!fail) {
              check(ok, 'rename project expected success');
              m.name = name;
            } else {
              check(!ok, 'failed project rename returned success');
            }
          } else if (op == 7 && m.players.isNotEmpty) {
            final old = m.players.first, name = 'P_${seed}_$step';
            final ok = await f.state.renamePlayer(old, name);
            if (!fail) {
              check(ok, 'rename player expected success');
              m.replacePlayer(old, name);
            } else {
              check(!ok, 'failed player rename returned success');
            }
          } else if (op == 8 && m.players.isNotEmpty) {
            final old = m.players.first, ok = await f.state.removePlayer(old);
            if (!fail) {
              check(ok, 'remove player expected success');
              m.replacePlayer(old, null);
            } else {
              check(!ok, 'failed player delete returned success');
            }
          } else if (op == 9) {
            final name = 'Add_${seed}_$step';
            f.state.addPlayer(name);
            if (!fail) m.players.add(name);
            await f.state.pendingProjectWrites;
          } else if (op == 10) {
            f.choose(video);
            await f.state.relinkVideo();
            if (!fail || !hit) m.history.clear();
          } else if (op == 11) {
            f.choose(await f.file('wrong.mp4', 'different'));
            await f.state.relinkVideo();
          } else if (op == 12) {
            if (random.nextBool()) {
              final pick = Completer<FilePickerResult?>();
              f.picker.pick = () => pick.future;
              final pending = f.state.relinkVideo();
              f.state.cancelVideoRelink();
              pick.complete(null);
              await pending;
            } else {
              f.choose(null);
              await f.state.relinkVideo();
            }
          } else if (op == 13) {
            provider(f);
            active = active == 'A' ? 'B' : 'A';
            await f.state.openProject(active);
            models[active]!.history.clear();
          } else if (op == 14) {
            provider(f);
            await f.state.startAnalysis();
            await f.state.pendingProjectWrites;
            m.cs = {};
            m.history.clear();
          } else if (op == 15 && canCandidate) {
            final name = 'Race_${seed}_$step',
                note = 'race_${seed}_$step',
                old = m.snapshot();
            final entered = Completer<void>(), release = Completer<void>();
            var first = true;
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(chan, (_) async {
                  if (first) {
                    first = false;
                    hit = true;
                    entered.complete();
                    await release.future;
                    if (fail)
                      throw PlatformException(code: 'injected_storage_failure');
                  }
                  return f.root.path;
                });
            final pending = f.state.updateCandidateNote(id, note);
            await entered.future;
            f.state.addPlayer(name);
            m.players.add(name);
            release.complete();
            final ok = await pending;
            await f.state.pendingProjectWrites;
            if (!fail) {
              check(ok, 'race note expected success');
              m.cs[id]!.note = note;
              m.historyAdd('note', old);
            } else {
              check(!ok, 'race failed note returned success');
            }
          } else if ((op == 16 || op == 17) &&
              canCandidate &&
              (op == 17 || m.history.isNotEmpty)) {
            final entered = Completer<void>(), release = Completer<void>();
            var first = true;
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(chan, (_) async {
                  if (first) {
                    first = false;
                    hit = true;
                    entered.complete();
                    await release.future;
                    if (fail)
                      throw PlatformException(code: 'injected_storage_failure');
                  }
                  return f.root.path;
                });
            final name = 'RaceProject_${seed}_$step',
                note = 'after_${seed}_$step';
            final Future<Object?> pending = op == 16
                ? f.state.undoReview()
                : f.state.renameProject(name);
            await entered.future;
            final later = f.state.updateCandidateNote(id, note);
            release.complete();
            final result = await pending;
            final laterOk = await later;
            check(laterOk, 'queued note expected success');
            if (!fail) {
              if (op == 16) {
                m.undo();
              } else {
                check(result == true, 'queued project rename expected success');
                m.name = name;
              }
            } else if (op == 17) {
              check(
                result == false,
                'queued failed project rename returned success',
              );
            }
            final old = m.snapshot();
            m.cs[id]!.note = note;
            m.historyAdd('note', old);
          }
          provider(f);
          await Future<void>.delayed(Duration.zero);
          if (hit && delayed) delayedCalls++;
          if (fail && hit) {
            injectedFailures++;
            failuresByOperation[label] = (failuresByOperation[label] ?? 0) + 1;
            check(
              backend.lines.where((x) => x.startsWith('app error:')).length >
                  beforeLog,
              'injected failure missing MobileDiagnostics',
            );
          }
          await checkState(f, models[active]!);
        }
      } catch (error, stack) {
        final race =
            trace.isNotEmpty &&
            trace.last.startsWith('race-note-add') &&
            '$error'.contains('disk/memory project mismatch');
        final failedAdd =
            trace.isNotEmpty &&
            trace.last.startsWith('add-player') &&
            '$error'.contains('injected failure missing MobileDiagnostics');
        failures.add({
          'seed': seed,
          'trace': trace,
          'minimal_reproduction': race
              ? [
                  'start note write; delay and fail',
                  'addPlayer while note write is delayed',
                  'release failure; drain queue',
                ]
              : failedAdd
              ? ['inject write failure', 'addPlayer; drain queue']
              : null,
          'error': '$error',
          'stack': '$stack',
        });
      } finally {
        provider(f);
        await f.close();
      }
    }
    final result = {
      'base': Platform.environment['BHE_TEST_BASE'] ?? 'workspace',
      'seed_start': seedStart,
      'sequences': count,
      'steps_requested': count * 24,
      'operations_attempted': counts,
      'operations_executed': executed,
      'injected_failures': injectedFailures,
      'injected_failures_by_operation': failuresByOperation,
      'delayed_calls': delayedCalls,
      'failure_count': failures.length,
      'failures': failures,
    };
    final path = Platform.environment['BHE_FUZZ_RESULT'];
    if (path != null)
      await File(
        path,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    debugPrint(
      'FUZZ_SUMMARY ${jsonEncode({'sequences': count, 'operations_attempted': counts, 'operations_executed': executed, 'injected_failures': injectedFailures, 'injected_failures_by_operation': failuresByOperation, 'delayed_calls': delayedCalls, 'failures': failures.length})}',
    );
    if (failures.isNotEmpty) {
      debugPrint(
        'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST_FAILURE ${jsonEncode(failures.first)}',
      );
    }
    MobileDiagnostics.instance = oldDiagnostics;
    expect(
      failures,
      isEmpty,
      reason: 'See BHE_FUZZ_RESULT for seeds and failing prefixes',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}
