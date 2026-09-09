import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class NativeAnalysisEngine implements MobileAnalysisEngine {
  NativeAnalysisEngine();

  static const _autoRoiDurationMs = 20 * 1000;
  static const _autoRoiMaxSamples = 12;
  // Must match desktop's refine_scale in build_pipeline_commands.
  static const _analysisCropScale = 2.0;

  static const _channel = MethodChannel('com.bhe.bhe/mobile_analysis');
  static const _progressChannel = EventChannel(
    'com.bhe.bhe/mobile_analysis_progress',
  );
  bool _cancelled = false;

  @override
  Future<Map<String, dynamic>?> suggestRoi({
    required VideoInfo video,
    required int startMs,
    required int modelSize,
  }) async {
    final modelPath = await _materializeModelWithProgress();
    final remainingMs = (video.durationMs - startMs).clamp(
      1,
      _autoRoiDurationMs,
    );
    try {
      final value = await _channel.invokeMethod<Map<Object?, Object?>>(
        'suggestRoi',
        {
          'videoPath': video.path,
          'modelPath': modelPath,
          'startMs': startMs,
          // Keep the mobile scan on the same short-range contract as the
          // desktop detect_auto_roi.py command.
          'durationMs': remainingMs > _autoRoiDurationMs
              ? _autoRoiDurationMs
              : remainingMs,
          'sampleFps': 1.0,
          'maxSamples': _autoRoiMaxSamples,
          'modelSize': modelSize,
        },
      );
      return value?.map((key, value) => MapEntry(key.toString(), value));
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      developer.log(
        'automatic ROI suggestion failed: ${error.message}',
        name: 'BHE-Analysis',
      );
      return null;
    }
  }

  @override
  Stream<AnalysisProgress> recoverAnalysis() async* {
    final controller = StreamController<AnalysisProgress>();
    final subscription = _progressChannel.receiveBroadcastStream().listen((
      event,
    ) {
      if (event is Map) controller.add(_progressFromNative(event));
    }, onError: controller.addError);
    try {
      final state = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getAnalysisState',
      );
      final status = state?['status']?.toString();
      if (status == 'running') {
        controller.add(_progressFromNative(state!));
      } else if (status == 'completed') {
        controller.add(
          _progressFromNative({
            ...(state ?? const <Object?, Object?>{}),
            'stage': AnalysisStage.completed.name,
            'progress': 1.0,
            'message': '分析完成',
            'candidates':
                ((state?['result'] as Map?)?['candidates'] ??
                const <Object?>[]),
          }),
        );
      } else if (status == 'failed' || status == 'cancelled') {
        controller.add(
          _progressFromNative({
            ...(state ?? const <Object?, Object?>{}),
            'stage': status == 'cancelled'
                ? AnalysisStage.cancelled.name
                : AnalysisStage.failed.name,
            'progress': status == 'cancelled' ? 0.0 : 1.0,
            'message': state?['errorMessage']?.toString() ?? '移动端分析失败',
          }),
        );
      } else {
        return;
      }
      await for (final update in controller.stream) {
        yield update;
        if (update.stage == AnalysisStage.completed ||
            update.stage == AnalysisStage.failed ||
            update.stage == AnalysisStage.cancelled) {
          break;
        }
      }
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      developer.log(
        'analysis recovery failed: ${error.message}',
        name: 'BHE-Analysis',
      );
    } finally {
      await subscription.cancel();
      await controller.close();
    }
  }

  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    Roi? rimRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) async* {
    _cancelled = false;
    yield const AnalysisProgress(
      stage: AnalysisStage.validateInput,
      progress: 0.02,
      message: '正在检查视频',
    );
    developer.log(
      'analysis stream started: ${video.path}',
      name: 'BHE-Analysis',
    );
    yield const AnalysisProgress(
      stage: AnalysisStage.prepareProxy,
      progress: 0.03,
      message: '正在准备本地模型',
    );
    final modelPath = await _materializeModelWithProgress().timeout(
      const Duration(seconds: 60),
      onTimeout: () =>
          throw const MobileAnalysisException('本地模型准备超过 60 秒，请检查存储空间后重试。'),
    );
    developer.log('model ready: $modelPath', name: 'BHE-Analysis');
    final progressController = StreamController<AnalysisProgress>();
    final progressSubscription = _progressChannel
        .receiveBroadcastStream()
        .listen((event) {
          if (event is Map) progressController.add(_progressFromNative(event));
        }, onError: (_) {});
    final iterator = StreamIterator(progressController.stream);
    developer.log('invoking native analyzeVideo', name: 'BHE-Analysis');
    final resultFuture = _channel.invokeMethod<Map<Object?, Object?>>(
      'analyzeVideo',
      {
        'videoPath': video.path,
        'modelPath': modelPath,
        'hoopRoi': hoopRoi.toJson(),
        if (rimRoi != null) 'rimRoi': rimRoi.toJson(),
        'netRoi': netRoi.toJson(),
        'startMs': settings.startMs,
        'endMs': settings.endMs ?? video.durationMs,
        'beforeMs': settings.clip.beforeSeconds * 1000,
        'afterMs': settings.clip.afterSeconds * 1000,
        'fps': settings.analysisFps,
        'confidenceThreshold': settings.confidenceThreshold,
        'modelSize': settings.modelInputSize,
        'cropScale': _analysisCropScale,
        'executionProvider': Platform.isAndroid
            ? 'auto'
            : Platform.isIOS
            ? 'coreml'
            : 'cpu',
        'inferenceBatchSize': settings.inferenceBatchSize,
        // Keep the crossing and deduplication windows explicit at the
        // platform boundary instead of relying on a native default.
        'maxCrossGapMs': 1800,
        'dedupeMs': 2000,
      },
    );
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
    final rawCandidates =
        event['candidates'] ??
        (event['result'] is Map
            ? (event['result'] as Map)['candidates']
            : null);
    final candidates = (rawCandidates as List? ?? const [])
        .whereType<Map>()
        .map((item) => Candidate.fromJson(item.cast<String, dynamic>()))
        .toList();
    return AnalysisProgress(
      stage: stage,
      progress: ((event['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
      message: event['message'] as String? ?? '正在分析视频',
      processedFrames:
          ((event['processedFrames'] ?? event['processed']) as num?)?.toInt(),
      totalFrames: ((event['totalFrames'] ?? event['total']) as num?)?.toInt(),
      candidates: candidates,
    );
  }

  Future<String> _materializeModelWithProgress() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/models/bball_model.onnx');
    final data = await rootBundle.load('assets/models/bball_model.onnx');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (await file.exists() && await file.length() == bytes.length) {
      developer.log(
        'model already materialized: ${await file.length()} bytes',
        name: 'BHE-Analysis',
      );
      return file.path;
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    const chunkSize = 1024 * 1024;
    final stopwatch = Stopwatch()..start();
    IOSink? output;
    try {
      if (await temporary.exists()) await temporary.delete();
      output = temporary.openWrite();
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        if (_cancelled) throw const MobileAnalysisException('分析已取消');
        final end = (offset + chunkSize).clamp(0, bytes.length);
        output.add(bytes.sublist(offset, end));
        await output.flush();
        developer.log('model copy $end/${bytes.length}', name: 'BHE-Analysis');
        if (stopwatch.elapsed > const Duration(seconds: 60)) {
          throw const MobileAnalysisException('本地模型准备超时，请检查设备存储空间后重试。');
        }
      }
      await output.flush();
      await output.close();
      output = null;
      if (await temporary.length() != bytes.length) {
        throw const MobileAnalysisException('本地模型复制不完整，请重试。');
      }
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } finally {
      await output?.close();
      if (await temporary.exists()) await temporary.delete();
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
