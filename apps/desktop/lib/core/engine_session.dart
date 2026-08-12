typedef JsonMap = Map<String, dynamic>;

abstract interface class EngineTransport {
  Future<JsonMap> request(String command, JsonMap payload);
}

class EngineSession {
  EngineSession(this.client);

  final EngineTransport client;

  Future<JsonMap> hello() => client.request('hello', <String, dynamic>{});

  Future<JsonMap> createProject({
    required String name,
    required String rootPath,
    String? projectId,
    String language = 'zh-CN',
  }) {
    return client.request('create_project', <String, dynamic>{
      'name': name,
      'root_path': rootPath,
      'language': language,
      ...?_optionalEntry('project_id', projectId),
    });
  }

  Future<JsonMap> updateProjectSettings({
    required String projectRoot,
    String? name,
    String? themeMode,
  }) {
    return client.request('update_project_settings', <String, dynamic>{
      'project_root': projectRoot,
      ...?_optionalEntry('name', name),
      ...?_optionalEntry('theme_mode', themeMode),
    });
  }

  Future<JsonMap> openProject({required String projectRoot}) {
    return client.request('open_project', <String, dynamic>{
      'project_root': projectRoot,
    });
  }

  Future<JsonMap> deleteProject({required String projectRoot}) {
    return client.request('delete_project', <String, dynamic>{
      'project_root': projectRoot,
    });
  }

  Future<JsonMap> listRecentProjects({
    required List<String> roots,
    int limit = 20,
  }) {
    return client.request('list_recent_projects', <String, dynamic>{
      'roots': roots,
      'limit': limit,
    });
  }

  Future<JsonMap> listRecentProjectsInRoot({
    required String knownRoot,
    int limit = 20,
  }) {
    return listRecentProjects(roots: [knownRoot], limit: limit);
  }

  Future<JsonMap> inspectVideo({required String videoPath}) {
    return client.request('inspect_video', <String, dynamic>{
      'video_path': videoPath,
    });
  }

  Future<JsonMap> linkVideo({
    required String projectRoot,
    required String videoPath,
  }) {
    return client.request('link_video', <String, dynamic>{
      'project_root': projectRoot,
      'video_path': videoPath,
    });
  }

  Future<JsonMap> relinkVideo({
    required String projectRoot,
    required String videoId,
    required String videoPath,
  }) {
    return client.request('relink_video', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      'video_path': videoPath,
    });
  }

  Future<JsonMap> extractPreview({
    required String projectRoot,
    required String videoId,
    int timeMs = 1000,
  }) {
    return client.request('extract_preview', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      'time_ms': timeMs,
    });
  }

  Future<JsonMap> setAnalysisRange({
    required String projectRoot,
    required String videoId,
    required int startMs,
    required int endMs,
  }) {
    return client.request('set_analysis_range', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      'start_ms': startMs,
      'end_ms': endMs,
    });
  }

  Future<JsonMap> suggestRoi({
    required String projectRoot,
    required String videoId,
    String? modelPath,
    double? sampleFps,
    double? duration,
    int? maxSamples,
    double? confidence,
  }) {
    return client.request('suggest_roi', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      ...?_optionalEntry('model_path', modelPath),
      ...?_optionalEntry('sample_fps', sampleFps),
      ...?_optionalEntry('duration', duration),
      ...?_optionalEntry('max_samples', maxSamples),
      ...?_optionalEntry('confidence', confidence),
    });
  }

  Future<JsonMap> saveRoi({
    required String projectRoot,
    required String videoId,
    required num x1,
    required num y1,
    required num x2,
    required num y2,
    String? name,
    JsonMap? calibration,
  }) {
    return client.request('save_roi', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      'x1': x1,
      'y1': y1,
      'x2': x2,
      'y2': y2,
      ...?_optionalEntry('name', name),
      ...?_optionalEntry('calibration', calibration),
    });
  }

  Future<JsonMap> startAnalysis({
    required String projectRoot,
    required String videoId,
    double? sampleFps,
    double? windowSeconds,
    double? beforeSeconds,
    double? afterSeconds,
    int? proxyWidth,
    int? proxyHeight,
    double? proxyFps,
    String? modelPath,
  }) {
    return client.request('start_analysis', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      ...?_optionalEntry('sample_fps', sampleFps),
      ...?_optionalEntry('window_seconds', windowSeconds),
      ...?_optionalEntry('before_seconds', beforeSeconds),
      ...?_optionalEntry('after_seconds', afterSeconds),
      ...?_optionalEntry('proxy_width', proxyWidth),
      ...?_optionalEntry('proxy_height', proxyHeight),
      ...?_optionalEntry('proxy_fps', proxyFps),
      ...?_optionalEntry('model_path', modelPath),
    });
  }

  Future<JsonMap> retryAnalysis({
    required String projectRoot,
    required String videoId,
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
    return client.request('retry_analysis', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      'job_id': jobId,
      ...?_optionalEntry('sample_fps', sampleFps),
      ...?_optionalEntry('window_seconds', windowSeconds),
      ...?_optionalEntry('before_seconds', beforeSeconds),
      ...?_optionalEntry('after_seconds', afterSeconds),
      ...?_optionalEntry('proxy_width', proxyWidth),
      ...?_optionalEntry('proxy_height', proxyHeight),
      ...?_optionalEntry('proxy_fps', proxyFps),
      ...?_optionalEntry('model_path', modelPath),
    });
  }

  Future<JsonMap> retryExport({
    required String projectRoot,
    required String jobId,
  }) {
    return client.request('retry_export', <String, dynamic>{
      'project_root': projectRoot,
      'job_id': jobId,
    });
  }

  Future<JsonMap> getJob({required String projectRoot, required String jobId}) {
    return client.request('get_job', <String, dynamic>{
      'project_root': projectRoot,
      'job_id': jobId,
    });
  }

  Future<JsonMap> getActiveJobs({
    required String projectRoot,
    String? videoId,
    String jobType = 'analysis',
  }) {
    return client.request('get_active_jobs', <String, dynamic>{
      'project_root': projectRoot,
      ...?_optionalEntry('job_type', jobType == 'analysis' ? null : jobType),
      ...?_optionalEntry('video_id', videoId),
    });
  }

  Future<JsonMap> cancelJob({
    required String projectRoot,
    required String jobId,
  }) {
    return client.request('cancel_job', <String, dynamic>{
      'project_root': projectRoot,
      'job_id': jobId,
    });
  }

  Stream<JsonMap> pollJob({
    required String projectRoot,
    required String jobId,
    Duration interval = const Duration(seconds: 1),
  }) async* {
    while (true) {
      final payload = await getJob(projectRoot: projectRoot, jobId: jobId);
      yield payload;
      if (_isTerminalJob(payload)) return;
      if (interval > Duration.zero) await Future<void>.delayed(interval);
    }
  }

  Future<JsonMap> waitForJob({
    required String projectRoot,
    required String jobId,
    Duration interval = const Duration(seconds: 1),
  }) async {
    JsonMap? latest;
    await for (final payload in pollJob(
      projectRoot: projectRoot,
      jobId: jobId,
      interval: interval,
    )) {
      latest = payload;
    }
    return latest ?? <String, dynamic>{};
  }

  Future<JsonMap> listCandidates({
    required String projectRoot,
    required String videoId,
  }) {
    return client.request('list_candidates', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
    });
  }

  Future<JsonMap> listPlayers({required String projectRoot}) {
    return client.request('list_players', <String, dynamic>{
      'project_root': projectRoot,
    });
  }

  Future<JsonMap> createPlayer({
    required String projectRoot,
    required String name,
  }) {
    return client.request('create_player', <String, dynamic>{
      'project_root': projectRoot,
      'name': name,
    });
  }

  Future<JsonMap> setCandidatePlayer({
    required String projectRoot,
    required String candidateId,
    String? playerId,
  }) {
    return client.request('set_candidate_player', <String, dynamic>{
      'project_root': projectRoot,
      'candidate_id': candidateId,
      'player_id': playerId,
    });
  }

  Future<JsonMap> setCandidatesPlayer({
    required String projectRoot,
    required List<String> candidateIds,
    String? playerId,
  }) {
    return client.request('set_candidates_player', <String, dynamic>{
      'project_root': projectRoot,
      'candidate_ids': candidateIds,
      'player_id': playerId,
    });
  }

  Future<JsonMap> listReviewHistory({
    required String projectRoot,
    required String candidateId,
  }) {
    return client.request('list_review_history', <String, dynamic>{
      'project_root': projectRoot,
      'candidate_id': candidateId,
    });
  }

  Future<JsonMap> startReview({
    required String projectRoot,
    required String candidateId,
    String? reviewStartedAt,
  }) {
    return client.request('start_review', <String, dynamic>{
      'project_root': projectRoot,
      'candidate_id': candidateId,
      ...?_optionalEntry('review_started_at', reviewStartedAt),
    });
  }

  Future<JsonMap> reviewCandidate({
    required String projectRoot,
    required String candidateId,
    required String status,
    String? note,
    String? reason,
  }) {
    return client.request('review_candidate', <String, dynamic>{
      'project_root': projectRoot,
      'candidate_id': candidateId,
      'status': status,
      ...?_optionalEntry('note', note),
      ...?_optionalEntry('reason', reason),
    });
  }

  Future<JsonMap> updateClipRange({
    required String projectRoot,
    required String candidateId,
    required int startMs,
    required int endMs,
  }) {
    return client.request('update_clip_range', <String, dynamic>{
      'project_root': projectRoot,
      'candidate_id': candidateId,
      'start_ms': startMs,
      'end_ms': endMs,
    });
  }

  Future<JsonMap> startExport({
    required String projectRoot,
    required String videoId,
    String mode = 'separate',
    String? outputDir,
    String? outputPath,
    List<String>? playerIds,
    bool? includeUnassigned,
  }) {
    return client.request('start_export', <String, dynamic>{
      'project_root': projectRoot,
      'video_id': videoId,
      'mode': mode,
      ...?_optionalEntry('output_dir', outputDir),
      ...?_optionalEntry('output_path', outputPath),
      ...?_optionalEntry('player_ids', playerIds),
      ...?_optionalEntry('include_unassigned', includeUnassigned),
    });
  }

  Future<JsonMap> listExports({required String projectRoot, int limit = 20}) {
    return client.request('list_exports', <String, dynamic>{
      'project_root': projectRoot,
      'limit': limit,
    });
  }

  Future<JsonMap> getStatistics({required String projectRoot}) {
    return client.request('get_statistics', <String, dynamic>{
      'project_root': projectRoot,
    });
  }

  bool _isTerminalJob(JsonMap payload) {
    final job = payload['job'];
    if (job is! Map) return false;
    final state = job['state'];
    return state == 'completed' || state == 'failed' || state == 'cancelled';
  }

  JsonMap? _optionalEntry(String key, Object? value) {
    return value == null ? null : <String, dynamic>{key: value};
  }
}
