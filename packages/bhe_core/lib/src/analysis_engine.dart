import 'models.dart';

class AnalysisProgress {
  const AnalysisProgress({
    required this.stage,
    required this.progress,
    required this.message,
    this.processedFrames,
    this.totalFrames,
    this.eta,
    this.candidates = const [],
  });

  final AnalysisStage stage;
  final double progress;
  final String message;
  final int? processedFrames;
  final int? totalFrames;
  final Duration? eta;
  final List<Candidate> candidates;
}

class AnalysisFrame {
  const AnalysisFrame({required this.timeMs, required this.width, required this.height, required this.imageBytes});

  final int timeMs;
  final int width;
  final int height;
  final List<int> imageBytes;
}

abstract interface class MobileAnalysisEngine {
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  });

  Future<void> cancel();
}

class MobileAnalysisEngineUnavailable implements MobileAnalysisEngine {
  const MobileAnalysisEngineUnavailable();

  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) => Stream<AnalysisProgress>.error(
        const MobileAnalysisException(
          '移动端本地分析引擎尚未接入，请先完成 ONNX/Rust 运行时集成。',
        ),
      );

  @override
  Future<void> cancel() async {}
}

class MobileAnalysisException implements Exception {
  const MobileAnalysisException(this.message);

  final String message;

  @override
  String toString() => message;
}
