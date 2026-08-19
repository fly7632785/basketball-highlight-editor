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
    var completed = 0;
    for (final candidate in candidates) {
      final outputPath = '$outputDirectory/${candidate.id}.mp4';
      yield ExportProgress(
        progress: completed / candidates.length,
        message: '正在导出 ${completed + 1}/${candidates.length}',
      );
      try {
        await _channel.invokeMethod<String>('exportClip', {
          'inputPath': video.path,
          'outputPath': outputPath,
          'startMs': candidate.startMs,
          'endMs': candidate.endMs,
        });
      } on MissingPluginException {
        throw const MobileExportException('当前平台尚未注册视频导出模块。');
      } on PlatformException catch (error) {
        throw MobileExportException(error.message ?? error.code);
      }
      completed++;
      yield ExportProgress(
        progress: completed / candidates.length,
        message: '已导出 $completed/${candidates.length}',
        outputPath: outputPath,
      );
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
