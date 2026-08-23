import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class NativeAnalysisEngine implements MobileAnalysisEngine {
  NativeAnalysisEngine();

  static const _channel = MethodChannel('com.bhe.bhe/mobile_analysis');
  static const _progressChannel = EventChannel('com.bhe.bhe/mobile_analysis_progress');
  bool _cancelled = false;

  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) async* {
    _cancelled = false;
    final modelPath = await _materializeModel();
    yield const AnalysisProgress(stage: AnalysisStage.validateInput, progress: 0.02, message: '正在检查视频');
    final progressController = StreamController<AnalysisProgress>();
    final progressSubscription = _progressChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) progressController.add(_progressFromNative(event));
      },
      onError: (_) {},
    );
    final iterator = StreamIterator(progressController.stream);
    final resultFuture = _channel.invokeMethod<Map<Object?, Object?>>('analyzeVideo', {
      'videoPath': video.path,
      'modelPath': modelPath,
      'hoopRoi': hoopRoi.toJson(),
      'netRoi': netRoi.toJson(),
      'startMs': settings.startMs,
      'endMs': settings.endMs ?? video.durationMs,
      'beforeMs': settings.clip.beforeSeconds * 1000,
      'afterMs': settings.clip.afterSeconds * 1000,
      'fps': settings.proxyFps,
    });
    try {
      Map<Object?, Object?>? result;
      while (true) {
        final nextProgress = iterator.moveNext();
        final next = await Future.any<Object?>([nextProgress, resultFuture]);
        if (next is bool) {
          if (!next) {
            result = await resultFuture;
            break;
          }
          yield iterator.current;
        } else {
          result = next as Map<Object?, Object?>?;
          break;
        }
      }
      if (_cancelled) return;
      final candidates = ((result?['candidates'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => Candidate.fromJson(item.cast<String, dynamic>()))
          .toList();
      yield AnalysisProgress(
        stage: AnalysisStage.completed,
        progress: 1,
        message: '分析完成',
        processedFrames: (result?['processed_frames'] as num?)?.toInt(),
        totalFrames: (result?['total_frames'] as num?)?.toInt(),
        candidates: candidates,
      );
    } on MissingPluginException {
      throw const MobileAnalysisException('当前设备未注册移动端分析模块。');
    } on PlatformException catch (error) {
      throw MobileAnalysisException(error.message ?? error.code);
    } finally {
      await progressSubscription.cancel();
      await iterator.cancel();
      await progressController.close();
    }
  }

  AnalysisProgress _progressFromNative(Map event) {
    final stage = AnalysisStage.values.firstWhere(
      (value) => value.name == event['stage'],
      orElse: () => AnalysisStage.refineCandidates,
    );
    return AnalysisProgress(
      stage: stage,
      progress: ((event['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
      message: event['message'] as String? ?? '正在分析视频',
      processedFrames: (event['processedFrames'] as num?)?.toInt(),
      totalFrames: (event['totalFrames'] as num?)?.toInt(),
    );
  }

  Future<String> _materializeModel() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/models/bball_model.onnx');
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/models/bball_model.onnx');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    return file.path;
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    try {
      await _channel.invokeMethod<void>('cancelAnalysis');
    } on MissingPluginException {
      return;
    }
  }
}
