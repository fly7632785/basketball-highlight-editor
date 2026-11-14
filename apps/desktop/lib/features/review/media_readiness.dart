import 'dart:async';

/// 等待媒体时长变为正数（media_kit 完成元数据探测）后才认为可播放。
///
/// 网络位置（NAS/共享文件夹）上的视频首次探测元数据可能远慢于本地
/// 文件：每次尝试给 [timeout]，共 [retries] + 1 次（默认 3 × 15 秒 =
/// 45 秒），全部超时才判定失败，并抛出带原因的 [MediaReadinessTimeout]。
Future<Duration> waitForPlayableDuration({
  required Duration current,
  required Stream<Duration> updates,
  Duration timeout = const Duration(seconds: 15),
  int retries = 2,
}) async {
  if (current > Duration.zero) return Future<Duration>.value(current);
  var attempt = 0;
  while (true) {
    try {
      return await updates
          .firstWhere((duration) => duration > Duration.zero)
          .timeout(timeout);
    } on TimeoutException {
      if (attempt >= retries) {
        throw MediaReadinessTimeout(
          (timeout.inMilliseconds * (retries + 1) / 1000).round(),
        );
      }
      attempt += 1;
    }
  }
}

/// 等待媒体元数据超时。
///
/// 常见于视频位于 NAS/共享文件夹且网络较慢，或连接已断开。
class MediaReadinessTimeout implements Exception {
  const MediaReadinessTimeout(this.seconds);

  final int seconds;

  @override
  String toString() =>
      '等待视频元数据超时（已等待 $seconds 秒）。视频若在 NAS 或共享文件夹上，'
      '可能是网络较慢或连接已断开，请检查网络后点击「重新加载视频」重试。';
}
