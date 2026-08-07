// lib/providers/project_state.dart
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine_session.dart';
import '../core/project_session.dart';
import 'notice_provider.dart';
import 'session_provider.dart';

/// 单进程内共享的 ProjectSession。封装 EngineSession(engineClientProvider)。
final Provider<ProjectSession> projectSessionProvider =
    Provider<ProjectSession>((ref) {
      return ProjectSession(EngineSession(ref.read(engineClientProvider)));
    });

/// 不可变项目会话状态。字段映射 app.dart:_BasketballHighlightAppState 的
/// 可观察字段(_themeMode/_section/_engineReady/_error 不在此处):
/// - _video/_videoPath/_reviewVideoPath/_previewPath
/// - _suggestedRoi/_roiSource/_roiConfidence/_roiSuggestionError
/// - _job/_exportJob/_candidates/_recentProjects/_exportHistory
/// - _busy/_recentProjectsLoading/_recentProjectsError/_knownProjectsRoot
class ProjectState {
  const ProjectState({
    this.video,
    this.videoPath,
    this.reviewVideoPath,
    this.previewPath,
    this.suggestedRoi,
    this.roiSource,
    this.roiConfidence,
    this.roiSuggestionError,
    this.job,
    this.exportJob,
    this.candidates = const <JsonMap>[],
    this.recentProjects = const <JsonMap>[],
    this.exportHistory = const <JsonMap>[],
    this.busy = false,
    this.recentLoading = false,
    this.recentError,
    this.knownProjectsRoot,
  });

  final JsonMap? video;
  final String? videoPath;
  final String? reviewVideoPath;
  final String? previewPath;
  final Rect? suggestedRoi;
  final String? roiSource;
  final double? roiConfidence;
  final String? roiSuggestionError;
  final JsonMap? job;
  final JsonMap? exportJob;
  final List<JsonMap> candidates;
  final List<JsonMap> recentProjects;
  final List<JsonMap> exportHistory;
  final bool busy;
  final bool recentLoading;
  final String? recentError;
  final String? knownProjectsRoot;

  /// 可空字段使用 sentinel 区分"未传入"与"显式置 null"。
  /// 非空集合/布尔字段使用普通可选参数(默认保留旧值)。
  ProjectState copyWith({
    Object? video = _unset,
    Object? videoPath = _unset,
    Object? reviewVideoPath = _unset,
    Object? previewPath = _unset,
    Object? suggestedRoi = _unset,
    Object? roiSource = _unset,
    Object? roiConfidence = _unset,
    Object? roiSuggestionError = _unset,
    Object? job = _unset,
    Object? exportJob = _unset,
    Object? recentError = _unset,
    Object? knownProjectsRoot = _unset,
    List<JsonMap>? candidates,
    List<JsonMap>? recentProjects,
    List<JsonMap>? exportHistory,
    bool? busy,
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
      suggestedRoi: identical(suggestedRoi, _unset)
          ? this.suggestedRoi
          : suggestedRoi as Rect?,
      roiSource: identical(roiSource, _unset)
          ? this.roiSource
          : roiSource as String?,
      roiConfidence: identical(roiConfidence, _unset)
          ? this.roiConfidence
          : roiConfidence as double?,
      roiSuggestionError: identical(roiSuggestionError, _unset)
          ? this.roiSuggestionError
          : roiSuggestionError as String?,
      job: identical(job, _unset) ? this.job : job as JsonMap?,
      exportJob: identical(exportJob, _unset)
          ? this.exportJob
          : exportJob as JsonMap?,
      candidates: candidates ?? this.candidates,
      recentProjects: recentProjects ?? this.recentProjects,
      exportHistory: exportHistory ?? this.exportHistory,
      busy: busy ?? this.busy,
      recentLoading: recentLoading ?? this.recentLoading,
      recentError: identical(recentError, _unset)
          ? this.recentError
          : recentError as String?,
      knownProjectsRoot: identical(knownProjectsRoot, _unset)
          ? this.knownProjectsRoot
          : knownProjectsRoot as String?,
    );
  }
}

const Object _unset = Object();

/// 审核撤销快照(原 app.dart:_ReviewSnapshot)。Notifier 私有,不入 ProjectState。
class _ReviewSnapshot {
  const _ReviewSnapshot({
    required this.candidateId,
    required this.status,
    required this.note,
  });

  final String candidateId;
  final String status;
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
  @override
  ProjectState build() => const ProjectState();

  final List<_ReviewSnapshot> _reviewHistory = <_ReviewSnapshot>[];
  final Set<String> _pollingJobIds = <String>{};
  int _projectLoadGeneration = 0;
  int _noticeCounter = 0;

  /// 等价 app.dart:_selectVideo(228)。
  Future<void> selectVideo(String path) async {
    await _runBusy(() async {
      _projectLoadGeneration++;
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final session = ref.read(projectSessionProvider);
      final source = File(path).absolute;
      final stem = source.uri.pathSegments.last.replaceFirst(
        RegExp(r'\.[^.]+$'),
        '',
      );
      final knownRoot = state.knownProjectsRoot ?? _projectsRoot;
      final projectRoot =
          '$knownRoot/$stem-${DateTime.now().millisecondsSinceEpoch}';
      await session.createProject(name: stem, rootPath: projectRoot);
      final linked = await session.linkVideo(path);
      final duration =
          ((linked['video'] as Map?)?['duration_ms'] as num?)?.toInt() ?? 1001;
      final preview = await session.extractPreview(
        timeMs: duration > 1000 ? 1000 : duration,
      );
      Rect? suggestedRoi;
      String? roiSource;
      double? roiConfidence;
      String? roiSuggestionError;
      try {
        final suggestion = await session.suggestRoi(
          duration: 20,
          sampleFps: 1,
          maxSamples: 12,
          confidence: 0.05,
        );
        final roi = (suggestion['roi'] as Map?)?.cast<String, dynamic>();
        final linkedVideo = (linked['video'] as Map?)?.cast<String, dynamic>();
        if (roi != null && linkedVideo != null) {
          suggestedRoi = _normalizeRoi(roi, linkedVideo);
          final calibration = (suggestion['calibration'] as Map?)
              ?.cast<String, dynamic>();
          await session.saveRoi(
            x1: roi['x1'] as num,
            y1: roi['y1'] as num,
            x2: roi['x2'] as num,
            y2: roi['y2'] as num,
            calibration: calibration,
          );
          roiSource = 'auto';
          roiConfidence = (calibration?['confidence'] as num?)?.toDouble();
        }
      } catch (error) {
        // 自动 ROI 是便利功能,失败不应阻塞导入,用户可手动框选。
        roiSuggestionError = error.toString();
      }
      state = state.copyWith(
        knownProjectsRoot: knownRoot,
        videoPath: path,
        reviewVideoPath: null,
        previewPath: preview['path']?.toString(),
        suggestedRoi: suggestedRoi,
        roiSource: roiSource,
        roiConfidence: roiConfidence,
        roiSuggestionError: roiSuggestionError,
        video: (linked['video'] as Map?)?.cast<String, dynamic>(),
        job: null,
        exportJob: null,
        candidates: <JsonMap>[],
        exportHistory: <JsonMap>[],
      );
      _reviewHistory.clear();
    }, successMessage: '视频已加载，已优先尝试自动识别篮筐区域');
  }

  /// 等价 app.dart:_chooseOpenProject(297)。
  Future<void> chooseOpenProject() async {
    final root = await getDirectoryPath(confirmButtonText: '打开项目');
    if (root != null) await openProject(root);
  }

  /// 等价 app.dart:_openProject(302)。
  Future<void> openProject(String root) async {
    await _runBusy(() async {
      final generation = ++_projectLoadGeneration;
      state = state.copyWith(
        video: null,
        videoPath: null,
        reviewVideoPath: null,
        previewPath: null,
        suggestedRoi: null,
        roiSource: null,
        roiConfidence: null,
        roiSuggestionError: null,
        job: null,
        exportJob: null,
        candidates: const <JsonMap>[],
        exportHistory: const <JsonMap>[],
      );
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final session = ref.read(projectSessionProvider);
      final payload = await session.openProject(root);
      var video = (payload['video'] as Map?)?.cast<String, dynamic>();
      var sourceMissing = false;
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
            sourceMissing = false;
          }
        }
      }
      final restoredRoi = (payload['roi'] as Map?)?.cast<String, dynamic>();
      final calibration = (restoredRoi?['calibration'] as Map?)
          ?.cast<String, dynamic>();
      final restoredRoiRect = video == null || restoredRoi == null
          ? null
          : _normalizeRoi(restoredRoi, video);
      final restoredRoiSource = calibration?['source']?.toString() ?? 'manual';
      state = state.copyWith(
        knownProjectsRoot: Directory(root).parent.path,
        video: video,
        videoPath: sourceMissing ? null : video?['source_path']?.toString(),
        reviewVideoPath: null,
        previewPath: null,
        suggestedRoi: restoredRoiRect,
        roiSource: restoredRoiRect == null ? null : restoredRoiSource,
        roiConfidence: (calibration?['confidence'] as num?)?.toDouble(),
        roiSuggestionError: null,
        job: null,
        exportJob: null,
        candidates: const <JsonMap>[],
        exportHistory: const <JsonMap>[],
      );
      _reviewHistory.clear();
      if (sourceMissing) {
        _pushNotice('原始视频已移动，请重新定位后再开始分析或导出。', NoticeSeverity.error);
      } else if (video != null && payload['video'] != null) {
        final originalPath = (payload['video'] as Map?)?['source_path']
            ?.toString();
        if (originalPath != video['source_path']) {
          _pushNotice('视频已重新定位，项目数据和审核记录已保留', NoticeSeverity.success);
        }
      }
      if (video != null) {
        unawaited(_hydrateOpenedProject(video, generation));
      }
    });
  }

  Future<void> _hydrateOpenedProject(JsonMap video, int generation) async {
    try {
      final duration = (video['duration_ms'] as num?)?.toInt() ?? 1000;
      final results = await Future.wait<Object?>([
        ref
            .read(projectSessionProvider)
            .extractPreview(timeMs: duration > 1000 ? 1000 : duration),
        ref.read(projectSessionProvider).listCandidates(),
        ref.read(projectSessionProvider).listExports(limit: 5),
        ref.read(projectSessionProvider).getActiveJobs(),
        ref.read(projectSessionProvider).getActiveExportJobs(),
      ]);
      final preview = results[0] as JsonMap;
      final candidatePayload = results[1] as JsonMap;
      final candidates =
          ((candidatePayload['candidates'] as List?) ?? const <dynamic>[])
              .whereType<Map>()
              .map((item) => item.cast<String, dynamic>())
              .toList();
      final reviewPath = candidatePayload['review_video_path']?.toString();
      final analysisJobs = results[3] as List<JsonMap>;
      final exportJobs = results[4] as List<JsonMap>;
      final analysisJob = analysisJobs.isEmpty ? null : analysisJobs.last;
      final exportJob = exportJobs.isEmpty ? null : exportJobs.last;
      if (generation != _projectLoadGeneration) return;
      state = state.copyWith(
        previewPath: preview['path']?.toString(),
        reviewVideoPath: reviewPath == null || reviewPath.isEmpty
            ? null
            : reviewPath,
        candidates: candidates,
        exportHistory: results[2] as List<JsonMap>,
        job: analysisJob,
        exportJob: exportJob,
      );
      final analysisId = analysisJob?['id'];
      if (analysisJob?['recovery_state'] == 'worker_attached' &&
          analysisId is String) {
        unawaited(pollJob(analysisId));
      }
      final exportId = exportJob?['id'];
      if (exportJob?['recovery_state'] == 'worker_attached' &&
          exportId is String) {
        unawaited(pollExportJob(exportId));
      }
    } catch (error) {
      _pushNotice('项目已打开，但部分数据加载失败：$error', NoticeSeverity.error);
    }
  }

  /// 等价 app.dart:_loadRecentProjects(385)。
  Future<void> loadRecentProjects() async {
    state = state.copyWith(recentLoading: true, recentError: null);
    try {
      await ref.read(engineBootstrapProvider.notifier).ensure();
      final projects = await ref
          .read(projectSessionProvider)
          .loadRecentProjects(knownRoot: _projectsRoot);
      state = state.copyWith(recentProjects: projects);
    } catch (error) {
      state = state.copyWith(recentError: error.toString());
    } finally {
      state = state.copyWith(recentLoading: false);
    }
  }

  /// 等价 app.dart:_saveRoi(404)。
  Future<void> saveRoi(Rect normalized) async {
    await _runBusy(() async {
      final video = state.video;
      if (video == null) throw const SessionStateException('视频元数据尚未准备好');
      final width = (video['width'] as num?)?.toDouble() ?? 0;
      final height = (video['height'] as num?)?.toDouble() ?? 0;
      if (width <= 0 || height <= 0) {
        throw const SessionStateException('视频分辨率无效');
      }
      await ref
          .read(projectSessionProvider)
          .saveRoi(
            x1: normalized.left * width,
            y1: normalized.top * height,
            x2: normalized.right * width,
            y2: normalized.bottom * height,
            calibration: const <String, dynamic>{'source': 'manual'},
          );
      state = state.copyWith(
        roiSource: 'manual',
        roiConfidence: null,
        roiSuggestionError: null,
      );
    }, successMessage: '篮筐区域已保存');
  }

  /// 等价 app.dart:_startAnalysis(445)。
  Future<void> startAnalysis() async {
    await _runBusy(() async {
      final session = ref.read(projectSessionProvider);
      final activeJobs = await session.getActiveJobs();
      if (activeJobs.isNotEmpty) {
        final active = activeJobs.last;
        state = state.copyWith(job: active);
        if (active['recovery_state'] == 'worker_attached') {
          final jobId = active['id'];
          if (jobId is String) unawaited(pollJob(jobId));
        }
        return;
      }
      final result = await session.startAnalysis(
        sampleFps: 10,
        beforeSeconds: 6,
        afterSeconds: 3,
      );
      state = state.copyWith(
        job: (result['job'] as Map?)?.cast<String, dynamic>(),
        candidates: const <JsonMap>[],
        reviewVideoPath: null,
      );
      _pushNotice('分析已开始，候选会在处理过程中陆续更新', NoticeSeverity.success);
      final jobId = state.job?['id'];
      if (jobId is! String) return;
      unawaited(pollJob(jobId));
    });
  }

  /// 等价 app.dart:_pollJob(476)。Stream 监听逻辑原样迁移。
  Future<void> pollJob(String jobId) async {
    if (!_pollingJobIds.add(jobId)) return;
    try {
      var refreshed = false;
      await for (final payload
          in ref.read(projectSessionProvider).pollJob(jobId: jobId)) {
        final nextJob = (payload['job'] as Map?)?.cast<String, dynamic>();
        final previousState = state.job?['state']?.toString();
        state = state.copyWith(job: nextJob);
        final nextState = nextJob?['state']?.toString();
        final terminal =
            nextState == 'completed' ||
            nextState == 'failed' ||
            nextState == 'cancelled';
        if (terminal && !refreshed) {
          await refreshCandidates();
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
      if (!refreshed) await refreshCandidates();
      await refreshExportHistory();
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
    } finally {
      _pollingJobIds.remove(jobId);
    }
  }

  /// 等价 app.dart:_restoreActiveJob(510)。
  Future<void> restoreActiveJob() async {
    final jobs = await ref.read(projectSessionProvider).getActiveJobs();
    if (jobs.isEmpty) return;
    final active = jobs.last;
    state = state.copyWith(job: active);
    if (active['recovery_state'] == 'worker_attached' &&
        active['id'] is String) {
      unawaited(pollJob(active['id'] as String));
    }
  }

  /// 等价 app.dart:_retryAnalysis(521)。
  Future<void> retryAnalysis() async {
    final jobId = state.job?['id'];
    if (jobId is! String) return;
    await _runBusy(() async {
      final result = await ref
          .read(projectSessionProvider)
          .retryAnalysis(
            jobId: jobId,
            sampleFps: 10,
            beforeSeconds: 6,
            afterSeconds: 3,
          );
      state = state.copyWith(
        job: (result['job'] as Map?)?.cast<String, dynamic>(),
      );
      _pushNotice('已重新开始分析', NoticeSeverity.success);
      final newJobId = state.job?['id'];
      if (newJobId is String) unawaited(pollJob(newJobId));
    });
  }

  /// 等价 app.dart:_cancelAnalysis(538)。
  Future<void> cancelAnalysis() async {
    final jobId = state.job?['id'];
    if (jobId is! String) return;
    try {
      final result = await ref
          .read(projectSessionProvider)
          .cancelJob(jobId: jobId);
      state = state.copyWith(
        job: (result['job'] as Map?)?.cast<String, dynamic>(),
      );
      _pushNotice('分析已取消', NoticeSeverity.success);
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
    }
  }

  /// 等价 app.dart:_refreshCandidates(552)。
  Future<void> refreshCandidates() async {
    final payload = await ref.read(projectSessionProvider).listCandidates();
    final reviewVideoPath = payload['review_video_path']?.toString();
    final reviewVideo = reviewVideoPath == null || reviewVideoPath.isEmpty
        ? null
        : reviewVideoPath;
    state = state.copyWith(
      candidates: ((payload['candidates'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList(),
      reviewVideoPath: reviewVideo,
    );
  }

  /// 等价 app.dart:_reviewCandidate(567)。
  Future<void> reviewCandidate(String id, String status) async {
    await _runBusy(() async {
      final previous = state.candidates.cast<JsonMap?>().firstWhere(
        (item) => item?['id']?.toString() == id,
        orElse: () => null,
      );
      if (previous != null) {
        _reviewHistory.add(
          _ReviewSnapshot(
            candidateId: id,
            status: previous['review_status']?.toString() ?? 'pending',
            note: previous['note']?.toString(),
          ),
        );
      }
      await ref
          .read(projectSessionProvider)
          .reviewCandidate(id, status: status);
      await refreshCandidates();
    }, successMessage: status == 'goal' ? '已确认进球' : '已排除候选');
  }

  /// 等价 app.dart:_updateCandidateNote(587)。
  Future<void> updateCandidateNote(String id, String note) async {
    await _runBusy(() async {
      final candidate = state.candidates.cast<JsonMap?>().firstWhere(
        (item) => item?['id']?.toString() == id,
        orElse: () => null,
      );
      final status = candidate?['review_status']?.toString() ?? 'pending';
      await ref
          .read(projectSessionProvider)
          .reviewCandidate(id, status: status, note: note);
      await refreshCandidates();
    }, successMessage: '备注已保存');
  }

  /// 等价 app.dart:_undoReview(599)。
  Future<void> undoReview() async {
    if (_reviewHistory.isEmpty) return;
    final snapshot = _reviewHistory.removeLast();
    await _runBusy(() async {
      await ref
          .read(projectSessionProvider)
          .reviewCandidate(
            snapshot.candidateId,
            status: snapshot.status,
            note: snapshot.note,
          );
      await refreshCandidates();
    }, successMessage: '已撤销上一次审核');
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

  /// 等价 app.dart:_export(623)。
  Future<void> export(
    String mode, {
    String? outputDir,
    String? outputPath,
  }) async {
    await _runBusy(() async {
      final result = await ref
          .read(projectSessionProvider)
          .startExport(
            mode: mode,
            outputDir: outputDir,
            outputPath: outputPath,
          );
      final job = (result['job'] as Map?)?.cast<String, dynamic>();
      state = state.copyWith(exportJob: job);
      final jobId = job?['id'];
      if (jobId is! String) {
        throw const SessionStateException('导出任务未返回 id');
      }
      await pollExportJob(jobId);
    });
  }

  /// 等价 app.dart:_pollExportJob(644)。Stream 监听逻辑原样迁移。
  Future<void> pollExportJob(String jobId) async {
    try {
      await for (final payload
          in ref.read(projectSessionProvider).pollJob(jobId: jobId)) {
        state = state.copyWith(
          exportJob: (payload['job'] as Map?)?.cast<String, dynamic>(),
        );
      }
      await refreshExportHistory();
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
      _pushNotice(error.toString(), NoticeSeverity.error);
    }
  }

  /// 等价 app.dart:_cancelExport(670)。
  Future<void> cancelExport() async {
    final jobId = state.exportJob?['id'];
    if (jobId is! String) return;
    try {
      final result = await ref
          .read(projectSessionProvider)
          .cancelJob(jobId: jobId);
      state = state.copyWith(
        exportJob: (result['job'] as Map?)?.cast<String, dynamic>(),
      );
      _pushNotice('导出已取消', NoticeSeverity.success);
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
    }
  }

  Future<void> retryExport() async {
    final jobId = state.exportJob?['id'];
    if (jobId is! String) return;
    await _runBusy(() async {
      final result = await ref
          .read(projectSessionProvider)
          .retryExport(jobId: jobId);
      state = state.copyWith(
        exportJob: (result['job'] as Map?)?.cast<String, dynamic>(),
      );
      final newJobId = state.exportJob?['id'];
      if (newJobId is String) await pollExportJob(newJobId);
    });
  }

  /// 等价 app.dart:_refreshExportHistory(686)。
  Future<void> refreshExportHistory() async {
    final history = await ref
        .read(projectSessionProvider)
        .listExports(limit: 5);
    state = state.copyWith(exportHistory: history);
  }

  /// 等价 app.dart:_runBusy(718)。busy=true → await action → busy=false。
  /// 错误改走 notice(原 _error/setState 已废)。
  Future<void> _runBusy(
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    if (state.busy) return;
    state = state.copyWith(busy: true);
    try {
      await action();
      if (successMessage != null) {
        _pushNotice(successMessage, NoticeSeverity.success);
      }
    } catch (error) {
      _pushNotice(error.toString(), NoticeSeverity.error);
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// 等价 app.dart:_showNotice(691)。原 SnackBar → noticeProvider.push。
  void _pushNotice(String title, NoticeSeverity severity) {
    if (title.trim().isEmpty) return;
    ref
        .read(noticeProvider.notifier)
        .push(
          NoticeMessage(
            id: 'project-${DateTime.now().microsecondsSinceEpoch}-${_noticeCounter++}',
            severity: severity,
            title: title,
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
}

final NotifierProvider<ProjectNotifier, ProjectState> projectProvider =
    NotifierProvider<ProjectNotifier, ProjectState>(ProjectNotifier.new);
