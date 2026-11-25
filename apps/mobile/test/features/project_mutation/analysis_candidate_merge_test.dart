import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/project_mutation/analysis_candidate_merge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

class _RepeatEngine extends MobileAnalysisEngineUnavailable {
  const _RepeatEngine();

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
      candidates: [
        Candidate(id: 'goal', startMs: 1050, endMs: 3050, eventMs: 2050),
        Candidate(id: 'other', startMs: 6600, endMs: 8200, eventMs: 7500),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('redo analysis transfers both tags only to the same ID', () async {
    final f = MobileVideoFixture();
    await f.init(engine: const _RepeatEngine());
    addTearDown(f.close);
    final video = await f.file('original.mp4', 'original');
    final base = f.project(video.path);
    f.state.project = base.copyWith(
      players: ['Alice', 'Bob'],
      candidates: [
        base.candidates.single.copyWith(players: ['Bob', 'Alice']),
        const Candidate(
          id: 'old-other',
          startMs: 6500,
          endMs: 8100,
          eventMs: 7420,
          players: ['Alice', 'Bob'],
        ),
      ],
    );
    await f.state.startAnalysis();
    expect(f.state.project.lastAnalysisStatus, 'completed');
    final clips = f.state.project.candidates;
    expect(clips.map((candidate) => candidate.id), ['goal', 'other']);
    expect(clips.first.players, ['Bob', 'Alice']);
    expect(clips.last.players, isEmpty);
  });
  test('engine updates preserve reviews and manual candidates by ID', () {
    const old = Candidate(
      id: 'a',
      startMs: 100,
      endMs: 900,
      eventMs: 500,
      rangeEdited: true,
      selection: CandidateSelection.excluded,
      reviewed: true,
      note: 'important',
      players: ['Alice', 'Bob'],
    );
    const manual = Candidate(
      id: 'manual',
      startMs: 1000,
      endMs: 2000,
      eventMs: 1500,
      reason: 'manual',
    );
    const refreshed = Candidate(
      id: 'a',
      startMs: 0,
      endMs: 1000,
      eventMs: 500,
      confidence: .9,
    );
    const newItem = Candidate(
      id: 'new',
      startMs: 2000,
      endMs: 3000,
      eventMs: 2500,
    );
    final result = mergeAnalysisCandidates([old, manual], [refreshed, newItem]);
    expect(result.map((item) => item.id), ['a', 'manual', 'new']);
    expect(result.first.confidence, .9);
    expect(result.first.startMs, 100);
    expect(result.first.endMs, 900);
    expect(result.first.selection, CandidateSelection.excluded);
    expect(result.first.reviewed, isTrue);
    expect(result.first.note, 'important');
    expect(result.first.players, ['Alice', 'Bob']);
  });
}
