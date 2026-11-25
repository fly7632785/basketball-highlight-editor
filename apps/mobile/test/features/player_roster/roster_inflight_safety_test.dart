import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';
import '../video_source/analysis_validation_test.dart' show RecordingAnalysis;

class LaunchRaceEngine extends MobileAnalysisEngineUnavailable {
  int calls = 0;
  bool cancelledBeforeStart = false;
  final done = Completer<void>();
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
      stage: AnalysisStage.validateInput,
      progress: 0.02,
      message: 'started',
    );
    await done.future;
  }

  @override
  Future<void> cancel() async {
    cancelledBeforeStart = calls == 0;
    if (!done.isCompleted) done.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stage in ['roster', 'clear']) {
    for (final action in ['cancel', 'switch', 'video', 'group']) {
      for (final fail in [false, true]) {
        test(
          '$action while $stage write ${fail ? 'fails' : 'succeeds'} preserves old review',
          () async {
            final f = MobileVideoFixture();
            final engine = RecordingAnalysis();
            await f.init(engine: engine);
            final release = Completer<void>();
            try {
              final source = await f.file('original.mp4', 'original');
              f.state.project = f.project(source.path).copyWith(players: []);
              f.state.playerGroups = [
                (name: 'Team', players: ['Bob']),
              ];
              f.state.rosterSelection.choose('Team', ['Bob']);
              expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
              expect(f.state.canUndoReview, isTrue);
              final entered = Completer<void>();
              var calls = 0;
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(
                    const MethodChannel('plugins.flutter.io/path_provider'),
                    (_) async {
                      calls++;
                      if (calls == (stage == 'roster' ? 1 : 3)) {
                        entered.complete();
                        await release.future;
                        if (fail) {
                          throw PlatformException(
                            code: 'injected_write_failure',
                          );
                        }
                      }
                      return f.root.path;
                    },
                  );
              final analysis = f.state.startAnalysis(
                rosterPlayers: ['Bob'],
                expectedRosterGroup: 'Team',
              );
              await entered.future.timeout(const Duration(seconds: 5));
              Future<void>? transition;
              switch (action) {
                case 'cancel':
                  transition = f.state.cancelAnalysis();
                case 'switch':
                  transition = f.state.createNewProject();
                case 'video':
                  f.choose(null);
                  transition = f.state.relinkVideo();
                case 'group':
                  expect(await f.state.deletePlayerGroup('Team'), isTrue);
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
              Future<bool>? later;
              if (action == 'cancel' || (action == 'group' && fail)) {
                later = f.state.updateCandidateNote('goal', 'later');
              }
              release.complete();
              await analysis;
              await transition;
              if (later != null) expect(await later, isTrue);
              final disk = const ProjectPackageCodec().decode(
                await File('${f.data.path}/projects/A.json').readAsString(),
              );
              if (action == 'group' && !fail) {
                expect(engine.calls, 1);
                expect(disk.players, ['Bob']);
                expect(f.state.project.players, ['Bob']);
                expect(disk.candidates.single.id, 'new');
                expect(f.state.canUndoReview, isFalse);
              } else {
                expect(engine.calls, 0);
                expect(disk.candidates.single.id, 'goal');
                expect(
                  disk.candidates.single.note,
                  later == null ? 'keep' : 'later',
                );
                expect(
                  disk.players,
                  stage == 'clear' || !fail ? ['Bob'] : isEmpty,
                );
                if (action != 'switch') {
                  expect(f.state.project.candidates.single.id, 'goal');
                  expect(
                    f.state.project.candidates.single.note,
                    later == null ? 'keep' : 'later',
                  );
                  expect(f.state.project.players, disk.players);
                  expect(f.state.canUndoReview, isTrue);
                } else {
                  expect(f.state.project.id, isNot('A'));
                  expect(
                    f.state.canUndoReview,
                    isFalse,
                  ); // History is project-session scoped.
                }
              }
            } finally {
              if (!release.isCompleted) release.complete();
              await f.close();
            }
          },
        );
      }
    }
  }
  test(
    'cancel at running commit waits for engine subscription to actually start',
    () async {
      final f = MobileVideoFixture();
      final engine = LaunchRaceEngine();
      await f.init(engine: engine);
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path).copyWith(players: []);
        f.state.playerGroups = [
          (name: 'Team', players: ['Bob']),
        ];
        f.state.rosterSelection.choose('Team', ['Bob']);
        expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
        Future<void>? cancel;
        void listener() {
          if (cancel == null &&
              f.state.analysing &&
              f.state.project.lastAnalysisStatus == 'running' &&
              !f.state.canUndoReview) {
            cancel = f.state.cancelAnalysis();
          }
        }

        f.state.addListener(listener);
        await f.state.startAnalysis(
          rosterPlayers: ['Bob'],
          expectedRosterGroup: 'Team',
        );
        await cancel;
        f.state.removeListener(listener);
        expect(engine.calls, 1);
        expect(engine.cancelledBeforeStart, isFalse);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.players, ['Bob']);
        expect(disk.candidates.single.effectivePlayers, ['Alice']);
      } finally {
        if (!engine.done.isCompleted) engine.done.complete();
        await f.close();
      }
    },
  );
}
