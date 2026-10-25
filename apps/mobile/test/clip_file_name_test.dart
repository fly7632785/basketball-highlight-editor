import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const candidate = Candidate(
    id: 'candidate_12345',
    startMs: 9000,
    endMs: 15000,
    eventMs: 12345,
    confidence: .8,
  );

  test('clip file names carry the index, time and a safe player name', () {
    expect(clipFileName(1, candidate), 'goal_001_12.35s.mp4');
    expect(
      clipFileName(2, candidate.copyWith(player: '科比')),
      'goal_002_12.35s_科比.mp4',
    );
    expect(
      clipFileName(3, candidate.copyWith(player: ' A/B:C*? ')),
      'goal_003_12.35s_A_B_C.mp4',
    );
    expect(
      clipFileName(4, candidate.copyWith(player: '...')),
      'goal_004_12.35s.mp4',
    );
  });
}
