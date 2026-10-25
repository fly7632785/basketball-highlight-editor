import 'package:desktop/features/export/game_stats.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _candidate(
  String id, {
  int minute = 0,
  String reviewStatus = 'pending',
  String? selection,
  String? reason,
  String? playerId,
  int? segment,
}) => {
  'id': id,
  'event_time_ms': minute * 60000 + 30000,
  'review_status': reviewStatus,
  'selection_status': ?selection,
  'review_reason': reason,
  'player_id': playerId,
  'segment': segment,
};

void main() {
  const players = [
    {'id': 'p1', 'name': '张三'},
    {'id': 'p2', 'name': '李四'},
    {'id': 'p3', 'name': '没进球'},
  ];

  test('counts made shots per player and splits exclusions by who made them', () {
    final stats = computeGameStats([
      _candidate('a', playerId: 'p2', reviewStatus: 'included'),
      _candidate('b', playerId: 'p2'),
      _candidate('c', playerId: 'p1', reviewStatus: 'included'),
      _candidate('d'),
      _candidate('e', reviewStatus: 'excluded', selection: 'excluded', reason: 'auto_rim_check'),
      _candidate('f', reviewStatus: 'excluded', selection: 'excluded', reason: 'auto_rim_check'),
      _candidate('g', reviewStatus: 'excluded', selection: 'excluded'),
    ], players);

    expect(stats.candidateCount, 7);
    expect(stats.madeCount, 4);
    expect(stats.unreviewedCount, 2);
    expect(stats.manuallyExcludedCount, 1);
    expect(stats.rimRejectedCount, 2);
    expect(stats.playerCounts.map((item) => (item.name, item.count)), [('李四', 2), ('张三', 1)]);
    expect(stats.unassignedCount, 1);
    // 4 个保留的进球 / 7 个疑似片段
    expect(stats.estimatedHitRate, closeTo(4 / 7, 1e-9));
  });

  test('groups made shots into ten-minute buckets per part', () {
    final stats = computeGameStats([
      _candidate('a', minute: 3, segment: 2),
      _candidate('b', minute: 12, segment: 1),
      _candidate('c', minute: 4, segment: 1),
      _candidate('d', minute: 8, segment: 1),
      _candidate('e', minute: 5, segment: 1, reviewStatus: 'excluded', selection: 'excluded'),
    ], players);

    expect(
      stats.timeBuckets.map((b) => (b.segment, b.startMinute, b.endMinute, b.count)),
      [(1, 0, 10, 2), (1, 10, 20, 1), (2, 0, 10, 1)],
    );
  });

  test('quiet ten-minute stretches still show up as zero', () {
    final stats = computeGameStats([
      _candidate('a', minute: 3),
      _candidate('b', minute: 25),
    ], players);

    expect(
      stats.timeBuckets.map((b) => (b.startMinute, b.count)),
      [(0, 1), (10, 0), (20, 1)],
    );
  });

  test('there is no hit rate before any shot is recognised', () {
    expect(computeGameStats(const [], players).estimatedHitRate, isNull);
  });
}
