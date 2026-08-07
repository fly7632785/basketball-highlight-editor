import 'engine_session.dart';

class SessionStateException implements Exception {
  const SessionStateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ProjectSession {
  ProjectSession(this.engine);

  final EngineSession engine;

  String? _projectRoot;
  String? _projectId;
  String? _videoId;

  String? get projectRoot => _projectRoot;
  String? get projectId => _projectId;
  String? get videoId => _videoId;

  Future<JsonMap> createProject({
    required String name,
    required String rootPath,
    String? projectId,
    String language = 'zh-CN',
  }) async {
    final payload = await engine.createProject(
      name: name,
      rootPath: rootPath,
      projectId: projectId,
      language: language,
    );
    _projectRoot = rootPath;
    _projectId = _nestedId(payload, 'project');
    _videoId = null;
    return payload;
  }

  Future<JsonMap> openProject(String projectRoot) async {
    final payload = await engine.openProject(projectRoot: projectRoot);
    final project = payload['project'];
    final video = payload['video'];
    _projectRoot = payload['project_root']?.toString() ?? projectRoot;
    _projectId = project is Map ? project['id']?.toString() : null;
    _videoId = video is Map ? video['id']?.toString() : null;
    return payload;
  }

  Future<JsonMap> deleteProject(String projectRoot) async {
    final payload = await engine.deleteProject(projectRoot: projectRoot);
    if (_projectRoot == projectRoot) reset();
    return payload;
  }

  Future<JsonMap> updateProjectSettings({String? name, String? themeMode}) {
    return engine.updateProjectSettings(
      projectRoot: _requireProjectRoot(),
      name: name,
      themeMode: themeMode,
    );
  }

  Future<List<JsonMap>> loadRecentProjects({
    required String knownRoot,
    int limit = 20,
  }) async {
    if (knownRoot.trim().isEmpty) {
      throw const SessionStateException('最近项目目录不能为空');
    }
    final payload = await engine.listRecentProjectsInRoot(
      knownRoot: knownRoot,
      limit: limit,
    );
    final projects = payload['projects'];
    if (projects is! List) return <JsonMap>[];
    return projects
        .whereType<Map>()
        .map((project) => Map<String, dynamic>.from(project))
        .toList();
  }

  Future<JsonMap> inspectVideo({required String videoPath}) {
    return engine.inspectVideo(videoPath: videoPath);
  }

  Future<JsonMap> linkVideo(String videoPath) async {
    final root = _requireProjectRoot();
    final payload = await engine.linkVideo(
      projectRoot: root,
      videoPath: videoPath,
    );
    _videoId = _nestedId(payload, 'video');
    return payload;
  }

  Future<JsonMap> relinkVideo(String videoPath) async {
    final root = _requireProjectRoot();
    final videoId = _requireVideoId();
    return engine.relinkVideo(
      projectRoot: root,
      videoId: videoId,
      videoPath: videoPath,
    );
  }

  Future<JsonMap> extractPreview({int timeMs = 1000}) {
    return engine.extractPreview(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      timeMs: timeMs,
    );
  }

  Future<JsonMap> suggestRoi({
    String? modelPath,
    double? sampleFps,
    double? duration,
    int? maxSamples,
    double? confidence,
  }) {
    return engine.suggestRoi(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      modelPath: modelPath,
      sampleFps: sampleFps,
      duration: duration,
      maxSamples: maxSamples,
      confidence: confidence,
    );
  }

  Future<JsonMap> saveRoi({
    required num x1,
    required num y1,
    required num x2,
    required num y2,
    String? name,
    JsonMap? calibration,
  }) {
    return engine.saveRoi(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      name: name,
      calibration: calibration,
    );
  }

  Future<JsonMap> startAnalysis({
    double? sampleFps,
    double? windowSeconds,
    double? beforeSeconds,
    double? afterSeconds,
    int? proxyWidth,
    int? proxyHeight,
    double? proxyFps,
    String? modelPath,
  }) {
    return engine.startAnalysis(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      sampleFps: sampleFps,
      windowSeconds: windowSeconds,
      beforeSeconds: beforeSeconds,
      afterSeconds: afterSeconds,
      proxyWidth: proxyWidth,
      proxyHeight: proxyHeight,
      proxyFps: proxyFps,
      modelPath: modelPath,
    );
  }

  Future<JsonMap> retryAnalysis({
    required String jobId,
    double? sampleFps,
    double? windowSeconds,
    double? beforeSeconds,
    double? afterSeconds,
    int? proxyWidth,
    int? proxyHeight,
    double? proxyFps,
    String? modelPath,
  }) {
    return engine.retryAnalysis(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      jobId: jobId,
      sampleFps: sampleFps,
      windowSeconds: windowSeconds,
      beforeSeconds: beforeSeconds,
      afterSeconds: afterSeconds,
      proxyWidth: proxyWidth,
      proxyHeight: proxyHeight,
      proxyFps: proxyFps,
      modelPath: modelPath,
    );
  }

  Future<JsonMap> retryExport({required String jobId}) {
    return engine.retryExport(projectRoot: _requireProjectRoot(), jobId: jobId);
  }

  Stream<JsonMap> pollJob({
    required String jobId,
    Duration interval = const Duration(seconds: 1),
  }) {
    return engine.pollJob(
      projectRoot: _requireProjectRoot(),
      jobId: jobId,
      interval: interval,
    );
  }

  Future<JsonMap> waitForJob({
    required String jobId,
    Duration interval = const Duration(seconds: 1),
  }) {
    return engine.waitForJob(
      projectRoot: _requireProjectRoot(),
      jobId: jobId,
      interval: interval,
    );
  }

  Future<JsonMap> cancelJob({required String jobId}) {
    return engine.cancelJob(projectRoot: _requireProjectRoot(), jobId: jobId);
  }

  Future<JsonMap> listCandidates() {
    return engine.listCandidates(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
    );
  }

  Future<JsonMap> listReviewHistory(String candidateId) {
    return engine.listReviewHistory(
      projectRoot: _requireProjectRoot(),
      candidateId: candidateId,
    );
  }

  Future<JsonMap> startReview(String candidateId, {String? reviewStartedAt}) {
    return engine.startReview(
      projectRoot: _requireProjectRoot(),
      candidateId: candidateId,
      reviewStartedAt: reviewStartedAt,
    );
  }

  Future<JsonMap> reviewCandidate(
    String candidateId, {
    required String status,
    String? note,
    String? reason,
  }) {
    return engine.reviewCandidate(
      projectRoot: _requireProjectRoot(),
      candidateId: candidateId,
      status: status,
      note: note,
      reason: reason,
    );
  }

  Future<JsonMap> updateClipRange({
    required String candidateId,
    required int startMs,
    required int endMs,
  }) {
    return engine.updateClipRange(
      projectRoot: _requireProjectRoot(),
      candidateId: candidateId,
      startMs: startMs,
      endMs: endMs,
    );
  }

  Future<JsonMap> exportClips({
    String mode = 'separate',
    String? outputDir,
    String? outputPath,
  }) {
    return engine.exportClips(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      mode: mode,
      outputDir: outputDir,
      outputPath: outputPath,
    );
  }

  Future<JsonMap> startExport({
    String mode = 'separate',
    String? outputDir,
    String? outputPath,
  }) {
    return engine.startExport(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      mode: mode,
      outputDir: outputDir,
      outputPath: outputPath,
    );
  }

  Future<JsonMap> getStatistics() {
    return engine.getStatistics(projectRoot: _requireProjectRoot());
  }

  Future<List<JsonMap>> getActiveJobs() async {
    final payload = await engine.getActiveJobs(
      projectRoot: _requireProjectRoot(),
      videoId: _videoId,
    );
    final jobs = payload['jobs'];
    if (jobs is! List) return <JsonMap>[];
    return jobs
        .whereType<Map>()
        .map((job) => Map<String, dynamic>.from(job))
        .toList();
  }

  Future<List<JsonMap>> getActiveExportJobs() async {
    final payload = await engine.getActiveJobs(
      projectRoot: _requireProjectRoot(),
      videoId: _videoId,
      jobType: 'export',
    );
    final jobs = payload['jobs'];
    if (jobs is! List) return <JsonMap>[];
    return jobs
        .whereType<Map>()
        .map((job) => Map<String, dynamic>.from(job))
        .toList();
  }

  Future<List<JsonMap>> listExports({int limit = 20}) async {
    final payload = await engine.listExports(
      projectRoot: _requireProjectRoot(),
      limit: limit,
    );
    final exports = payload['exports'];
    if (exports is! List) return <JsonMap>[];
    return exports
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  void clearVideo() => _videoId = null;

  void reset() {
    _projectRoot = null;
    _projectId = null;
    _videoId = null;
  }

  String _requireProjectRoot() {
    final value = _projectRoot;
    if (value == null || value.isEmpty) {
      throw const SessionStateException('当前会话尚未创建项目');
    }
    return value;
  }

  String _requireVideoId() {
    final value = _videoId;
    if (value == null || value.isEmpty) {
      throw const SessionStateException('当前会话尚未关联视频');
    }
    return value;
  }

  String _nestedId(JsonMap payload, String key) {
    final value = payload[key];
    if (value is Map &&
        value['id'] is String &&
        (value['id'] as String).isNotEmpty) {
      return value['id'] as String;
    }
    throw SessionStateException('Engine 返回的 $key 缺少 id');
  }
}
