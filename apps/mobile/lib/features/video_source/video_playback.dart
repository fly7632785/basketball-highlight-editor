import 'dart:io';

import 'package:video_player/video_player.dart';

import '../diagnostics/mobile_diagnostics.dart';
import 'video_source_failure.dart';

bool isContentVideo(String path) => path.startsWith('content://');

VideoPlayerController sourceVideoController(String path) => isContentVideo(path)
    ? VideoPlayerController.contentUri(Uri.parse(path))
    : VideoPlayerController.file(File(path));

/// Async even for missing files: never notify app state during widget initState.
Future<VideoPlayerController?> openSourceVideo(
  String path, {
  required bool Function() isCurrent,
  required void Function(
    VideoSourceFailure, {
    DiagnosticErrorRecord? diagnostic,
  })
  onFailure,
}) async {
  VideoPlayerController? player;
  try {
    if (!isContentVideo(path) && !await File(path).exists()) {
      if (isCurrent()) {
        final diagnostic = MobileDiagnostics.instance.error(
          FileSystemException(
            'Video source missing',
            path,
            const OSError('ENOENT', 2),
          ),
          null,
          operation: 'playback',
        );
        onFailure(VideoSourceFailure.missing, diagnostic: diagnostic);
      }
      return null;
    }
    player = sourceVideoController(path);
    await player.initialize();
    if (isCurrent()) return player;
  } catch (error, stack) {
    final diagnostic = MobileDiagnostics.instance.error(
      error,
      stack,
      operation: 'playback',
    );
    if (isCurrent()) {
      onFailure(VideoSourceFailure.unplayable, diagnostic: diagnostic);
    }
  }
  await disposeSourceVideo(player);
  return null;
}

Future<void> disposeSourceVideo(VideoPlayerController? player) async {
  try {
    await player?.dispose();
  } catch (error, stack) {
    MobileDiagnostics.instance.error(
      error,
      stack,
      operation: 'playback.dispose',
    );
  }
}
