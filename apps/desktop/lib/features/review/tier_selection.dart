import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/project_state.dart';

const tierLabels = {'must': '进球', 'suspect': '疑似', 'excluded': '排除'};

// Only read the engine's classification; never duplicate its evidence rules here.
String candidateTier(Map<String, dynamic> candidate) {
  final tier = candidate['tier']?.toString();
  if (tierLabels.containsKey(tier)) return tier!;
  if (candidate['review_status'] == 'goal') return 'must';
  if (candidate['selection_status'] == 'excluded' ||
      candidate['review_status'] == 'excluded') {
    return 'excluded';
  }
  return 'suspect';
}

// Manual review can optimistically change the tier before the next engine read.
bool candidateLikelyMiss(Map<String, dynamic> candidate) =>
    candidateTier(candidate) == 'suspect' && candidate['likely_miss'] == true;

List<String> candidateTagIds(Map<String, dynamic> candidate) {
  final tags = candidate['tags'] ?? candidate['players'];
  if (tags is List) {
    return tags
        .whereType<Map>()
        .map((tag) => tag['id']?.toString())
        .whereType<String>()
        .toList();
  }
  final id = candidate['player_id']?.toString();
  return id == null || id.isEmpty ? [] : [id];
}

class TierSelection {
  TierSelection({Set<String> tiers = const {'must'}, Set<String>? tags})
    : tiers = Set.unmodifiable(tiers),
      tags = tags == null ? null : Set.unmodifiable(tags);
  final Set<String> tiers;
  final Set<String>? tags;
  bool matches(Map<String, dynamic> item) =>
      tiers.contains(candidateTier(item)) &&
      (tags == null || candidateTagIds(item).any(tags!.contains));
  List<Map<String, dynamic>> apply(List<Map<String, dynamic>> items) =>
      items.where(matches).toList();
  TierSelection toggleTier(String tier) => TierSelection(
    tiers: tiers.contains(tier) ? ({...tiers}..remove(tier)) : {...tiers, tier},
    tags: tags,
  );
  TierSelection toggleTag(String id) {
    final next = {...?tags};
    next.contains(id) ? next.remove(id) : next.add(id);
    return TierSelection(tiers: tiers, tags: next.isEmpty ? null : next);
  }

  String get reviewTier =>
      tiers.length == 3 ? 'all' : 'tiers:${tiers.join(',')}';
  String get reviewTags => tags == null ? 'all' : 'players:${tags!.join(',')}';
}

// Scope follows the project, not the active video in a multi-video project.
final exportSelectionProvider = StateProvider<TierSelection>((ref) {
  ref.watch(projectProvider.select((s) => s.statistics?['project']?['id']));
  return TierSelection();
});
final exportReviewProvider = StateProvider<TierSelection?>((ref) {
  ref.watch(projectProvider.select((s) => s.statistics?['project']?['id']));
  return null;
});
