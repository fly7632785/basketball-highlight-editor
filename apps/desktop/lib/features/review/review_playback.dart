import 'package:media_kit/media_kit.dart';

/// Position analysis results without starting playback, including empty results.
Future<void> positionPausedReview(Player player, Duration? position) async {
  await player.pause();
  if (position != null) await player.seek(position);
}
