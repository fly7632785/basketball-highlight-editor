// lib/providers/project_state.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/engine_session.dart';
import '../core/engine_client.dart';
import '../core/project_session.dart';
import 'notice_provider.dart';
import 'session_provider.dart';
import 'sidebar_provider.dart';

const _recentProjectRootsKey = 'basketball_recent_project_roots';

({String title, String? description}) userFacingNotice(Object error) {
  final raw = error.toString();
  if (raw.contains('ROI_COORDINATES_INVALID')) {
    return (title: '检测区域无法保存', description: '请从左上向右下拖出一个有效矩形，再松开鼠标。');
  }
  if (raw.contains('ROI_OUT_OF_BOUNDS')) {
    return (title: '检测区域超出画面', description: '请把四个手柄拖回预览画面内。');
  }
  if (raw.contains('ROI_TOO_SMALL')) {
    return (title: '投篮分析区太小', description: '请扩大橙色区域，覆盖篮筐、篮网和球落下的位置。');
  }
  if (raw.contains('ENGINE_TIMEOUT')) {
    return (title: '处理时间较长', description: '请稍候查看任务状态，原始视频不会被修改。');
  }
  return (title: raw, description: null);
}

/// 单进程内共享的 ProjectSession。封装 EngineSession(engineClientProvider)。
final Provider<ProjectSession> projectSessionProvider =
    Provider<ProjectSession>((ref) {
      return ProjectSession(EngineSession(ref.read(engineClientProvider)));
    });

/// 不可变项目会话状态。字段映射 app.dart:_BasketballHighlightAppState 的
/// 可观察字段(_themeMode/_section/_engineReady/_error 不在此处):
/// - _video/_videoPath/_reviewVideoPath/_previewPath
/// - _suggestedRoi/_roiSource/_roiConfidence/_roiSuggestionError
/// - _job/_exportJob/_statistics/_candidates/_recentProjects/_exportHistory
/// - _busy/_recentProjectsLoading/_recentProjectsError/_knownProjectsRoot
class ProjectState {
  const ProjectState({
    this.video,
    this.videoPath,
    this.reviewVideoPath,
    this.previewPath,
    this.previewTimeMs = 1000,
    this.previewRefreshing = false,
    this.suggestedRoi,
    this.netRoi,
    this.hoopBbox,
    this.roiSource,
    this.roiConfidence,
    this.roiSuggestionError,
    this.roiDetecting = false,
    this.job,
    this.exportJob,
    this.statistics,
    this.candidates = const <JsonMap>[],
    this.players = const <JsonMap>[],
    this.recentProjects = const <JsonMap>[],
    this.exportHistory = const <JsonMap>[],
    this.hydrating = false,
    this.hydrateError,
    this.busy = false,
    this.busyMessage,
    this.recentLoading = false,
    this.recentError,
    this.knownProjectsRoot,
    this.workflowDraft,
    this.analysisMode = 'standard',
  });

  final JsonMap? video;
  final String? videoPath;
  final String? reviewVideoPath;
  final String? previewPath;
  final int previewTimeMs;
  final bool previewRefreshing;
  final Rect? suggestedRoi;
  final Rect? netRoi;
  final Rect? hoopBbox;
  final String? roiSource;
  final double? roiConfidence;
  final String? roiSuggestionError;
  final bool roiDetecting;
  final JsonMap? job;
  final JsonMap? exportJob;
  final JsonMap? statistics;
  final List<JsonMap> candidates;
  final List<JsonMap> players;
  final List<JsonMap> recentProjects;
  final List<JsonMap> exportHistory;
  final bool hydrating;
  final String? hydrateError;
  final bool busy;
  final String? busyMessage;
  final bool recentLoading;
  final String? recentError;
  final String? knownProjectsRoot;
  final JsonMap? workflowDraft;
  final String analysisMode;

  bool get exportRunning {
    final jobState = exportJob?['state']?.toString();
    final recoveryState = exportJob?['recovery_state']?.toString();
    return (jobState == 'queued' || jobState == 'running') &&
        (recoveryState == null || recoveryState == 'worker_attached');
  }

  bool get analysisRunning {
    final jobState = job?['state']?.toString();
    final recoveryState = job?['recovery_state']?.toString();
    return (jobState == 'queued' || jobState == 'running') &&
        (recoveryState == null || recoveryState == 'worker_attached');
  }

  /// 可空字段使用 sentinel 区分"未传入"与"显式置 null"。
  /// 非空集合/布尔字段使用普通可选参数(默认保留旧值)。
  ProjectState copyWith({
    Object? video = _unset,
    Object? videoPath = _unset,
    Object? reviewVideoPath = _unset,
    Object? previewPath = _unset,
    int? previewTimeMs,
    bool? previewRefreshing,
    Object? suggestedRoi = _unset,
    Object? netRoi = _unset,
    Object? hoopBbox = _unset,
    Object? roiSource = _unset,
    Object? roiConfidence = _unset,
    Object? roiSuggestionError = _unset,
    bool? roiDetecting,
    Object? job = _unset,
    Object? exportJob = _unset,
    Object? statistics = _unset,
    Object? recentError = _unset,
    Object? knownProjectsRoot = _unset,
    Object? workflowDraft = _unset,
    Object? analysisMode = _unset,
    List<JsonMap>? candidates,
    List<JsonMap>? players,
    List<JsonMap>? recentProjects,
    List<JsonMap>? exportHistory,
    bool? hydrating,
    Object? hydrateError = _unset,
    bool? busy,
    Object? busyMessage = _unset,
    bool? recentLoading,
  }) {
    return ProjectState(
      video: identical(video, _unset) ? this.video : video as JsonMap?,
      videoPath: identical(videoPath, _unset)
          ? this.videoPath
          : videoPath as String?,
      reviewVideoPath: identical(reviewVideoPath, _unset)
          ? this.reviewVideoPath
          : reviewVideoPath as String?,
      previewPath: identical(previewPath, _unset)
          ? this.previewPath
          : previewPath as String?,
      previewTimeMs: previewTimeMs ?? this.previewTimeMs,
      previewRefreshing: previewRefreshing ?? this.previewRefreshing,
      suggestedRoi: identical(suggestedRoi, _unset)
          ? this.suggestedRoi
          : suggestedRoi as Rect?,
      netRoi: identical(netRoi, _unset) ? this.netRoi : netRoi as Rect?,
      hoopBbox: identical(hoopBbox, _unset) ? this.hoopBbox : hoopBbox as Rect?,
      roiSource: identical(roiSource, _unset)
          ? this.roiSource
          : roiSource as String?,
      roiConfidence: identical(roiConfidence, _unset)
          ? this.roiConfidence
          : roiConfidence as double?,
      roiSuggestionError: identical(roiSuggestionError, _unset)
          ? this.roiSuggestionError
          : roiSuggestionError as String?,
      roiDetecting: roiDetecting ?? this.roiDetecting,
      job: identical(job, _unset) ? this.job : job as JsonMap?,
      exportJob: identical(exportJob, _unset)
          ? this.exportJob
          : exportJob as JsonMap?,
      statistics: identical(statistics, _unset)
          ? this.statistics
          : statistics as JsonMap?,
      candidates: candidates ?? this.candidates,
      players: players ?? this.players,
      recentProjects: recentProjects ?? this.recentProjects,
      exportHistory: exportHistory ?? this.exportHistory,
      hydrating: hydrating ?? this.hydrating,
      hydrateError: identical(hydrateError, _unset)
          ? this.hydrateError
          : hydrateError as String?,
      busy: busy ?? this.busy,
      busyMessage: identical(busyMessage, _unset)
          ? this.busyMessage
          : busyMessage as String?,
      recentLoading: recentLoading ?? this.recentLoading,
      recentError: identical(recentError, _unset)
          ? this.recentError
          : recentError as String?,
      knownProjectsRoot: identical(knownProjectsRoot, _unset)
          ? this.knownProjectsRoot
          : knownProjectsRoot as String?,
      workflowDraft: identical(workflowDraft, _unset)
          ? this.workflowDraft
          : workflowDraft as JsonMap?,
      analysisMode: identical(analysisMode, _unset)
          ? this.analysisMode
          : analysisMode as String,
    );
  }
}

const Object _unset = Object();

/// 审核撤销快照(原 app.dart:_ReviewSnapshot)。Notifier 私有,不入 ProjectState。
class _ReviewSnapshot {
  const _ReviewSnapshot({
    required this.candidateId,
    required this.status,
    required this.reason,
    required this.note,
  });

  final String candidateId;
  final String status;
  final String? reason;
  final String? note;
}

/// 迁移自 app.dart:_BasketballHighlightAppState 的全部业务方法。
///
/// - `_session` → `ref.read(projectSessionProvider)`
/// - `setState((){...})` → `state = state.copyWith(...)`
/// - `_ensureEngine()` → `ref.read(engineBootstrapProvider.notifier).ensure()`
/// - `_showNotice(msg)` → success notice;`_showNotice(msg, error:true)` → error notice
/// - `_section = AppSection.x` 不迁移(由 router 负责)
/// - `_error = ...` 不迁移(由 notice 替代)
class ProjectNotifier extends Notifier<ProjectState> {
  final List<_ReviewSnapshot> _reviewHistory = <_ReviewSnapshot>[];
  final Set<String> _pollingJobIds = <String>{};
  final Set<String> _pollingExportJobIds = <String>{};
  Future<void> _reviewQueue = Future<void>.value();
  Future<void> _busyOperation = Future<void>.value();
  final Map<String, int> _reviewRevisions = <String, int>{};
  bool _disposed = false;
  int _projectLoadGeneration = 0;
  int _noticeCounter = 0;

  /// 等价 app.dart:_selectVideo(228)。
  @override
  ProjectState build() {
    ref.onDispose(() {
      _disposed = true;
      _pollingJobIds.clear();
      _pollingExportJobIds.clear();
    });
    return const ProjectState();
  }

  Future<void> selectVideo(String path) async {
    await flushReviewQueue();
    var projectCreatedForRecent = false;
    await _runBusy(
      () async {
        final generation = ++_projectLoadGeneration;
        await ref.read(engineBootstrapProvider.notifier).ensure();
        final session = ref.read(projectSessionProvider);
        final checkpoint = session.checkpoint();
        final source = File(path).absolute;
        final stem = source.uri.pathSegments.last.replaceFirst(
          RegExp(r'\.[^.]+$'),
          '',
        );
        final knownRoot = state.knownProjectsRoot ?? _projectsRoot;
        final projectRoot =
            '$knownRoot/$stem-${DateTime.now().millisecondsSinceEpoch}';
        late final JsonMap linked;
        var projectCreated = false;
        try {
          await session.createProject(name: stem, rootPath: projectRoot);
          projectCreated = true;
          linked = await session.linkVideo(path);
          projectCreatedForRecent = true;
        } catch (_) {
          if (projectCreated) {
            await session.deleteProject(projectRoot);
          }
          session.restore(checkpoint);
          rethrow;
        }
        final linkedVideo = (linked['video'] as Map?)?.cast<String, dynamic>();
        state = state.copyWith(
          knownProjectsRoot: knownRoot,
          videoPath: _playbackVideoPath(linkedVideo) ?? path,
          reviewVideoPath: null,
          previewPath: null,
          previewTimeMs: 1000,
          previewRefreshing: false,
          suggestedRoi: null,
          netRoi: null,
          hoopBbox: null,
          roiSource: null,
          roiConfidence: null,
          roiSuggestionError: null,
          roiDetecting: true,
          video: linkedVideo,
          job: null,
          exportJob: null,
          statistics: null,
          candidates: const <JsonMap>[],
          players: const <JsonMap>[],
          exportHistory: const <JsonMap>[],
          workflowDraft: null,
        );
        await _rememberProjectsRoot(knownRoot);
        ref.read(sidebarExtendedProvider.notifier).collapseForProjectCreation();
        state = state.copyWith(busyMessage: '正在生成视频预览…');
        final duration = (linkedVideo?['duration_ms'] as num?)?.toInt() ?? 1001;
        try {
          final preview = await session.extractPreview(
            timeMs: duration > 1000 ? 1000 : duration,
          );
          if (!_disposed && generation == _projectLoadGeneration) {
            state = state.copyWith(previewPath: preview['path']?.toString());
          }
        } catch (error) {
          if (!_disposed && generation == _projectLoadGeneration) {
            _pushNotice('视频预览加载失败：$error', NoticeSeverity.error);
          }
        }
        if (_disposed || generation != _projectLoadGeneration) return;
        state = state.copyWith(busyMessage: '正在识别篮筐区域…');
        Rect? suggestedRoi;
        Rect? hoopBbox;
        String? roiSource;
        var previewTimeMs = 1000;
        String? roiSuggestionError;
        double? roiConfidence;
        try {
          final suggestion = await session.suggestRoi(
            duration: 12,
            sampleFps: 1,
            maxSamples: 8,
            confidence: 0.05,
          );
          final roi = (suggestion['roi'] as Map?)?.cast<String, dynamic>();
          if (roi != null && linkedVideo != null) {
            suggestedRoi = _normalizeRoi(roi, linkedVideo);
            final calibration = (suggestion['calibration'] as Map?)
                ?.cast<String, dynamic>();
            final rawHoopBbox = calibration?['hoop_bbox'];
            if (rawHoopBbox is List) {
              hoopBbox = _normalizeBbox(rawHoopBbox, linkedVideo);
            }
            // 自动建议只进入会话草稿，最终由 applyWorkflowDraft 写入生效配置。
            roiSource = 'auto';
            roiConfidence = (calibration?['confidence'] as num?)?.toDouble();
            previewTimeMs =
                ((suggestion['preview_time_ms'] as num?)?.toInt() ?? 1000)
                    .clamp(0, duration)
                    .toInt();
          }
        } catch (error) {
          // 自动 ROI 是便利功能,失败不应阻塞导入,用户可手动框选。
          roiSuggestionError = error.toString();
        }
        if (_disposed || generation != _projectLoadGeneration) return;
        if (previewTimeMs != 1000) {
          try {
            final preview = await session.extractPreview(timeMs: previewTimeMs);
            if (!_disposed && generation == _projectLoadGeneration) {
              state = state.copyWith(
                previewPath: preview['path']?.toString(),
                previewTimeMs: previewTimeMs,
              );
            }
          } catch (error) {
            if (!_disposed && generation == _projectLoadGeneration) {
              _pushNotice('自动切换标记画面失败：$error', NoticeSeverity.error);
            }
          }
        }
        if (_disposed || generation != _projectLoadGeneration) return;
        state = state.copyWith(
          previewTimeMs: previewTimeMs,
          suggestedRoi: suggestedRoi,
          hoopBbox: hoopBbox,
          roiSource: roiSource,
          roiConfidence: roiConfidence,
          roiSuggestionError: roiSuggestionError,
          roiDetecting: false,
        );
        _reviewHistory.clear();
      },
      busyMessage: '正在准备视频…',
      successMessage: '视频已加载，已优先尝试自动识别篮筐区域',
    );
    if (projectCreatedForRecent && !_disposed) {
      await loadRecentProjects();
    }
  }

  int _previewTimeForVideo(JsonMap? video) {
    final duration = (video?['duration_ms'] as num?)?.toInt();
    if (duration == null) return 1000;
    return duration.clamp(0, 1000).toInt();
  }

  Future<bool> refreshPreview() => refreshPreviewAt(state.previewTimeMs);

  Future<bool> refreshPreviewAt(int timeMs) async {
    final video = state.video;
    if (video == null || state.previewRefreshing) return false;
    final duration = (video['duration_ms'] as num?)?.toInt() ?? 1000;
    final target = timeMs.clamp(0, duration).toInt();
    final videoId = video['id']?.toString();
    state = state.copyWith(previewRefreshing: true);
    try {
      final preview = await ref
          .read(projectSessionProvider)
          .extractPreview(timeMs: target);
      if (!_disposed && state.video?['id']?.toString() == videoId) {
        state = state.copyWith(
          previewPath: preview['path']?.toString(),
          previewTimeMs: target,
        );
      }
      return true;
    } catch (error) {
      if (!_disposed && state.video?['id']?.toString() == videoId) {
        _pushNotice('标记画面切换失败：$error', NoticeSeverity.error);
      }
      return false;
    } finally {
      if (!_disposed) state = state.copyWith(previewRefreshing: false);
    }
  }

  Future<JsonMap?> loadWorkflowDraft() async {
    final session = ref.read(projectSessionProvider);
    if (session.projectRoot == null) return state.workflowDraft;
    final payload = await session.getWorkflowDraft();
    final draft = (payload['draft'] as Map?)?.cast<String, dynamic>();
    state = state.copyWith(workflowDraft: draft);
    return draft;
  }

  Future<void> saveWorkflowDraft(JsonMap draft) async {
    await ref.read(projectSessionProvider).saveWorkflowDraft(draft);
    state = state.copyWith(workflowDraft: draft);
  }

  Future<void> clearWorkflowDraft() async {
    await ref.read(projectSessionProvider).clearWorkflowDraft();
    state = state.copyWith(workflowDraft: null);
  }

  Future<bool> applyWorkflowDraft(JsonMap draft) async {
    var applied = false;
    await _runBusy(() async {
      final video = state.video;
      if (video == null) {
        throw const SessionStateException('请先选择视频');
      }
      final session = ref.read(projectSessionProvider);
      final roi = _draftRect(draft['roi']);
      if (roi == null) {
        throw const SessionStateException('请先设置投篮分析区');
      }
      final range = (draft['analysis_range'] as Map?)?.cast<String, dynamic>();
      final startMs = (range?['start_ms'] as num?)?.toInt() ?? 0;
      final endMs =
          (range?['end_ms'] as num?)?.toInt() ??
          (video['duration_ms'] as num?)?.toInt() ??
          0;
      final rangePayload = await session.setAnalysisRange(
        startMs: startMs,
        endMs: endMs,
      );
      final rangedVideo = (rangePayload['video'] as Map?)
          ?.cast<String, dynamic>();

      final net = _draftRect(draft['net_roi']);
      final hoop = _draftRect(draft['hoop_bbox']);
      final mappedRoi = roi;
      final mappedNet = net;
      final mappedHoop = hoop;
      final nextWidth = ((video['width'] as num?)?.toDouble() ?? 1).clamp(
        1,
        double.infinity,
      );
      final nextHeight = ((video['height'] as num?)?.toDouble() ?? 1).clamp(
        1,
        double.infinity,
      );
      final calibration = <String, dynamic>{'source': 'manual'};
      if (mappedHoop != null) {
        calibration['hoop_bbox'] = <double>[
          mappedHoop.left * nextWidth,
          mappedHoop.top * nextHeight,
          mappedHoop.right * nextWidth,
          mappedHoop.bottom * nextHeight,
        ];
      }
      if (mappedNet != null) {
        calibration['net_roi'] = <String, double>{
          'x1': mappedNet.left * nextWidth,
          'y1': mappedNet.top * nextHeight,
          'x2': mappedNet.right * nextWidth,
          'y2': mappedNet.bottom * nextHeight,
        };
      }
      await session.saveRoi(
        x1: mappedRoi.left * nextWidth,
        y1: mappedRoi.top * nextHeight,
        x2: mappedRoi.right * nextWidth,
        y2: mappedRoi.bottom * nextHeight,
        calibration: calibration,
      );
      await session.clearWorkflowDraft();
      final savedMode = draft['analysis_mode']?.toString();
      final mode = savedMode == 'fast' ? 'fast' : 'standard';
      await session.setAnalysisMode(mode);
      state = state.copyWith(
        video: rangedVideo ?? video,
        videoPath: state.videoPath,
        reviewVideoPath: null,
        previewPath: null,
        previewTimeMs: state.previewTimeMs,
        suggestedRoi: mappedRoi,
        hoopBbox: mappedHoop,
        netRoi: mappedNet,
        roiSource: 'manual',
        roiConfidence: null,
        roiSuggestionError: null,
        statistics: null,
        workflowDraft: null,
        analysisMode: mode,
      );
      applied = true;
    }, busyMessage: '正在保存配置…');
    return applied;
  }

  /// 等价 app.dart:_chooseOpenProject(297)。
  Future<bool> chooseOpenProject() async {
    final root = await getDirectoryPath(confirmButtonText: '打开项目');
    if (root == null) return false;
    return openProject(root);
  }

  Future<bool> relinkCurrentVideo(String path) async {
    final video = state.video;
    if (video == null) return false;
    final generation = ++_projectLoadGeneration;
    var relinked = false;
    await _runBusy(() async {
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final session = ref.read(projectSessionProvider);
      final result = await session.relinkVideo(path);
      final nextVideo = (result['video'] as Map?)?.cast<String, dynamic>();
      if (nextVideo == null) {
        throw const SessionStateException('重新定位视频未返回视频信息');
      }
      if (_disposed || generation != _projectLoadGeneration) return;
      final invalidated = nextVideo['analysis_invalidated'] == true;
      state = state.copyWith(
        video: nextVideo,
        videoPath: _playbackVideoPath(nextVideo) ?? path,
        reviewVideoPath: null,
        previewPath: null,
        previewTimeMs: invalidated ? 1000 : state.previewTimeMs,
        suggestedRoi: invalidated ? null : state.suggestedRoi,
        netRoi: invalidated ? null : state.netRoi,
        hoopBbox: invalidated ? null : state.hoopBbox,
        roiSource: invalidated ? null : state.roiSource,
        roiConfidence: invalidated ? null : state.roiConfidence,
        roiSuggestionError: null,
        job: invalidated ? null : state.job,
        exportJob: invalidated ? null : state.exportJob,
        statistics: invalidated ? null : state.statistics,
        candidates: invalidated ? const <JsonMap>[] : state.candidates,
        exportHistory: invalidated ? const <JsonMap>[] : state.exportHistory,
        workflowDraft: invalidated ? null : state.workflowDraft,
        hydrateError: null,
      );
      try {
        final previewTimeMs = invalidated ? 1000 : state.previewTimeMs;
        final preview = await session.extractPreview(timeMs: previewTimeMs);
        if (!_disposed && generation == _projectLoadGeneration) {
          state = state.copyWith(
            previewPath: preview['path']?.toString(),
            previewTimeMs: previewTimeMs,
          );
        }
      } catch (error) {
        if (!_disposed && generation == _projectLoadGeneration) {
          _pushNotice('视频预览加载失败：$error', NoticeSeverity.error);
        }
      }
      relinked = true;
    }, successMessage: '视频已重新定位');
    return relinked;
  }

  Future<void> deleteProject(String root) async {
    final session = ref.read(projectSessionProvider);
    final normalizedRoot = canonicalProjectPath(root);
    final wasCurrentProject = session.projectRoot == normalizedRoot;
    if (wasCurrentProject) await flushReviewQueue();
    await _runBusy(() async {
      await session.deleteProject(root);
      final remaining = state.recentProjects
          .where(
            (project) =>
                canonicalProjectPath(
                  project['project_root']?.toString() ?? '',
                ) !=
                normalizedRoot,
          )
          .toList();
      if (wasCurrentProject) {
        _projectLoadGeneration++;
        _reviewHistory.clear();
        session.reset();
        state = ProjectState(
          recentProjects: remaining,
          knownProjectsRoot: Directory(normalizedRoot).parent.path,
        );
      } else {
        state = state.copyWith(recentProjects: remaining);
      }
    }, successMessage: '项目已删除（原始视频未删除）');
  }

  /// 关闭当前项目但不删除磁盘上的项目数据和原始视频。
  void closeProject() {
    if (state.busy) return;
    _projectLoadGeneration++;
    _reviewHistory.clear();
    ref.read(projectSessionProvider).reset();
    state = ProjectState(
      recentProjects: state.recentProjects,
      knownProjectsRoot: state.knownProjectsRoot,
    );
  }

  Future<void> flushReviewQueue() => _reviewQueue;

  Future<bool> closeProjectSafely() async {
    if (state.busy) return false;
    await flushReviewQueue();
    if (_disposed) return false;
    closeProject();
    return true;
  }

  Future<bool> startNewProject() async {
    if (state.busy || state.analysisRunning || state.exportRunning) {
      _pushNotice('请先等待当前操作结束或取消正在运行的任务', NoticeSeverity.info);
      return false;
    }
    await flushReviewQueue();
    if (_disposed) return false;
    _projectLoadGeneration++;
    _reviewHistory.clear();
    ref.read(projectSessionProvider).reset();
    state = ProjectState(
      recentProjects: state.recentProjects,
      knownProjectsRoot: state.knownProjectsRoot,
    );
    return true;
  }

  Future<bool> cancelTasksAndCloseProject() async {
    if (state.busy) return false;
    final generation = _projectLoadGeneration;
    final session = ref.read(projectSessionProvider);
    final scope = session.snapshot();
    final jobIds = <String>{
      if (_isActiveJob(state.job) && state.job?['id'] is String)
        state.job!['id'] as String,
      if (_isActiveJob(state.exportJob) && state.exportJob?['id'] is String)
        state.exportJob!['id'] as String,
    };
    if (jobIds.isEmpty) {
      return closeProjectSafely();
    }
    state = state.copyWith(busy: true);
    _pushNotice('正在取消任务并关闭项目…', NoticeSeverity.info);
    try {
      await flushReviewQueue();
      for (final jobId in jobIds) {
        await scope.cancelJob(jobId: jobId);
      }
      for (final jobId in jobIds) {
        await scope
            .waitForJob(jobId: jobId)
            .timeout(const Duration(seconds: 15));
      }
      if (_disposed || generation != _projectLoadGeneration) return false;
      state = state.copyWith(busy: false);
      closeProject();
      return true;
    } catch (error) {
      if (!_disposed && generation == _projectLoadGeneration) {
        state = state.copyWith(busy: false);
        _pushNotice('关闭项目失败：$error', NoticeSeverity.error);
      }
      return false;
    }
  }

  Future<bool> prepareForShutdown() async {
    try {
      await _busyOperation.timeout(const Duration(seconds: 30));
    } catch (error) {
      if (!_disposed) {
        _pushNotice('当前操作尚未结束，暂时无法退出：$error', NoticeSeverity.error);
      }
      return false;
    }
    final session = ref.read(projectSessionProvider);
    if (session.projectRoot == null) return true;
    final generation = _projectLoadGeneration;
    final scope = session.snapshot();
    final jobIds = <String>{
      if (_isActiveJob(state.job) && state.job?['id'] is String)
        state.job!['id'] as String,
      if (_isActiveJob(state.exportJob) && state.exportJob?['id'] is String)
        state.exportJob!['id'] as String,
    };
    try {
      await flushReviewQueue();
      for (final jobId in jobIds) {
        await scope.cancelJob(jobId: jobId);
      }
      for (final jobId in jobIds) {
        await scope
            .waitForJob(jobId: jobId)
            .timeout(const Duration(seconds: 15));
      }
      return !_disposed && generation == _projectLoadGeneration;
    } catch (error) {
      if (!_disposed) {
        _pushNotice('退出前保存项目失败：$error', NoticeSeverity.error);
      }
      return false;
    }
  }

  /// 等价 app.dart:_openProject(302)。
  Future<bool> openProject(String root) async {
    var opened = false;
    await flushReviewQueue();
    await _runBusy(() async {
      final generation = ++_projectLoadGeneration;
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final session = ref.read(projectSessionProvider);
      final checkpoint = session.checkpoint();
      late final JsonMap payload;
      try {
        payload = await session.openProject(root);
      } catch (_) {
        session.restore(checkpoint);
        rethrow;
      }
      if (generation != _projectLoadGeneration) return;
      var video = (payload['video'] as Map?)?.cast<String, dynamic>();
      var sourceMissing = false;
      var analysisInvalidated = false;
      if (video != null) {
        final sourcePath = video['source_path']?.toString();
        sourceMissing =
            sourcePath == null ||
            sourcePath.isEmpty ||
            video['source_exists'] == false ||
            !File(sourcePath).existsSync();
        if (sourceMissing) {
          final replacementFile = await openFile(
            confirmButtonText: '重新定位视频',
            acceptedTypeGroups: const [
              XTypeGroup(
                label: '视频',
                extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv'],
              ),
            ],
          );
          final replacement = replacementFile?.path;
          if (replacement != null && replacement.isNotEmpty) {
            final relinked = await session.relinkVideo(replacement);
            video = (relinked['video'] as Map?)?.cast<String, dynamic>();
            analysisInvalidated = video?['analysis_invalidated'] == true;
            sourceMissing = false;
          }
        }
      }
      if (generation != _projectLoadGeneration) return;
      final restoredRoi = analysisInvalidated
          ? null
          : (payload['roi'] as Map?)?.cast<String, dynamic>();
      final calibration = (restoredRoi?['calibration'] as Map?)
          ?.cast<String, dynamic>();
      final restoredRoiRect = video == null || restoredRoi == null
          ? null
          : _normalizeRoi(restoredRoi, video);
      final storedNetRoi = calibration?['net_roi'];
      final rawHoopBbox = calibration?['hoop_bbox'];
      final restoredHoopBbox = video == null || rawHoopBbox is! List
          ? null
          : _normalizeBbox(rawHoopBbox, video);
      final restoredNetRoi = video == null || storedNetRoi is! Map
          ? null
          : _normalizeRoi(storedNetRoi.cast<String, dynamic>(), video);
      final restoredRoiSource = calibration?['source']?.toString() ?? 'manual';
      state = state.copyWith(
        knownProjectsRoot: Directory(canonicalProjectPath(root)).parent.path,
        video: video,
        videoPath: sourceMissing ? null : _playbackVideoPath(video),
        reviewVideoPath: null,
        previewPath: null,
        previewTimeMs: _previewTimeForVideo(video),
        previewRefreshing: false,
        suggestedRoi: restoredRoiRect,
        netRoi: restoredNetRoi,
        hoopBbox: restoredHoopBbox,
        roiSource: restoredRoiRect == null ? null : restoredRoiSource,
        roiConfidence: (calibration?['confidence'] as num?)?.toDouble(),
        roiSuggestionError: null,
        job: null,
        exportJob: null,
        candidates: const <JsonMap>[],
        exportHistory: const <JsonMap>[],
        hydrating: video != null && session.videoId != null,
        hydrateError: null,
        workflowDraft: (payload['workflow_draft'] as Map?)
            ?.cast<String, dynamic>(),
        analysisMode: payload['analysis_mode']?.toString() == 'fast'
            ? 'fast'
            : 'standard',
      );
      await _rememberProjectsRoot(
        Directory(canonicalProjectPath(root)).parent.path,
      );
      opened = true;
      _reviewHistory.clear();
      if (sourceMissing) {
        _pushNotice('原始视频已移动，请重新定位后再开始分析或导出。', NoticeSeverity.error);
      } else if (video != null && payload['video'] != null) {
        final originalPath = (payload['video'] as Map?)?['source_path']
            ?.toString();
        if (originalPath != video['source_path']) {
          _pushNotice(
            analysisInvalidated
                ? '视频内容与原项目不一致，旧候选和 ROI 已清空，请重新设置后分析'
                : '视频已重新定位，项目数据和审核记录已保留',
            analysisInvalidated ? NoticeSeverity.info : NoticeSeverity.success,
          );
        }
      }
      if (video != null && session.videoId != null) {
        final scope = session.snapshot(requireVideo: true);
        unawaited(_hydrateOpenedProject(video, generation, scope));
      }
    });
    return opened;
  }

  Future<void> _hydrateOpenedProject(
    JsonMap video,
    int generation,
    ProjectSessionScope scope,
  ) async {
    final duration = (video['duration_ms'] as num?)?.toInt() ?? 1000;
    try {
      final modePayload = await scope.engine.getAnalysisMode(
        projectRoot: scope.projectRoot,
      );
      if (generation == _projectLoadGeneration) {
        state = state.copyWith(
          analysisMode: modePayload['mode']?.toString() == 'fast'
              ? 'fast'
              : 'standard',
        );
      }
    } catch (_) {
      // 旧项目没有模式记录时保持 standard。
    }
    try {
      final candidatePayload = await scope.listCandidates();
      final candidates =
          ((candidatePayload['candidates'] as List?) ?? const <dynamic>[])
              .whereType<Map>()
              .map((item) => item.cast<String, dynamic>())
              .toList();
      final reviewPath = candidatePayload['review_video_path']?.toString();
      if (generation != _projectLoadGeneration) return;
      state = state.copyWith(
        reviewVideoPath: reviewPath == null || reviewPath.isEmpty
            ? null
            : reviewPath,
        candidates: candidates,
        players: ((candidatePayload['players'] as List?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>())
            .toList(),
        hydrating: false,
        hydrateError: null,
      );
      unawaited(refreshStatistics(generation: generation, scope: scope));
    } catch (error) {
      if (!_disposed && generation == _projectLoadGeneration) {
        state = state.copyWith(
          hydrating: false,
          hydrateError: error.toString(),
        );
        _pushNotice('候选片段加载失败：$error', NoticeSeverity.error);
      }
    }
    try {
      final exports = await scope.listExports(limit: 5);
      if (!_disposed && generation == _projectLoadGeneration) {
        state = state.copyWith(exportHistory: exports);
      }
    } catch (error) {
      if (!_disposed && generation == _projectLoadGeneration) {
        _pushNotice('导出记录加载失败：$error', NoticeSeverity.error);
      }
    }
    try {
      final jobs = await Future.wait<dynamic>([
        scope.getActiveJobs(),
        scope.getActiveJobs(jobType: 'export'),
        scope.getLatestJob(),
        scope.getLatestJob(jobType: 'export'),
      ]);
      if (!_disposed && generation == _projectLoadGeneration) {
        final analysisJob = jobs[0].isEmpty ? null : jobs[0].last;
        final activeExportJob = jobs[1].isEmpty ? null : jobs[1].last;
        final latestAnalysisJob = jobs[2] as JsonMap?;
        final latestExportJob = jobs[3] as JsonMap?;
        state = state.copyWith(
          job: analysisJob ?? latestAnalysisJob,
          exportJob: activeExportJob ?? latestExportJob,
          analysisMode:
              _jobAnalysisMode(analysisJob ?? latestAnalysisJob) ??
              state.analysisMode,
        );
        final analysisId = analysisJob?['id'];
        if (analysisJob?['recovery_state'] == 'worker_attached' &&
            analysisId is String) {
          unawaited(pollJob(analysisId, scope: scope));
        }
        final exportId = activeExportJob?['id'];
        if (activeExportJob?['recovery_state'] == 'worker_attached' &&
            exportId is String) {
          unawaited(pollExportJob(exportId, scope: scope));
        }
      }
    } catch (error) {
      if (!_disposed && generation == _projectLoadGeneration) {
        _pushNotice('任务状态加载失败：$error', NoticeSeverity.error);
      }
    }
    try {
      final previewTimeMs = duration > 1000 ? 1000 : duration;
      final preview = await scope.extractPreview(timeMs: previewTimeMs);
      if (generation == _projectLoadGeneration) {
        state = state.copyWith(
          previewPath: preview['path']?.toString(),
          previewTimeMs: previewTimeMs,
          previewRefreshing: false,
        );
      }
    } catch (error) {
      if (!_disposed && generation == _projectLoadGeneration) {
        _pushNotice('视频预览加载失败：$error', NoticeSeverity.error);
      }
    }
  }

  Future<void> retryProjectHydration() async {
    final video = state.video;
    final scope = _captureScope();
    if (video == null || scope == null || state.hydrating) return;
    state = state.copyWith(hydrating: true, hydrateError: null);
    await _hydrateOpenedProject(video, _projectLoadGeneration, scope);
  }

  /// 等价 app.dart:_loadRecentProjects(385)。
  Future<void> loadRecentProjects() async {
    state = state.copyWith(recentLoading: true, recentError: null);
    try {
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final roots = <String>{_projectsRoot, ...await _recentProjectRoots()};
      final projectsByPath = <String, JsonMap>{};
      for (final root in roots) {
        List<JsonMap> projects;
        try {
          projects = await ref
              .read(projectSessionProvider)
              .loadRecentProjects(knownRoot: root);
        } catch (_) {
          continue;
        }
        for (final project in projects) {
          final projectRoot = project['project_root']?.toString();
          if (projectRoot == null || projectRoot.isEmpty) continue;
          projectsByPath[canonicalProjectPath(projectRoot)] = project;
        }
      }
      state = state.copyWith(
        recentProjects: projectsByPath.values.take(20).toList(),
      );
    } catch (error) {
      state = state.copyWith(recentError: error.toString());
    } finally {
      state = state.copyWith(recentLoading: false);
    }
  }

  /// 等价 app.dart:_saveRoi(404)。
  Future<bool> saveRoi(
    Rect normalized, {
    Rect? netRoi,
    bool showNotice = true,
  }) async {
    var saved = false;
    await _runBusy(() async {
      final video = state.video;
      if (video == null) throw const SessionStateException('视频元数据尚未准备好');
      final width = (video['width'] as num?)?.toDouble() ?? 0;
      final height = (video['height'] as num?)?.toDouble() ?? 0;
      if (width <= 0 || height <= 0) {
        throw const SessionStateException('视频分辨率无效');
      }
      final calibration = <String, dynamic>{'source': 'manual'};
      final hoopBbox = state.hoopBbox;
      if (hoopBbox != null) {
        calibration['hoop_bbox'] = <double>[
          hoopBbox.left * width,
          hoopBbox.top * height,
          hoopBbox.right * width,
          hoopBbox.bottom * height,
        ];
      }
      if (netRoi != null) {
        calibration['net_roi'] = <String, double>{
          'x1': netRoi.left * width,
          'y1': netRoi.top * height,
          'x2': netRoi.right * width,
          'y2': netRoi.bottom * height,
        };
      }
      await ref
          .read(projectSessionProvider)
          .saveRoi(
            x1: normalized.left * width,
            y1: normalized.top * height,
            x2: normalized.right * width,
            y2: normalized.bottom * height,
            calibration: calibration,
          );
      state = state.copyWith(
        roiSource: 'manual',
        netRoi: netRoi,
        roiConfidence: null,
        roiSuggestionError: null,
      );
      saved = true;
    }, successMessage: showNotice ? '篮筐区域已保存' : null);
    return saved;
  }

  Future<bool> saveAnalysisRange(
    int startMs,
    int endMs, {
    bool showNotice = true,
  }) async {
    var saved = false;
    await _runBusy(() async {
      final result = await ref
          .read(projectSessionProvider)
          .setAnalysisRange(startMs: startMs, endMs: endMs);
      final video = (result['video'] as Map?)?.cast<String, dynamic>();
      if (video != null) {
        state = state.copyWith(video: video, statistics: null);
      }
      saved = true;
    }, successMessage: showNotice ? '分析范围已保存' : null);
    return saved;
  }

  /// 等价 app.dart:_startAnalysis(445)。
  Future<bool> startAnalysis({
    bool replaceRecoverable = false,
    String? mode,
  }) async {
    var started = false;
    final requestedMode = mode == 'fast' || mode == 'standard'
        ? mode
        : state.analysisMode;
    await _runBusy(() async {
      await flushReviewQueue();
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final session = ref.read(projectSessionProvider);
      final activeJobs = await session.getActiveJobs();
      if (activeJobs.isNotEmpty) {
        final active = activeJobs.last;
        final activeId = active['id'];
        if (replaceRecoverable &&
            active['recoverable'] == true &&
            activeId is String) {
          final result = await session.retryAnalysis(
            jobId: activeId,
            mode: requestedMode,
            sampleFps: 10,
            beforeSeconds: 6,
            afterSeconds: 3,
          );
          state = state.copyWith(
            job: (result['job'] as Map?)?.cast<String, dynamic>(),
            analysisMode: requestedMode,
          );
          started = true;
          _pushNotice('已重新开始分析', NoticeSeverity.success);
          final newJobId = state.job?['id'];
          if (newJobId is String) unawaited(pollJob(newJobId));
          return;
        }
        state = state.copyWith(job: active);
        started = true;
        if (active['recovery_state'] == 'worker_attached') {
          final jobId = active['id'];
          if (jobId is String) unawaited(pollJob(jobId));
        }
        return;
      }
      final result = await session.startAnalysis(
        mode: requestedMode,
        sampleFps: 10,
        beforeSeconds: 6,
        afterSeconds: 3,
      );
      state = state.copyWith(
        job: (result['job'] as Map?)?.cast<String, dynamic>(),
        analysisMode: requestedMode,
      );
      started = true;
      _pushNotice('分析已开始，完成后会显示候选片段', NoticeSeverity.success);
      final jobId = state.job?['id'];
      if (jobId is! String) return;
      unawaited(pollJob(jobId));
    }, busyMessage: '正在启动分析…');
    return started;
  }

  /// 等价 app.dart:_pollJob(476)。Stream 监听逻辑原样迁移。
  Future<void> pollJob(String jobId, {ProjectSessionScope? scope}) async {
    if (_disposed || !_pollingJobIds.add(jobId)) return;
    final projectGeneration = _projectLoadGeneration;
    final requestScope = scope ?? _captureScope();
    if (requestScope == null) {
      _pollingJobIds.remove(jobId);
      return;
    }
    try {
      var refreshed = false;
      await for (final payload in requestScope.pollJob(jobId: jobId)) {
        if (_disposed || projectGeneration != _projectLoadGeneration) return;
        final nextJob = (payload['job'] as Map?)?.cast<String, dynamic>();
        final previousState = state.job?['state']?.toString();
        state = state.copyWith(job: nextJob);
        final nextState = nextJob?['state']?.toString();
        final terminal =
            nextState == 'completed' ||
            nextState == 'failed' ||
            nextState == 'cancelled';
        if (terminal && !refreshed) {
          await refreshCandidates(
            generation: projectGeneration,
            scope: requestScope,
          );
          if (_disposed || projectGeneration != _projectLoadGeneration) return;
          await refreshStatistics(
            generation: projectGeneration,
            scope: requestScope,
          );
          refreshed = true;
        }
        if (nextState != previousState) {
          if (nextState == 'completed') {
            _pushNotice('分析完成，候选片段已准备好', NoticeSeverity.success);
          } else if (nextState == 'cancelled') {
            _pushNotice('分析已取消', NoticeSeverity.success);
          } else if (nextState == 'failed') {
            _pushNotice(
              nextJob?['error_message']?.toString() ?? '分析失败',
              NoticeSeverity.error,
            );
          }
        }
      }
      if (_disposed || projectGeneration != _projectLoadGeneration) return;
      if (!refreshed) {
        await refreshCandidates(
          generation: projectGeneration,
          scope: requestScope,
        );
        if (_disposed || projectGeneration != _projectLoadGeneration) return;
        await refreshStatistics(
          generation: projectGeneration,
          scope: requestScope,
        );
      }
      if (_disposed || projectGeneration != _projectLoadGeneration) return;
      await refreshExportHistory(
        generation: projectGeneration,
        scope: requestScope,
      );
    } catch (error) {
      if (_disposed || projectGeneration != _projectLoadGeneration) return;
      _markEngineJobRecoverable(error, export: false);
      _pushNotice(error.toString(), NoticeSeverity.error);
    } finally {
      _pollingJobIds.remove(jobId);
    }
  }

  /// 等价 app.dart:_restoreActiveJob(510)。
  Future<void> restoreActiveJob() async {
    final scope = _captureScope();
    if (scope == null) return;
    final jobs = await scope.getActiveJobs();
    if (jobs.isEmpty) return;
    final active = jobs.last;
    state = state.copyWith(job: active);
    if (active['recovery_state'] == 'worker_attached' &&
        active['id'] is String) {
      unawaited(pollJob(active['id'] as String, scope: scope));
    }
  }

  /// 等价 app.dart:_retryAnalysis(521)。
  Future<void> retryAnalysis({String? mode}) async {
    final jobId = state.job?['id'];
    if (jobId is! String) return;
    final requestedMode = mode == 'fast' || mode == 'standard'
        ? mode
        : _jobAnalysisMode(state.job) ?? state.analysisMode;
    await _runBusy(() async {
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final result = await ref
          .read(projectSessionProvider)
          .retryAnalysis(
            jobId: jobId,
            mode: requestedMode,
            sampleFps: 10,
            beforeSeconds: 6,
            afterSeconds: 3,
          );
      state = state.copyWith(
        job: (result['job'] as Map?)?.cast<String, dynamic>(),
        analysisMode: requestedMode,
      );
      _pushNotice('已重新开始分析', NoticeSeverity.success);
      final newJobId = state.job?['id'];
      if (newJobId is String) unawaited(pollJob(newJobId));
    });
  }

  String? _jobAnalysisMode(JsonMap? job) {
    final checkpoint = job?['checkpoint'];
    if (checkpoint is Map) {
      final mode = checkpoint['mode']?.toString();
      if (mode == 'fast' || mode == 'standard') return mode;
    }
    final raw = job?['checkpoint_json']?.toString();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      final mode = decoded is Map ? decoded['mode']?.toString() : null;
      return mode == 'fast' || mode == 'standard' ? mode : null;
    } on FormatException {
      return null;
    }
  }

  /// 等价 app.dart:_cancelAnalysis(538)。
  Future<void> cancelAnalysis() async {
    final jobId = state.job?['id'];
    if (jobId is! String) return;
    final generation = _projectLoadGeneration;
    try {
      final result = await ref
          .read(projectSessionProvider)
          .cancelJob(jobId: jobId);
      if (_disposed ||
          generation != _projectLoadGeneration ||
          state.job?['id']?.toString() != jobId) {
        return;
      }
      state = state.copyWith(
        job: (result['job'] as Map?)?.cast<String, dynamic>(),
      );
      final nextState = state.job?['state']?.toString();
      if (nextState == 'cancelled') {
        _pushNotice('分析已取消', NoticeSeverity.success);
      } else {
        _pushNotice('正在取消分析…', NoticeSeverity.info);
        final scope = _captureScope();
        if (scope != null) unawaited(pollJob(jobId, scope: scope));
      }
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
    }
  }

  /// 等价 app.dart:_refreshCandidates(552)。
  Future<void> refreshCandidates({
    int? generation,
    ProjectSessionScope? scope,
  }) async {
    if (_disposed) return;
    final requestGeneration = generation ?? _projectLoadGeneration;
    final payload = scope == null
        ? await ref.read(projectSessionProvider).listCandidates()
        : await scope.listCandidates();
    if (_disposed || requestGeneration != _projectLoadGeneration) return;
    final reviewVideoPath = payload['review_video_path']?.toString();
    final reviewVideo = reviewVideoPath == null || reviewVideoPath.isEmpty
        ? null
        : reviewVideoPath;
    state = state.copyWith(
      candidates: ((payload['candidates'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList(),
      players: ((payload['players'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList(),
      reviewVideoPath: reviewVideo,
    );
  }

  Future<void> setAnalysisMode(String mode) async {
    if (mode != 'fast' && mode != 'standard') return;
    final result = await ref.read(projectSessionProvider).setAnalysisMode(mode);
    state = state.copyWith(
      analysisMode: result['mode']?.toString() == 'fast' ? 'fast' : 'standard',
    );
  }

  Future<String?> loadCandidatePreview(String candidateId, int timeMs) async {
    final cachedPath = state.candidates
        .cast<JsonMap?>()
        .firstWhere(
          (candidate) => candidate?['id']?.toString() == candidateId,
          orElse: () => null,
        )?['preview_path']
        ?.toString();
    if (cachedPath != null &&
        cachedPath.isNotEmpty &&
        File(cachedPath).existsSync()) {
      return cachedPath;
    }
    final preview = await ref
        .read(projectSessionProvider)
        .extractPreview(timeMs: timeMs);
    return preview['path']?.toString();
  }

  Future<void> refreshStatistics({
    int? generation,
    ProjectSessionScope? scope,
  }) async {
    if (_disposed) return;
    final requestGeneration = generation ?? _projectLoadGeneration;
    try {
      final payload = scope == null
          ? await ref.read(projectSessionProvider).getStatistics()
          : await scope.getStatistics();
      if (_disposed || requestGeneration != _projectLoadGeneration) return;
      final raw = payload['statistics'];
      state = state.copyWith(
        statistics: raw is Map
            ? Map<String, dynamic>.from(raw)
            : const <String, dynamic>{},
      );
    } catch (_) {
      // 统计是辅助展示，旧版 Engine 不支持时不阻塞审核流程。
    }
  }

  Future<void> startReview(String id) async {
    if (id.isEmpty) return;
    try {
      await ref.read(projectSessionProvider).startReview(id);
    } catch (error) {
      _pushNotice('开始记录审核耗时失败：$error', NoticeSeverity.error);
    }
  }

  /// 等价 app.dart:_reviewCandidate(567)。
  Future<bool> reviewCandidate(
    String id,
    String status, {
    String? reason,
    bool showNotice = true,
  }) async {
    final result = Completer<bool>();
    final generation = _projectLoadGeneration;
    final revision = (_reviewRevisions[id] ?? 0) + 1;
    _reviewRevisions[id] = revision;
    final previous = state.candidates.cast<JsonMap?>().firstWhere(
      (item) => item?['id']?.toString() == id,
      orElse: () => null,
    );
    final engineStatus = status == 'included' ? 'goal' : status;
    if (previous != null &&
        previous['review_status']?.toString() == engineStatus &&
        (reason == null || previous['review_reason']?.toString() == reason)) {
      return true;
    }
    final snapshot = previous == null
        ? null
        : _ReviewSnapshot(
            candidateId: id,
            status: previous['review_status']?.toString() ?? 'pending',
            reason: previous['review_reason']?.toString(),
            note: previous['note']?.toString(),
          );
    if (previous != null) {
      _setLocalReviewState(id, engineStatus, reason: reason);
    }
    _reviewQueue = _reviewQueue.then((_) async {
      if (_disposed || generation != _projectLoadGeneration) {
        result.complete(false);
        return;
      }
      try {
        await ref
            .read(projectSessionProvider)
            .reviewCandidate(
              id,
              status: engineStatus,
              reason: reason,
              note: snapshot?.note,
            );
        if (_disposed || generation != _projectLoadGeneration) {
          result.complete(false);
          return;
        }
        if (snapshot != null) _reviewHistory.add(snapshot);
        unawaited(refreshStatistics(generation: generation));
        if (showNotice) {
          _pushNotice(switch (status) {
            'goal' || 'included' => '已保留片段',
            'deferred' => '已暂缓审核',
            'second_review' => '已标记二次复核',
            'pending' => '已恢复待审核',
            _ => '已排除候选',
          }, NoticeSeverity.success);
        }
        result.complete(true);
      } catch (error) {
        if (!_disposed && generation == _projectLoadGeneration) {
          final current = state.candidates.cast<JsonMap?>().firstWhere(
            (item) => item?['id']?.toString() == id,
            orElse: () => null,
          );
          if (snapshot != null &&
              _reviewRevisions[id] == revision &&
              current?['review_status']?.toString() == engineStatus) {
            _setLocalReviewState(
              id,
              snapshot.status,
              reason: snapshot.reason,
              note: snapshot.note,
            );
          }
          _pushNotice(error.toString(), NoticeSeverity.error);
        }
        result.complete(false);
      }
    });
    return result.future;
  }

  void _setLocalReviewState(
    String id,
    String status, {
    String? reason,
    String? note,
  }) {
    state = state.copyWith(
      candidates: [
        for (final candidate in state.candidates)
          if (candidate['id']?.toString() == id)
            <String, dynamic>{
              ...candidate,
              'review_status': status,
              'selection_status': status == 'excluded'
                  ? 'excluded'
                  : 'included',
              'review_reason': reason,
              'note': note ?? candidate['note'],
            }
          else
            candidate,
      ],
    );
  }

  /// 等价 app.dart:_updateCandidateNote(587)。
  Future<void> updateCandidateNote(String id, String note) async {
    await _runBusy(() async {
      await flushReviewQueue();
      final candidate = state.candidates.cast<JsonMap?>().firstWhere(
        (item) => item?['id']?.toString() == id,
        orElse: () => null,
      );
      final status = candidate?['review_status']?.toString() ?? 'pending';
      final reason = candidate?['review_reason']?.toString();
      await ref
          .read(projectSessionProvider)
          .reviewCandidate(id, status: status, reason: reason, note: note);
      await refreshCandidates();
    }, successMessage: '备注已保存');
  }

  Future<List<JsonMap>> loadReviewHistory(String id) async {
    final payload = await ref
        .read(projectSessionProvider)
        .listReviewHistory(id);
    return ((payload['history'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
  }

  /// 等价 app.dart:_undoReview(599)。
  Future<void> undoReview() async {
    if (_reviewHistory.isEmpty) return;
    final snapshot = _reviewHistory.last;
    var succeeded = false;
    await _runBusy(() async {
      await flushReviewQueue();
      await ref
          .read(projectSessionProvider)
          .reviewCandidate(
            snapshot.candidateId,
            status: snapshot.status,
            reason: snapshot.reason,
            note: snapshot.note,
          );
      await refreshCandidates();
      succeeded = true;
    }, successMessage: '已撤销上一次审核');
    if (succeeded) _reviewHistory.removeLast();
  }

  /// 等价 app.dart:_updateClipRange(612)。
  Future<void> updateClipRange(String id, int startMs, int endMs) async {
    await _runBusy(() async {
      await ref
          .read(projectSessionProvider)
          .updateClipRange(candidateId: id, startMs: startMs, endMs: endMs);
      await refreshCandidates();
    }, successMessage: '片段范围已更新');
  }

  Future<JsonMap?> createManualCandidate({
    required int startMs,
    required int endMs,
    int? eventTimeMs,
  }) async {
    JsonMap? created;
    await _runBusy(() async {
      final payload = await ref
          .read(projectSessionProvider)
          .createManualCandidate(
            startMs: startMs,
            endMs: endMs,
            eventTimeMs: eventTimeMs,
          );
      final raw = payload['candidate'];
      if (raw is Map) created = Map<String, dynamic>.from(raw);
      await refreshCandidates();
    }, successMessage: '补漏片段已加入候选');
    return created;
  }

  Future<String?> createPlayer(String name) async {
    String? playerId;
    await _runBusy(() async {
      final created = await ref.read(projectSessionProvider).createPlayer(name);
      playerId = (created['player'] as Map?)?['id']?.toString();
      final payload = await ref.read(projectSessionProvider).listPlayers();
      state = state.copyWith(players: _jsonList(payload['players']));
    }, successMessage: '球员已添加');
    return playerId;
  }

  Future<bool> deletePlayer(String playerId) async {
    var deleted = false;
    await _runBusy(() async {
      await ref.read(projectSessionProvider).deletePlayer(playerId);
      final payload = await ref.read(projectSessionProvider).listPlayers();
      state = state.copyWith(players: _jsonList(payload['players']));
      await refreshCandidates();
      deleted = true;
    }, successMessage: '球员已删除');
    return deleted;
  }

  Future<void> setCandidatePlayer(String candidateId, String? playerId) async {
    await _runBusy(() async {
      await ref
          .read(projectSessionProvider)
          .setCandidatePlayer(candidateId: candidateId, playerId: playerId);
      await refreshCandidates();
    });
  }

  Future<void> setCandidatesPlayer(
    List<String> candidateIds,
    String? playerId,
  ) async {
    if (candidateIds.isEmpty) return;
    await _runBusy(() async {
      await ref
          .read(projectSessionProvider)
          .setCandidatesPlayer(candidateIds: candidateIds, playerId: playerId);
      await refreshCandidates();
    }, successMessage: '已更新 ${candidateIds.length} 个片段的球员标签');
  }

  /// 等价 app.dart:_export(623)。
  Future<void> export(
    String mode, {
    String? outputDir,
    String? outputPath,
    List<String>? playerIds,
    bool? includeUnassigned,
  }) async {
    if (state.busy || _isActiveJob(state.exportJob)) return;
    state = state.copyWith(busy: true);
    try {
      await flushReviewQueue();
      final result = await ref
          .read(projectSessionProvider)
          .startExport(
            mode: mode,
            outputDir: outputDir,
            outputPath: outputPath,
            playerIds: playerIds,
            includeUnassigned: includeUnassigned,
          );
      final job = (result['job'] as Map?)?.cast<String, dynamic>();
      state = state.copyWith(exportJob: job);
      final jobId = job?['id'];
      if (jobId is! String) {
        throw const SessionStateException('导出任务未返回 id');
      }
      // 只锁定“启动导出”这一小段时间；实际编码在后台轮询，审核仍可继续。
      state = state.copyWith(busy: false);
      unawaited(pollExportJob(jobId));
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
      state = state.copyWith(busy: false);
    }
  }

  /// 等价 app.dart:_pollExportJob(644)。Stream 监听逻辑原样迁移。
  Future<void> pollExportJob(String jobId, {ProjectSessionScope? scope}) async {
    if (_disposed || !_pollingExportJobIds.add(jobId)) return;
    final projectGeneration = _projectLoadGeneration;
    final requestScope = scope ?? _captureScope();
    if (requestScope == null) {
      _pollingExportJobIds.remove(jobId);
      return;
    }
    try {
      await for (final payload in requestScope.pollJob(jobId: jobId)) {
        if (_disposed || projectGeneration != _projectLoadGeneration) return;
        state = state.copyWith(
          exportJob: (payload['job'] as Map?)?.cast<String, dynamic>(),
        );
      }
      if (_disposed || projectGeneration != _projectLoadGeneration) return;
      await refreshExportHistory(
        generation: projectGeneration,
        scope: requestScope,
      );
      if (_disposed || projectGeneration != _projectLoadGeneration) return;
      await refreshStatistics(
        generation: projectGeneration,
        scope: requestScope,
      );
      final jobState = state.exportJob?['state']?.toString();
      if (jobState == 'completed') {
        _pushNotice('导出完成', NoticeSeverity.success);
      } else if (jobState == 'cancelled') {
        _pushNotice('导出已取消', NoticeSeverity.success);
      } else if (jobState == 'failed') {
        _pushNotice(
          state.exportJob?['error_message']?.toString() ?? '导出失败',
          NoticeSeverity.error,
        );
      }
    } catch (error) {
      if (_disposed || projectGeneration != _projectLoadGeneration) return;
      _markEngineJobRecoverable(error, export: true);
      _pushNotice(error.toString(), NoticeSeverity.error);
    } finally {
      _pollingExportJobIds.remove(jobId);
    }
  }

  /// 等价 app.dart:_cancelExport(670)。
  Future<void> cancelExport() async {
    final jobId = state.exportJob?['id'];
    if (jobId is! String) return;
    final generation = _projectLoadGeneration;
    try {
      final result = await ref
          .read(projectSessionProvider)
          .cancelJob(jobId: jobId);
      if (_disposed ||
          generation != _projectLoadGeneration ||
          state.exportJob?['id']?.toString() != jobId) {
        return;
      }
      state = state.copyWith(
        exportJob: (result['job'] as Map?)?.cast<String, dynamic>(),
      );
      final nextState = state.exportJob?['state']?.toString();
      if (nextState == 'cancelled') {
        _pushNotice('导出已取消', NoticeSeverity.success);
      } else {
        _pushNotice('正在取消导出…', NoticeSeverity.info);
        final scope = _captureScope();
        if (scope != null) unawaited(pollExportJob(jobId, scope: scope));
      }
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
    }
  }

  Future<void> retryExport() async {
    final jobId = state.exportJob?['id'];
    if (jobId is! String || state.busy || _isActiveJob(state.exportJob)) return;
    state = state.copyWith(busy: true);
    try {
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final result = await ref
          .read(projectSessionProvider)
          .retryExport(jobId: jobId);
      state = state.copyWith(
        exportJob: (result['job'] as Map?)?.cast<String, dynamic>(),
      );
      final newJobId = state.exportJob?['id'];
      state = state.copyWith(busy: false);
      if (newJobId is String) unawaited(pollExportJob(newJobId));
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
      state = state.copyWith(busy: false);
    }
  }

  /// 等价 app.dart:_refreshExportHistory(686)。
  Future<void> refreshExportHistory({
    int? generation,
    ProjectSessionScope? scope,
  }) async {
    if (_disposed) return;
    final requestGeneration = generation ?? _projectLoadGeneration;
    final history = scope == null
        ? await ref.read(projectSessionProvider).listExports(limit: 5)
        : await scope.listExports(limit: 5);
    if (_disposed || requestGeneration != _projectLoadGeneration) return;
    state = state.copyWith(exportHistory: history);
  }

  ProjectSessionScope? _captureScope() {
    if (_disposed) return null;
    try {
      return ref.read(projectSessionProvider).snapshot(requireVideo: true);
    } on SessionStateException {
      return null;
    }
  }

  /// 等价 app.dart:_runBusy(718)。busy=true → await action → busy=false。
  /// 错误改走 notice(原 _error/setState 已废)。
  Future<void> _runBusy(
    Future<void> Function() action, {
    String? successMessage,
    String? busyMessage,
  }) async {
    if (_disposed) return;
    if (state.busy) return;
    state = state.copyWith(busy: true, busyMessage: busyMessage);
    final completer = Completer<void>();
    _busyOperation = completer.future;
    try {
      await action();
      if (_disposed) return;
      if (successMessage != null) {
        _pushNotice(successMessage, NoticeSeverity.success);
      }
    } catch (error) {
      if (_disposed) return;
      _pushNotice(error.toString(), NoticeSeverity.error);
    } finally {
      if (!completer.isCompleted) completer.complete();
      if (!_disposed) state = state.copyWith(busy: false, busyMessage: null);
    }
  }

  /// 等价 app.dart:_showNotice(691)。原 SnackBar → noticeProvider.push。
  void _pushNotice(Object error, NoticeSeverity severity) {
    final content = userFacingNotice(error);
    if (_disposed || content.title.trim().isEmpty) return;
    ref
        .read(noticeProvider.notifier)
        .push(
          NoticeMessage(
            id: 'project-${DateTime.now().microsecondsSinceEpoch}-${_noticeCounter++}',
            severity: severity,
            title: content.title,
            description: content.description,
          ),
        );
  }

  /// 等价 app.dart:_projectsRoot(76)。env BHE_PROJECTS_ROOT > knownProjectsRoot >
  /// $HOME/Movies/BasketballProjects。
  String get _projectsRoot {
    final configured = Platform.environment['BHE_PROJECTS_ROOT'];
    if (configured != null && configured.trim().isNotEmpty) return configured;
    final current = state.knownProjectsRoot;
    if (current != null && current.isNotEmpty) return current;
    final home = Platform.environment['HOME'];
    return '${home ?? Directory.current.path}/Movies/BasketballProjects';
  }

  Future<List<String>> _recentProjectRoots() async {
    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 250),
      );
      return preferences.getStringList(_recentProjectRootsKey) ??
          const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> _rememberProjectsRoot(String root) async {
    try {
      final canonical = canonicalProjectPath(root);
      final preferences = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 250),
      );
      final roots = <String>{
        canonical,
        ...preferences.getStringList(_recentProjectRootsKey) ??
            const <String>[],
      }.take(12).toList();
      await preferences.setStringList(_recentProjectRootsKey, roots);
    } catch (_) {}
  }

  bool _isActiveJob(JsonMap? job) {
    final jobState = job?['state']?.toString();
    final recoveryState = job?['recovery_state']?.toString();
    return (jobState == 'queued' || jobState == 'running') &&
        (recoveryState == null || recoveryState == 'worker_attached');
  }

  void _markEngineJobRecoverable(Object error, {required bool export}) {
    if (error is! EngineException ||
        !const <String>{
          'ENGINE_EXITED',
          'ENGINE_NOT_RUNNING',
          'ENGINE_TIMEOUT',
          'ENGINE_WRITE_FAILED',
          'ENGINE_DISPOSED',
        }.contains(error.code)) {
      return;
    }
    ref.read(engineBootstrapProvider.notifier).markUnavailable(error);
    final current = export ? state.exportJob : state.job;
    if (current == null) return;
    final recoverable = <String, dynamic>{
      ...current,
      'state': 'failed',
      'recovery_state': 'stale_recoverable',
      'recoverable': true,
      'error_code': error.code,
      'error_message': error.message,
    };
    state = export
        ? state.copyWith(exportJob: recoverable)
        : state.copyWith(job: recoverable);
  }

  Rect? _draftRect(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final x1 = (map['x1'] as num?)?.toDouble();
    final y1 = (map['y1'] as num?)?.toDouble();
    final x2 = (map['x2'] as num?)?.toDouble();
    final y2 = (map['y2'] as num?)?.toDouble();
    if ([x1, y1, x2, y2].any((value) => value == null)) return null;
    return Rect.fromLTRB(x1!, y1!, x2!, y2!);
  }

  /// 等价 app.dart:_normalizeRoi(430)。原始像素坐标 → 归一化 [0,1]。
  Rect _normalizeRoi(Map<String, dynamic> roi, Map<String, dynamic> video) {
    final width = (video['width'] as num?)?.toDouble() ?? 1;
    final height = (video['height'] as num?)?.toDouble() ?? 1;
    final x1 = (roi['x1'] as num?)?.toDouble() ?? 0;
    final y1 = (roi['y1'] as num?)?.toDouble() ?? 0;
    final x2 = (roi['x2'] as num?)?.toDouble() ?? width;
    final y2 = (roi['y2'] as num?)?.toDouble() ?? height;
    return Rect.fromLTRB(
      (x1 / width).clamp(0.0, 1.0).toDouble(),
      (y1 / height).clamp(0.0, 1.0).toDouble(),
      (x2 / width).clamp(0.0, 1.0).toDouble(),
      (y2 / height).clamp(0.0, 1.0).toDouble(),
    );
  }

  Rect? _normalizeBbox(List<dynamic> bbox, Map<String, dynamic> video) {
    if (bbox.length != 4 || bbox.any((value) => value is! num)) return null;
    final width = (video['width'] as num?)?.toDouble() ?? 0;
    final height = (video['height'] as num?)?.toDouble() ?? 0;
    if (width <= 0 || height <= 0) return null;
    final x1 = (bbox[0] as num).toDouble();
    final y1 = (bbox[1] as num).toDouble();
    final x2 = (bbox[2] as num).toDouble();
    final y2 = (bbox[3] as num).toDouble();
    if (x2 <= x1 || y2 <= y1) return null;
    return Rect.fromLTRB(
      (x1 / width).clamp(0.0, 1.0).toDouble(),
      (y1 / height).clamp(0.0, 1.0).toDouble(),
      (x2 / width).clamp(0.0, 1.0).toDouble(),
      (y2 / height).clamp(0.0, 1.0).toDouble(),
    );
  }
}

final NotifierProvider<ProjectNotifier, ProjectState> projectProvider =
    NotifierProvider<ProjectNotifier, ProjectState>(ProjectNotifier.new);

String? _playbackVideoPath(JsonMap? video) => video?['source_path']?.toString();

List<JsonMap> _jsonList(Object? raw) {
  if (raw is! List) return <JsonMap>[];
  return raw
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}
