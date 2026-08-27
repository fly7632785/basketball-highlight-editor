import 'dart:async';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';

class NativeMediaExportEngine implements MobileExportEngine {
  const NativeMediaExportEngine();

  static const _channel = MethodChannel('com.bhe.bhe/mobile_media');
  static Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Stream<ExportProgress> exportClips({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputDirectory,
  }) async* {
    if (candidates.isEmpty) return;

    // Parallel export: MediaExtractor/MediaMuxer on Android runs on
    // background threads; exporting 4+ clips concurrently reduces total
    // wall time from sum(N) to ~max(N) + small overhead.
    // Keep concurrency bounded to avoid thread/memory pressure on
    // low-end devices.
    const maxConcurrent = 3;
    final outputs = <String>[];
    var completed = 0;
    var failed = false;

    Future<void> exportOne(Candidate candidate) async {
      if (failed) return;
      final outputPath = '$outputDirectory/${candidate.id}.mp4';
      try {
        await _channel.invokeMethod<String>('exportClip', {
          'inputPath': video.path,
          'outputPath': outputPath,
          'startMs': candidate.startMs,
          'endMs': candidate.endMs,
        });
        outputs.add(outputPath);
      } on MissingPluginException {
        failed = true;
        throw const MobileExportException('当前平台尚未注册视频导出模块。');
      } on PlatformException catch (error) {
        failed = true;
        throw MobileExportException(error.message ?? error.code);
      }
    }

    // Process in batches of maxConcurrent.
    for (var i = 0; i < candidates.length; i += maxConcurrent) {
      final batch = candidates.skip(i).take(maxConcurrent).toList();
      yield ExportProgress(
        progress: completed / candidates.length,
        message: '正在导出 ${completed + 1}-${completed + batch.length}/${candidates.length}',
      );
      await Future.wait(batch.map(exportOne));
      completed += batch.length;
      for (final path in outputs.skip(outputs.length - batch.length)) {
        yield ExportProgress(
          progress: completed / candidates.length,
          message: '已导出 $completed/${candidates.length}',
          outputPath: path,
        );
      }
    }
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> saveToLibrary(String path) async {
    try {
      await _channel.invokeMethod<void>('saveToLibrary', {'path': path});
    } on MissingPluginException {
      throw const MobileExportException('当前平台尚未注册相册保存模块。');
    } on PlatformException catch (error) {
      throw MobileExportException(error.message ?? error.code);
    }
  }
}
