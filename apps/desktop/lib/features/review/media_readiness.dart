Future<Duration> waitForPlayableDuration({
  required Duration current,
  required Stream<Duration> updates,
  Duration timeout = const Duration(seconds: 15),
}) {
  if (current > Duration.zero) return Future<Duration>.value(current);
  return updates
      .firstWhere((duration) => duration > Duration.zero)
      .timeout(timeout);
}
