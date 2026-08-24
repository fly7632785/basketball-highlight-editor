import 'dart:io';

import 'engine_session.dart';

String canonicalProjectPath(String path) {
  final directory = Directory(path).absolute;
  try {
    return directory.resolveSymbolicLinksSync();
  } on FileSystemException {
    return directory.path;
  }
}

class SessionStateException implements Exception {
  const SessionStateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ProjectSessionCheckpoint {
  const ProjectSessionCheckpoint({
    this.projectRoot,
    this.projectId,
    this.videoId,
  });

  final String? projectRoot;
  final String? projectId;
  final String? videoId;
}

/// 后台任务使用的不可变项目上下文。
///
/// ProjectSession 本身会随着打开项目而变化；后台轮询必须持有创建时的
/// projectRoot/videoId，不能在每次请求时重新读取可变会话。
class ProjectSessionScope {
  const ProjectSessionScope({
    required this.engine,
    required this.projectRoot,
    this.projectId,
    this.videoId,
  });

  final EngineSession engine;
  final String projectRoot;
  final String? projectId;
  final String? videoId;

  Future<JsonMap> extractPreview({int timeMs = 1000}) {
    return engine.extractPreview(
      projectRoot: projectRoot,
      videoId: _requireVideoId(),
      timeMs: timeMs,
    );
  }

  Future<JsonMap> setAnalysisRange({required int startMs, required int endMs}) {
    return engine.setAnalysisRange(
      projectRoot: projectRoot,
      videoId: _requireVideoId(),
      startMs: startMs,
      endMs: endMs,
    );
  }

  Stream<JsonMap> pollJob({
    required String jobId,
    Duration interval = const Duration(seconds: 1),
  }) {
    return engine.pollJob(
      projectRoot: projectRoot,
      jobId: jobId,
      interval: interval,
    );
  }

  Future<JsonMap> listCandidates() {
    return engine.listCandidates(
      projectRoot: projectRoot,
      videoId: _requireVideoId(),
    );
  }

  Future<JsonMap> listPlayers() {
    return engine.listPlayers(projectRoot: projectRoot);
  }

  Future<JsonMap> createPlayer(String name) {
    return engine.createPlayer(projectRoot: projectRoot, name: name);
  }

  Future<JsonMap> setCandidatePlayer({
    required String candidateId,
    String? playerId,
  }) {
    return engine.setCandidatePlayer(
      projectRoot: projectRoot,
      candidateId: candidateId,
      playerId: playerId,
    );
  }

  Future<JsonMap> setCandidatesPlayer({
    required List<String> candidateIds,
    String? playerId,
  }) {
    return engine.setCandidatesPlayer(
      projectRoot: projectRoot,
      candidateIds: candidateIds,
      playerId: playerId,
    );
  }

  Future<List<JsonMap>> getActiveJobs({String jobType = 'analysis'}) async {
    final payload = await engine.getActiveJobs(
      projectRoot: projectRoot,
      videoId: videoId,
      jobType: jobType,
    );
    return _mapList(payload['jobs']);
  }

  Future<JsonMap?> getLatestJob({String jobType = 'analysis'}) async {
    final payload = await engine.getLatestJob(
      projectRoot: projectRoot,
      videoId: videoId,
      jobType: jobType,
    );
    final job = payload['job'];
    return job is Map ? job.cast<String, dynamic>() : null;
  }

  Future<List<JsonMap>> listExports({int limit = 20}) async {
    final payload = await engine.listExports(
      projectRoot: projectRoot,
      limit: limit,
    );
    return _mapList(payload['exports']);
  }

  Future<JsonMap> getStatistics() {
    return engine.getStatistics(projectRoot: projectRoot);
  }

  Future<JsonMap> cancelJob({required String jobId}) {
    return engine.cancelJob(projectRoot: projectRoot, jobId: jobId);
  }

  Future<JsonMap> waitForJob({
    required String jobId,
    Duration interval = const Duration(milliseconds: 200),
  }) {
    return engine.waitForJob(
      projectRoot: projectRoot,
      jobId: jobId,
      interval: interval,
    );
  }

  String _requireVideoId() {
    final value = videoId;
    if (value == null || value.isEmpty) {
      throw const SessionStateException('当前快照尚未关联视频');
    }
    return value;
  }
}

List<JsonMap> _mapList(Object? raw) {
  if (raw is! List) return <JsonMap>[];
  return raw
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
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

  ProjectSessionCheckpoint checkpoint() => ProjectSessionCheckpoint(
    projectRoot: _projectRoot,
    projectId: _projectId,
    videoId: _videoId,
  );

  void restore(ProjectSessionCheckpoint checkpoint) {
    _projectRoot = checkpoint.projectRoot;
    _projectId = checkpoint.projectId;
    _videoId = checkpoint.videoId;
  }

  /// 捕获当前项目上下文，供可能跨越项目切换的后台任务使用。
  ProjectSessionScope snapshot({bool requireVideo = false}) {
    final root = _requireProjectRoot();
    final videoId = _videoId;
    if (requireVideo && (videoId == null || videoId.isEmpty)) {
      throw const SessionStateException('当前会话尚未关联视频');
    }
    return ProjectSessionScope(
      engine: engine,
      projectRoot: root,
      projectId: _projectId,
      videoId: videoId,
    );
  }

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
    _projectRoot = canonicalProjectPath(
      (payload['project'] as Map?)?['root_path']?.toString() ?? rootPath,
    );
    _projectId = _nestedId(payload, 'project');
    _videoId = null;
    return payload;
  }

  Future<JsonMap> openProject(String projectRoot) async {
    final payload = await engine.openProject(projectRoot: projectRoot);
    final project = payload['project'];
    final video = payload['video'];
    _projectRoot = canonicalProjectPath(
      payload['project_root']?.toString() ?? projectRoot,
    );
    _projectId = project is Map ? project['id']?.toString() : null;
    _videoId = video is Map ? video['id']?.toString() : null;
    return payload;
  }

  Future<JsonMap> deleteProject(String projectRoot) async {
    final payload = await engine.deleteProject(projectRoot: projectRoot);
    if (_projectRoot == canonicalProjectPath(projectRoot)) reset();
    return payload;
  }

  Future<JsonMap> updateProjectSettings({String? name, String? themeMode}) {
    return engine.updateProjectSettings(
      projectRoot: _requireProjectRoot(),
      name: name,
      themeMode: themeMode,
    );
  }

  Future<JsonMap> getAnalysisMode() {
    return engine.getAnalysisMode(projectRoot: _requireProjectRoot());
  }

  Future<JsonMap> setAnalysisMode(String mode) {
    return engine.setAnalysisMode(
      projectRoot: _requireProjectRoot(),
      mode: mode,
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

  Future<JsonMap> setAnalysisRange({required int startMs, required int endMs}) {
    return engine.setAnalysisRange(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      startMs: startMs,
      endMs: endMs,
    );
  }

  Future<JsonMap> getWorkflowDraft() {
    return engine.getWorkflowDraft(projectRoot: _requireProjectRoot());
  }

  Future<JsonMap> saveWorkflowDraft(JsonMap draft) {
    return engine.saveWorkflowDraft(
      projectRoot: _requireProjectRoot(),
      draft: draft,
    );
  }

  Future<JsonMap> clearWorkflowDraft() {
    return engine.clearWorkflowDraft(projectRoot: _requireProjectRoot());
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
    String? mode,
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
      mode: mode,
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
    String? mode,
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
      mode: mode,
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

  Future<JsonMap> createManualCandidate({
    required int startMs,
    required int endMs,
    int? eventTimeMs,
  }) {
    return engine.createManualCandidate(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      startMs: startMs,
      endMs: endMs,
      eventTimeMs: eventTimeMs,
    );
  }

  Future<JsonMap> listPlayers() {
    return engine.listPlayers(projectRoot: _requireProjectRoot());
  }

  Future<JsonMap> createPlayer(String name) {
    return engine.createPlayer(projectRoot: _requireProjectRoot(), name: name);
  }

  Future<JsonMap> deletePlayer(String playerId) {
    return engine.deletePlayer(
      projectRoot: _requireProjectRoot(),
      playerId: playerId,
    );
  }

  Future<JsonMap> setCandidatePlayer({
    required String candidateId,
    String? playerId,
  }) {
    return engine.setCandidatePlayer(
      projectRoot: _requireProjectRoot(),
      candidateId: candidateId,
      playerId: playerId,
    );
  }

  Future<JsonMap> setCandidatesPlayer({
    required List<String> candidateIds,
    String? playerId,
  }) {
    return engine.setCandidatesPlayer(
      projectRoot: _requireProjectRoot(),
      candidateIds: candidateIds,
      playerId: playerId,
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

  Future<JsonMap> startExport({
    String mode = 'separate',
    String? outputDir,
    String? outputPath,
    List<String>? playerIds,
    bool? includeUnassigned,
  }) {
    return engine.startExport(
      projectRoot: _requireProjectRoot(),
      videoId: _requireVideoId(),
      mode: mode,
      outputDir: outputDir,
      outputPath: outputPath,
      playerIds: playerIds,
      includeUnassigned: includeUnassigned,
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
