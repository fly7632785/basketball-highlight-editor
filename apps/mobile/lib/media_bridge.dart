import 'dart:async';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';

class NativeMediaExportEngine implements MobileExportEngine {
  NativeMediaExportEngine();

  static const _channel = MethodChannel('com.bhe.bhe/mobile_media');
  bool _cancelled = false;

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
    _cancelled = false;

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
      if (failed || _cancelled) return;
      final outputPath = '$outputDirectory/${candidate.id}.mp4';
      try {
        await _channel.invokeMethod<String>('exportClip', {
          'exportId': candidate.id,
          'inputPath': video.path,
          'outputPath': outputPath,
          'startMs': candidate.startMs,
          'endMs': candidate.endMs,
        });
        if (_cancelled) return;
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
        message:
            '正在导出 ${completed + 1}-${completed + batch.length}/${candidates.length}',
      );
      await Future.wait(batch.map(exportOne));
      if (_cancelled) {
        throw const MobileExportException('导出已取消');
      }
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
  Stream<ExportProgress> mergeClips({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputPath,
  }) async* {
    if (candidates.isEmpty) return;
    _cancelled = false;
    yield const ExportProgress(progress: 0, message: '正在准备合并导出');
    try {
      final path = await _channel.invokeMethod<String>('mergeClips', {
        'exportId': 'merge-${DateTime.now().microsecondsSinceEpoch}',
        'inputPath': video.path,
        'outputPath': outputPath,
        'clips': [
          for (final candidate in candidates)
            {'startMs': candidate.startMs, 'endMs': candidate.endMs},
        ],
      });
      if (_cancelled) throw const MobileExportException('导出已取消');
      yield ExportProgress(
        progress: 1,
        message: '合并导出完成',
        outputPath: path ?? outputPath,
      );
    } on MissingPluginException {
      throw const MobileExportException('当前平台尚未注册合并导出模块。');
    } on PlatformException catch (error) {
      throw MobileExportException(error.message ?? error.code);
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    try {
      await _channel.invokeMethod<void>('cancelExport');
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      throw MobileExportException(error.message ?? error.code);
    }
  }

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
