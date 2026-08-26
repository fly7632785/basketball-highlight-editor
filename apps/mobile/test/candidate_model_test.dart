import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('candidate evidence round-trips through the project schema', () {
    const candidate = Candidate(
      id: 'candidate_1200',
      startMs: 0,
      endMs: 4200,
      eventMs: 1200,
      confidence: .82,
      trajectoryScore: .76,
      crossingScore: .94,
      netMotionScore: .41,
      trajectory: [
        EvidencePoint(timeMs: 900, x: .42, y: .31, confidence: .66),
        EvidencePoint(timeMs: 1200, x: .48, y: .5, confidence: .82),
      ],
      crossingPoint: EvidencePoint(timeMs: 1200, x: .48, y: .5),
      reason: 'uncertain',
      verdict: 'ambiguous',
      completeCrossing: true,
      evidenceSource: 'rust_onnx',
    );

    final restored = Candidate.fromJson(candidate.toJson());

    expect(restored.id, candidate.id);
    expect(restored.confidence, candidate.confidence);
    expect(restored.trajectory, hasLength(2));
    expect(restored.trajectory.first.timeMs, 900);
    expect(restored.crossingPoint?.x, .48);
    expect(restored.completeCrossing, isTrue);
    expect(restored.evidenceSource, 'rust_onnx');
  });

  test(
    'desktop overlay evidence accepts seconds and review suggestion fields',
    () {
      final candidate = Candidate.fromJson({
        'id': 'desktop_candidate',
        'review_start_ms': 1000,
        'review_end_ms': 5000,
        'event_time_ms': 3000,
        'confidence': 'medium',
        'evidence': {
          'trajectory': [
            {'time': 2.5, 'x': .4, 'y': .3},
            {'time': 3.0, 'x': .5, 'y': .5},
          ],
          'crossing': {'time': 3.0, 'x': .5, 'y': .5, 'valid': true},
          'review_reason_suggestion': {'primary': 'net_no_motion'},
          'analysis_source': 'desktop_engine',
        },
      });

      expect(candidate.confidence, .6);
      expect(candidate.trajectory.first.timeMs, 2500);
      expect(candidate.crossingPoint?.timeMs, 3000);
      expect(candidate.reason, 'net_no_motion');
      expect(candidate.evidenceSource, 'desktop_engine');
    },
  );
}
