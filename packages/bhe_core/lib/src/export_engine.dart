import 'models.dart';

class ExportProgress {
  const ExportProgress({
    required this.progress,
    required this.message,
    this.outputPath,
  });

  final double progress;
  final String message;
  final String? outputPath;
}

abstract interface class MobileExportEngine {
  Stream<ExportProgress> exportClips({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputDirectory,
  });

  Future<void> cancel();

  Future<void> saveToLibrary(String path);
}

class MobileExportEngineUnavailable implements MobileExportEngine {
  const MobileExportEngineUnavailable();

  @override
  Stream<ExportProgress> exportClips({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputDirectory,
  }) => Stream<ExportProgress>.error(
        const MobileExportException('移动端视频剪辑引擎尚未接入。'),
      );

  @override
  Future<void> cancel() async {}

  @override
  Future<void> saveToLibrary(String path) async {
    throw const MobileExportException('当前平台尚未注册媒体保存模块。');
  }
}

class MobileExportException implements Exception {
  const MobileExportException(this.message);
  final String message;
  @override
  String toString() => message;
}
