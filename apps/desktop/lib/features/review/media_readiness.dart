import 'dart:async';

/// 等待媒体时长变为正数（media_kit 完成元数据探测）后才认为可播放。
///
/// 网络位置（NAS/共享文件夹）上的视频首次探测元数据可能远慢于本地
/// 文件：保留 [timeout] × ([retries] + 1) 的总等待额度（默认 45 秒），
/// 只建立一个订阅。[cancelled] 完成时立即退出并清理订阅。
Future<Duration> waitForPlayableDuration({
  required Duration current,
  required Stream<Duration> updates,
  Duration timeout = const Duration(seconds: 15),
  int retries = 2,
  Future<void>? cancelled,
}) async {
  if (current > Duration.zero) return Future<Duration>.value(current);
  final result = Completer<Duration>();
  final totalTimeout = timeout * (retries < 0 ? 1 : retries + 1);
  final subscription = updates.listen(
    (duration) {
      if (duration > Duration.zero && !result.isCompleted) {
        result.complete(duration);
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
    onDone: () {
      if (!result.isCompleted) {
        result.completeError(StateError('No playable media duration'));
      }
    },
  );
  final timer = Timer(totalTimeout, () {
    if (!result.isCompleted) {
      result.completeError(
        MediaReadinessTimeout((totalTimeout.inMilliseconds / 1000).round()),
      );
    }
  });
  cancelled?.then<void>(
    (_) {
      if (!result.isCompleted) {
        result.completeError(const MediaReadinessCancelled());
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  try {
    return await result.future;
  } finally {
    timer.cancel();
    await subscription.cancel();
  }
}

class MediaReadinessCancelled implements Exception {
  const MediaReadinessCancelled();
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
