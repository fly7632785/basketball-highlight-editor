import 'dart:convert';
import 'package:test/test.dart';
import 'package:bhe_core/bhe_core.dart';

void main() {
  const codec = ProjectPackageCodec();
  test('package and snapshot round trip keeps all ordered tags and human decision', () {
    const candidate = Candidate(id: 'c', startMs: 100, endMs: 800, eventMs: 500,
      players: ['小王', '囧'], reviewed: true, selection: CandidateSelection.excluded);
    const project = ProjectSnapshot(id: 'p', name: '多标签', video: null,
      candidates: [candidate], players: ['小王', '囧'], tierRuleVersion: 'r2-v1');
    final restored = codec.decode(codec.encode(project));
    expect(restored.candidates.single.players, ['小王', '囧']);
    expect(restored.candidates.single.player, '小王');
    expect(restored.candidates.single.reviewed, isTrue);
    expect(restored.candidates.single.selection, CandidateSelection.excluded);
    expect(restored.tierRuleVersion, 'r2-v1');
    expect(ProjectSnapshot.fromJson(project.toJson()).candidates.single.players, ['小王', '囧']);
    expect(candidate.copyWith(note: 'keep').players, ['小王', '囧']);
    expect(candidate.copyWith(player: '小李').players, ['小李']);
    expect(candidate.copyWith(players: []).player, isNull);
    expect(candidate.copyWith(clearPlayer: true).players, isEmpty);
    final manifest = (jsonDecode(codec.encode(project)) as Map)['manifest'] as Map;
    final raw = (manifest['candidates'] as List).single as Map;
    expect(raw['player'], '小王');
    expect(raw['players'], ['小王', '囧']);
  });
  test('old single tag imports, explicit empty array overrides stale old tag', () {
    final old = Candidate.fromJson({'id':'c','player':'小王'});
    expect(old.players, ['小王']);
    expect(old.toJson()['player'], '小王');
    final cleared = Candidate.fromJson({'id':'c','player':'旧值','players':[]});
    expect(cleared.players, isEmpty);
    expect(cleared.player, isNull);
    expect(cleared.toJson().containsKey('player'), isFalse);
  });
}
