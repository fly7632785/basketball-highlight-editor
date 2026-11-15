/// Choose the clip start nearest the review position; ties prefer earlier time.
T? nearestReviewCandidate<T>(
  Iterable<T> candidates, {
  required int anchorMs,
  required int Function(T candidate) startMs,
}) {
  T? nearest;
  int? nearestStart;
  int? nearestDistance;
  for (final candidate in candidates) {
    final start = startMs(candidate);
    final distance = (start - anchorMs).abs();
    if (nearestDistance == null ||
        distance < nearestDistance ||
        (distance == nearestDistance && start < nearestStart!)) {
      nearest = candidate;
      nearestStart = start;
      nearestDistance = distance;
    }
  }
  return nearest;
}
