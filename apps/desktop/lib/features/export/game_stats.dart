/// 导出页「比赛数据」用到的统计，只读审核结果，不改任何数据。
class GameStats {
  const GameStats({
    required this.candidateCount,
    required this.madeCount,
    required this.unreviewedCount,
    required this.manuallyExcludedCount,
    required this.rimRejectedCount,
    required this.playerCounts,
    required this.unassignedCount,
    required this.timeBuckets,
  });

  final int candidateCount;

  /// 保留的片段，也就是导出时会算作进球的片段。
  final int madeCount;
  final int unreviewedCount;
  final int manuallyExcludedCount;

  /// 篮筐复核确认没进而自动排除的出手。
  final int rimRejectedCount;

  /// 球员 id 和进球数，按进球数从多到少。
  final List<({String id, String name, int index, int count})> playerCounts;
  final int unassignedCount;
  final List<({int? segment, int startMinute, int endMinute, int count})>
  timeBuckets;

  /// 保留的进球 / 全部疑似片段，只是粗略估算：疑似片段里也有不是投篮的，
  /// 没碰到篮筐的投篮又识别不到。
  double? get estimatedHitRate =>
      candidateCount == 0 ? null : madeCount / candidateCount;
}

const _bucketMinutes = 10;

bool _isExcluded(Map<String, dynamic> candidate) =>
    candidate['selection_status']?.toString() == 'excluded' ||
    candidate['review_status']?.toString() == 'excluded';

GameStats computeGameStats(
  List<Map<String, dynamic>> candidates,
  List<Map<String, dynamic>> players,
) {
  var made = 0;
  var unreviewed = 0;
  var manual = 0;
  var rim = 0;
  var unassigned = 0;
  final perPlayer = <String, int>{};
  final buckets = <(int?, int), int>{};
  for (final candidate in candidates) {
    if (_isExcluded(candidate)) {
      if (candidate['review_reason']?.toString() == 'auto_rim_check') {
        rim++;
      } else {
        manual++;
      }
      continue;
    }
    made++;
    if (candidate['review_status']?.toString() == 'pending') unreviewed++;
    final playerId = candidate['player_id']?.toString();
    if (playerId == null || playerId.isEmpty) {
      unassigned++;
    } else {
      perPlayer[playerId] = (perPlayer[playerId] ?? 0) + 1;
    }
    final eventMs = (candidate['event_time_ms'] as num?)?.toInt() ?? 0;
    final key = (
      (candidate['segment'] as num?)?.toInt(),
      eventMs ~/ (_bucketMinutes * 60000),
    );
    buckets[key] = (buckets[key] ?? 0) + 1;
  }
  final playerCounts = [
    for (var index = 0; index < players.length; index++)
      if (perPlayer[players[index]['id']?.toString()] case final int count)
        (
          id: players[index]['id'].toString(),
          name: players[index]['name']?.toString() ?? '',
          index: index,
          count: count,
        ),
  ]..sort((a, b) => b.count.compareTo(a.count));
  // 每段从 0 分钟连续列到最后一个有进球的时间段，没进球的段显示 0，避免看起来是连续的。
  final lastBucket = <int?, int>{};
  for (final key in buckets.keys) {
    final last = lastBucket[key.$1];
    if (last == null || key.$2 > last) lastBucket[key.$1] = key.$2;
  }
  final segments = lastBucket.keys.toList()
    ..sort((a, b) => (a ?? 0).compareTo(b ?? 0));
  final bucketKeys = [
    for (final segment in segments)
      for (var index = 0; index <= lastBucket[segment]!; index++) (segment, index),
  ];
  return GameStats(
    candidateCount: candidates.length,
    madeCount: made,
    unreviewedCount: unreviewed,
    manuallyExcludedCount: manual,
    rimRejectedCount: rim,
    playerCounts: playerCounts,
    unassignedCount: unassigned,
    timeBuckets: [
      for (final key in bucketKeys)
        (
          segment: key.$1,
          startMinute: key.$2 * _bucketMinutes,
          endMinute: (key.$2 + 1) * _bucketMinutes,
          count: buckets[key] ?? 0,
        ),
    ],
  );
}
