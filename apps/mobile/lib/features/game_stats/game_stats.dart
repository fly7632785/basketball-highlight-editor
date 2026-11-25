import 'package:bhe_core/bhe_core.dart';

/// 导出页「比赛数据」的统计。只读审核结果，不写盘，不进修改管道。
class GameStats {
  const GameStats({
    required this.candidateCount,
    required this.keptCount,
    required this.unreviewedCount,
    required this.manuallyExcludedCount,
    required this.rimRejectedCount,
    required this.playerCounts,
    required this.unassignedCount,
    required this.bucketMinutes,
    required this.timeBuckets,
  });

  final int candidateCount;

  /// 保留的片段，导出时会算作进球。
  final int keptCount;

  /// 保留的片段里还没人工看过的。
  final int unreviewedCount;
  final int manuallyExcludedCount;

  /// 篮筐复核判断没进、且没被人工改过的片段。
  final int rimRejectedCount;
  final List<({String name, int count})> playerCounts;
  final int unassignedCount;
  final int bucketMinutes;
  final List<({int startMinute, int endMinute, int count})> timeBuckets;

  int get excludedCount => manuallyExcludedCount + rimRejectedCount;

  /// 保留 / 全部疑似片段，只是粗略估算：疑似片段里有不是投篮的，
  /// 没碰到篮筐的投篮又识别不到。
  double? get estimatedHitRate =>
      candidateCount == 0 ? null : keptCount / candidateCount;
}

const _defaultBucketMinutes = 10;
const _maxBuckets = 12;

/// 手机的 [Candidate] 不保存分析时写入的 review_reason，所以用「被排除、
/// 没人工审核过、篮筐复核判定为没进」近似桌面端的「篮筐复核排除」。
bool _isAutoRimRejected(Candidate candidate) =>
    !candidate.reviewed && candidate.rimCheckStatus == 'rejected';

GameStats computeGameStats(
  List<Candidate> candidates,
  List<String> roster, {
  int videoDurationMs = 0,
}) {
  var kept = 0;
  var unreviewed = 0;
  var manual = 0;
  var rim = 0;
  var unassigned = 0;
  final perPlayer = <String, int>{};
  final eventTimes = <int>[];
  for (final candidate in candidates) {
    if (candidate.selection == CandidateSelection.excluded) {
      if (_isAutoRimRejected(candidate)) {
        rim++;
      } else {
        manual++;
      }
      continue;
    }
    kept++;
    if (!candidate.reviewed) unreviewed++;
    final names = {
      for (final label in candidate.effectivePlayers)
        if (label.trim().isNotEmpty) label.trim(),
    };
    if (names.isEmpty) unassigned++;
    for (final name in names) {
      perPlayer[name] = (perPlayer[name] ?? 0) + 1;
    }
    var event = candidate.eventMs;
    if (event < 0) event = 0;
    if (videoDurationMs > 0 && event > videoDurationMs) event = videoDurationMs;
    eventTimes.add(event);
  }

  final rosterIndex = {
    for (var i = 0; i < roster.length; i++) roster[i]: i,
  };
  final playerCounts = [
    for (final entry in perPlayer.entries)
      (name: entry.key, count: entry.value),
  ]..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      final ai = rosterIndex[a.name];
      final bi = rosterIndex[b.name];
      if (ai != null && bi != null) return ai.compareTo(bi);
      if (ai != null) return -1;
      if (bi != null) return 1;
      return a.name.compareTo(b.name);
    });

  var bucketMinutes = _defaultBucketMinutes;
  if (eventTimes.isNotEmpty) {
    final last = eventTimes.reduce((a, b) => a > b ? a : b);
    while (last ~/ (bucketMinutes * 60000) + 1 > _maxBuckets) {
      bucketMinutes *= 2;
    }
  }
  final counts = <int, int>{};
  for (final time in eventTimes) {
    final index = time ~/ (bucketMinutes * 60000);
    counts[index] = (counts[index] ?? 0) + 1;
  }
  // 从 0 分钟连续列到最后一个有进球的时间段，没进球的段显示 0。
  final lastBucket = counts.isEmpty
      ? -1
      : counts.keys.reduce((a, b) => a > b ? a : b);
  return GameStats(
    candidateCount: candidates.length,
    keptCount: kept,
    unreviewedCount: unreviewed,
    manuallyExcludedCount: manual,
    rimRejectedCount: rim,
    playerCounts: playerCounts,
    unassignedCount: unassigned,
    bucketMinutes: bucketMinutes,
    timeBuckets: [
      for (var index = 0; index <= lastBucket; index++)
        (
          startMinute: index * bucketMinutes,
          endMinute: (index + 1) * bucketMinutes,
          count: counts[index] ?? 0,
        ),
    ],
  );
}
