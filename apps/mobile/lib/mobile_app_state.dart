import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'features/review_undo/review_history.dart';
import 'features/review_undo/review_action_result.dart';
import 'features/player_roster/roster_selection.dart';
import 'features/player_groups/player_group_store.dart';
import 'features/project_list/project_catalog.dart';
import 'features/export/export_modes.dart';

export 'features/review_undo/review_action_result.dart';
import 'features/project_mutation/project_mutation_queue.dart';
import 'features/project_mutation/analysis_candidate_merge.dart';
import 'features/video_source/project_paths.dart';
import 'features/video_source/project_file_commit.dart';
import 'features/video_source/video_source_store.dart';
import 'features/video_source/video_source_failure.dart';
import 'media_bridge.dart';
import 'features/diagnostics/diagnostic_state.dart';
import 'features/diagnostics/mobile_diagnostics.dart';
import 'features/operation_status/task_stop_status.dart';
export 'features/operation_status/task_stop_status.dart';

import 'native_analysis_engine.dart';

part 'features/project_list/project_management.dart';
part 'features/export/label_export_batch.dart';
part 'features/export_history/export_history_state.dart';

class MobileAppState extends ChangeNotifier with MobileDiagnosticState {
  MobileAppState({
    MobileAnalysisEngine? analysisEngine,
    MobileExportEngine? exportEngine,
    VideoSourceStore? videoSourceStore,
    this.videoProbe,
    this.exportCancelTimeout = const Duration(seconds: 5),
    this.exportDrainTimeout = const Duration(seconds: 30),
    this.analysisStartupTimeout = const Duration(seconds: 60),
    this.analysisCancelTimeout = const Duration(seconds: 6),
    this.pickerRetryDelay = const Duration(milliseconds: 1500),
    MobileFilePicker? filePicker,
  }) : analysisEngine = analysisEngine ?? NativeAnalysisEngine(),
       exportEngine = exportEngine ?? NativeMediaExportEngine(),
       _filePicker = filePicker ?? _systemFilePicker,
       _providedVideoStore = videoSourceStore {
    ready = Future.wait([loadSavedProject(), _loadPlayerGroups()]).then((_) {});
  }

  late final Future<void> ready;
  final VideoSourceStore? _providedVideoStore;
  final MobileFilePicker _filePicker;

  /// 已经拿到 already_active 后要等多久再试一次（测试里调小）。
  final Duration pickerRetryDelay;

  /// 系统选文件窗口的「占用中」标记：占用中再点入口直接忽略，按钮置灰。
  bool get pickerBusy => _pickerBusy;
  bool _pickerBusy = false;

  /// 统一包住两处 pickFiles：互斥、错误提示、already_active 重试都在这里。
  Future<FilePickerResult?> _pickFiles({
    required FileType type,
    required String kind,
    List<String>? allowedExtensions,
  }) async {
    if (_pickerBusy) return null;
    _pickerBusy = true;
    notifyListeners();
    try {
      try {
        MobileDiagnostics.instance.event('picker.open.$kind');
        final result = await _filePicker(
          type: type,
          allowedExtensions: allowedExtensions,
        );
        MobileDiagnostics.instance.event(
          result == null ? 'picker.cancelled.$kind' : 'picker.result.$kind',
        );
        return result;
      } on PlatformException catch (error) {
        MobileDiagnostics.instance.event(
          'picker.error.$kind',
          count: 1,
        );
        if (!_isPickerAlreadyActive(error)) rethrow;
        // 小米等系统在上一轮选择还没真正结束时仍报 already_active：
        // 延迟后重试一次；还失败就把原始错误交给上层给用户人话提示。
        await Future<void>.delayed(pickerRetryDelay);
        MobileDiagnostics.instance.event('picker.retry.$kind', count: 2);
        final retried = await _filePicker(
          type: type,
          allowedExtensions: allowedExtensions,
        );
        MobileDiagnostics.instance.event(
          retried == null
              ? 'picker.cancelled.$kind.attempt2'
              : 'picker.result.$kind.attempt2',
        );
        return retried;
      }
    } finally {
      _pickerBusy = false;
      notifyListeners();
    }
  }

  /// 只认 file_picker 的 already_active（部分机型把它塞进 message）。
  static bool _isPickerAlreadyActive(PlatformException error) {
    final code = error.code.toLowerCase();
    return code == 'already_active' ||
        error.message?.toLowerCase().contains('already active') == true;
  }
  final Future<VideoInfo> Function(File)? videoProbe;
  final Duration exportCancelTimeout;
  final Duration exportDrainTimeout;
  final Duration analysisStartupTimeout;
  final Duration analysisCancelTimeout;
  late final VideoSourceStore _videoStore =
      _providedVideoStore ??
      VideoSourceStore(
        dataDirectory: _dataDirectory,
        temporaryDirectory: () async =>
            Directory((await getTemporaryDirectory()).path),
      );

  static const playerGroupsPrefsKey = 'bhe.player_groups';
  static const defaultPlayerGroupPrefsKey = 'bhe.default_player_group';

  final MobileAnalysisEngine analysisEngine;
  final MobileExportEngine exportEngine;

  ProjectSnapshot project = ProjectSnapshot(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: '新项目',
    video: null,
  );
  List<ProjectSnapshot> recentProjects = const [];
  late final PlayerGroupStore _groupStore = PlayerGroupStore(
    onChanged: () {
      if (!_disposed) {
        _rosterSelection?.reconcile(
          playerGroups,
          hasPlayers: project.players.isNotEmpty,
        );
        notifyListeners();
      }
    },
    onFailure: (error, stack) {
      if (_disposed) {
        MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'player.groups',
        );
      } else {
        recordDiagnosticFailure(error, stack, operation: 'player.groups');
        playerGroupError = diagnosticError;
        notifyListeners();
      }
    },
  );
  List<PlayerGroup> get playerGroups => _groupStore.groups;
  set playerGroups(List<PlayerGroup> value) => _groupStore.groups = value;
  String? get defaultPlayerGroupName => _groupStore.defaultName;
  set defaultPlayerGroupName(String? value) => _groupStore.defaultName = value;
  Future<void> get groupsReady => _groupStore.ready;
  bool get groupsLoaded => _groupStore.loaded;
  bool get playerGroupDataInvalid => _groupStore.hasUnsafeData;
  DiagnosticErrorRecord? playerGroupError;
  RosterSelection? _rosterSelection;
  int get videoPreparationGeneration => _videoPreparationGeneration;

  RosterSelection get rosterSelection {
    final existing = _rosterSelection;
    if (existing != null) {
      existing.reconcile(playerGroups, hasPlayers: project.players.isNotEmpty);
      return existing;
    }
    final draft = RosterSelection();
    final matches = playerGroups.where(
      (group) => group.name == defaultPlayerGroupName,
    );
    if (project.players.isEmpty && matches.isNotEmpty) {
      final group = matches.first;
      draft.choose(group.name, group.players, automatic: true);
    }
    return _rosterSelection = draft;
  }

  /// Cover image per project id, taken from a shot frame after analysis.
  Map<String, String> coverPaths = const {};
  AnalysisStage stage = AnalysisStage.idle;
  double progress = 0;
  String progressMessage = '';
  int? processedFrames;
  int? totalFrames;
  Duration? eta;
  @override
  String? errorMessage;
  VideoSourceFailure? videoSourceFailure;
  int videoSourceRevision = 0;
  bool get videoMissing => videoSourceFailure == VideoSourceFailure.missing;
  bool get canRelinkVideo => videoSourceFailure?.canRelink ?? false;
  bool relinkingVideo = false;
  bool relinkCancelling = false;
  int _relinkSerial = 0;
  bool _disposed = false;

  void markVideoFailure(
    VideoSourceFailure failure, {
    DiagnosticErrorRecord? diagnostic,
  }) {
    if (_disposed) return;
    videoSourceFailure = failure;
    errorMessage = failure.message;
    diagnosticError =
        diagnostic ??
        MobileDiagnostics.instance.error(
          StateError(failure.message),
          null,
          operation: 'video.source',
        );
    notifyListeners();
  }

  void _recordVideoFailure(Object error, String? path, [StackTrace? stack]) {
    markVideoFailure(
      error is VideoSourceMismatch
          ? VideoSourceFailure.mismatch
          : path != null && !File(path).existsSync()
          ? VideoSourceFailure.missing
          : VideoSourceFailure.unplayable,
      diagnostic: MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'video.source',
      ),
    );
  }

  void cancelVideoPreparation() {
    if (!preparingVideo) return;
    _invalidateVideoPreparation();
    notifyListeners();
  }

  void cancelVideoRelink() {
    if (!relinkingVideo || relinkCancelling) return;
    _videoPreparationGeneration++;
    relinkCancelling = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _exportDrainTimer?.cancel();
    _uncertainExportWatch?.cancel();
    _videoPreparationGeneration++;
    super.dispose();
  }

  bool loading = true;
  bool preparingVideo = false;
  String preparingVideoMessage = '';
  bool analysing = false;
  String? exportHistoryWarning;
  String? _historyActiveMode;
  int _historyPlannedCount = 0;
  DateTime? _historyExportStartedAt;
  bool exporting = false;
  int exportBatchTotal = 0;
  List<LabelExportFile> exportBatchFiles = const [];
  bool _batchExport = false;
  bool _batchStopRequested = false;
  bool exportCancelled = false;
  int _exportRun = 0;
  bool _exportPreflight = false;
  Timer? _exportDrainTimer;
  Timer? _uncertainExportWatch;
  Future<void>? _uncertainExportDrain;
  DiagnosticErrorRecord? uncertainExportDiagnostic;
  String? uncertainExportStatus;
  bool checkingUncertainExport = false;
  bool get hasUncertainExport => _uncertainExportDrain != null;

  void _watchOldExport() {
    final drain = NativeMediaExportEngine.activeDrain;
    if (drain == null) return;
    _uncertainExportWatch?.cancel();
    final timer = Timer(exportDrainTimeout, () {
      if (!_disposed && identical(NativeMediaExportEngine.activeDrain, drain)) {
        _markExportUncertain(TimeoutException('上一次导出尚未结束'), StackTrace.current);
        notifyListeners();
      }
    });
    _uncertainExportWatch = timer;
    drain.then((_) {
      if (identical(_uncertainExportWatch, timer)) timer.cancel();
      if (!_disposed) notifyListeners();
    });
  }

  void _markExportUncertain(Object error, StackTrace stack) {
    final drain = NativeMediaExportEngine.activeDrain;
    if (drain == null || _disposed) return;
    _uncertainExportDrain = drain;
    uncertainExportStatus = null;
    uncertainExportDiagnostic = MobileDiagnostics.instance.error(
      error,
      stack,
      operation: 'export',
    );
    drain.then((_) {
      if (identical(_uncertainExportDrain, drain)) {
        _uncertainExportDrain = null;
        uncertainExportDiagnostic = null;
        uncertainExportStatus = null;
        if (!_disposed) notifyListeners();
      }
    });
  }

  Future<TaskStopStatus> checkUncertainExport({bool stopFirst = false}) async {
    final drain = _uncertainExportDrain;
    final engine = exportEngine;
    if (drain == null) return TaskStopStatus.stopped;
    if (_disposed ||
        engine is! NativeMediaExportEngine ||
        checkingUncertainExport) {
      return TaskStopStatus.unknown;
    }
    checkingUncertainExport = true;
    notifyListeners();
    try {
      final outcome = await engine.checkPreviousExport(stopFirst: stopFirst);
      if (identical(_uncertainExportDrain, drain)) {
        uncertainExportStatus = switch (outcome) {
          TaskStopStatus.stopped => null,
          TaskStopStatus.running => '上次任务仍在运行，请稍候或再次尝试停止。',
          TaskStopStatus.unknown => '无法确认上次任务是否停止。',
        };
      }
      return outcome;
    } on Object catch (error, stack) {
      if (identical(_uncertainExportDrain, drain)) {
        uncertainExportStatus = '无法确认上次任务是否停止。';
        uncertainExportDiagnostic = MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'export',
        );
      }
      return TaskStopStatus.unknown;
    } finally {
      checkingUncertainExport = false;
      if (!_disposed) notifyListeners();
    }
  }

  bool _mergeCommitted = false;
  bool exportAudioSkipped = false;
  int? exportMergedOverlapCount;
  List<String> exportedPaths = const [];
  final ProjectMutationQueue _mutations = ProjectMutationQueue();
  Future<void> get pendingProjectWrites => _mutations.drained;
  int get pendingProjectMutations => _mutations.pending;
  final ReviewHistory reviewHistory = ReviewHistory();
  String? undoFocusId;
  int undoRevision = 0;
  int reviewRevision = 0;
  String? reviewNotice;
  DiagnosticErrorRecord? reviewDiagnosticError;
  DateTime? reviewNoticeAt;

  void _setReviewNotice(String? notice) {
    if (notice == null) reviewDiagnosticError = null;
    reviewNotice = notice;
    reviewNoticeAt = notice == null ? null : DateTime.now();
    reviewRevision++;
  }

  bool get canUndoReview => reviewHistory.canUndo;

  int _projectSession = 0;
  int get projectSession => _projectSession;
  int _projectTransitions = 0;
  int _projectIntent = 0;
  bool get projectTransitioning => _projectTransitions != 0;

  int _newProjectIntent() => ++_projectIntent;
  bool _isProjectIntent(int intent) => !_disposed && intent == _projectIntent;

  Future<void> _withProjectTransition(
    int intent,
    Future<void> Function() action,
  ) async {
    if (!_isProjectIntent(intent)) return;
    _projectTransitions++;
    notifyListeners();
    try {
      await action();
    } finally {
      _projectTransitions--;
      if (!_disposed) notifyListeners();
    }
  }

  int playerMutationRevision = 0;
  String? lastPlayerOldName;
  String? lastPlayerNewName;

  Future<ReviewActionResult> _changeReviewResult({
    required ReviewChange kind,
    required String focusId,
    required String notice,
    required List<Candidate> Function(List<Candidate>) change,
  }) {
    if (_projectTransitions != 0) {
      return Future.value(ReviewActionResult.rejected);
    }
    final projectId = project.id;
    final session = _projectSession;
    return _mutations.run(() async {
      if (_disposed || project.id != projectId || _projectSession != session) {
        return ReviewActionResult.rejected;
      }
      final original = project.candidates;
      final next = change(original);
      final previous = <String, ReviewFields>{};
      for (var i = 0; i < original.length; i++) {
        final old = original[i], updated = next[i];
        final different = switch (kind) {
          ReviewChange.selection =>
            old.selection != updated.selection ||
                old.reviewed != updated.reviewed,
          ReviewChange.player => old.player != updated.player,
          ReviewChange.note => old.note != updated.note,
          ReviewChange.range =>
            old.startMs != updated.startMs ||
                old.endMs != updated.endMs ||
                old.rangeEdited != updated.rangeEdited,
        };
        if (different) previous[old.id] = ReviewFields.capture(kind, old);
      }
      if (previous.isEmpty) {
        return original.any((item) => item.id == focusId)
            ? ReviewActionResult.unchanged
            : ReviewActionResult.rejected;
      }
      project = project.copyWith(candidates: next);
      notifyListeners();
      try {
        await _writeProject(project);
        if (_disposed ||
            project.id != projectId ||
            _projectSession != session) {
          return ReviewActionResult.rejected;
        }
        reviewHistory.add(ReviewEntry(kind, previous, focusId));
        _setReviewNotice(notice);
        notifyListeners();
        return ReviewActionResult.changed;
      } catch (error, stack) {
        if (!_disposed &&
            project.id == projectId &&
            _projectSession == session) {
          project = project.copyWith(
            candidates: [
              for (final c in project.candidates)
                if (previous[c.id] case final old?)
                  restoreReviewFields(c, old, kind)
                else
                  c,
            ],
          );
          recordDiagnosticFailure(error, stack, operation: 'project');
          reviewDiagnosticError = diagnosticError;
          _setReviewNotice('保存失败，请重试');
          notifyListeners();
        } else {
          MobileDiagnostics.instance.error(error, stack, operation: 'project');
        }
        return ReviewActionResult.rejected;
      }
    });
  }

  Future<bool> _changeReview({
    required ReviewChange kind,
    required String focusId,
    required String notice,
    required List<Candidate> Function(List<Candidate>) change,
  }) async =>
      await _changeReviewResult(
        kind: kind,
        focusId: focusId,
        notice: notice,
        change: change,
      ) ==
      ReviewActionResult.changed;

  Future<void> undoReview() {
    if (_projectTransitions != 0) return Future.value();
    final projectId = project.id;
    final session = _projectSession;
    return _mutations.run(() async {
      if (_disposed || project.id != projectId || _projectSession != session) {
        return;
      }
      final entry = reviewHistory.pop();
      if (entry == null) return;
      final previous = <String, ReviewFields>{
        for (final candidate in project.candidates)
          if (entry.before.containsKey(candidate.id))
            candidate.id: ReviewFields.capture(entry.kind, candidate),
      };
      project = project.copyWith(
        candidates: [
          for (final candidate in project.candidates)
            if (entry.before[candidate.id] case final old?)
              restoreReviewFields(candidate, old, entry.kind)
            else
              candidate,
        ],
      );
      notifyListeners();
      try {
        await _writeProject(project);
        if (!_disposed &&
            project.id == projectId &&
            _projectSession == session &&
            reviewHistory.complete(entry)) {
          undoFocusId = entry.focusId;
          undoRevision++;
          _setReviewNotice('已撤销');
          notifyListeners();
        }
      } catch (error, stack) {
        if (!_disposed &&
            project.id == projectId &&
            _projectSession == session &&
            reviewHistory.restore(entry)) {
          project = project.copyWith(
            candidates: [
              for (final c in project.candidates)
                if (previous[c.id] case final old?)
                  restoreReviewFields(c, old, entry.kind)
                else
                  c,
            ],
          );
          recordDiagnosticFailure(error, stack, operation: 'project');
          reviewDiagnosticError = diagnosticError;
          _setReviewNotice('保存失败，请重试');
          notifyListeners();
        } else {
          MobileDiagnostics.instance.error(error, stack, operation: 'project');
        }
      }
    });
  }

  int _analysisGeneration = 0;
  int _analysisCancelIntent = 0;
  Future<void>? _analysisLaunchBarrier;
  Completer<void>? _analysisNativeWait;
  Future<void>? _analysisCancelPending;
  PreparedNativeAnalysis? _waitingNativeRun;
  PreparedNativeAnalysis? _uncertainNativeRun;
  final Expando<bool> _confirmedStoppedAnalysisRuns = Expando<bool>();
  DiagnosticErrorRecord? uncertainAnalysisDiagnostic;
  bool checkingUncertainAnalysis = false;
  String? uncertainAnalysisStatus;
  bool get hasUncertainAnalysis => _uncertainNativeRun != null;

  void _markNativeUncertain(
    PreparedNativeAnalysis run, {
    bool cancellationAcknowledged = false,
    DiagnosticErrorRecord? diagnostic,
  }) {
    if (_confirmedStoppedAnalysisRuns[run] == true) return;
    if (identical(_uncertainNativeRun, run)) {
      uncertainAnalysisDiagnostic ??= diagnostic;
      return;
    }
    _uncertainNativeRun = run;
    uncertainAnalysisStatus = null;
    uncertainAnalysisDiagnostic =
        diagnostic ??
        (cancellationAcknowledged
            ? null
            : MobileDiagnostics.instance.error(
                TimeoutException('上次分析尚未确认停止'),
                StackTrace.current,
                operation: 'analysis',
              ));
    run.settled.then((_) async {
      // The result can precede Android worker cleanup, so verify native state.
      var attempt = 0;
      while (!_disposed && identical(_uncertainNativeRun, run)) {
        if (await checkUncertainAnalysis() == TaskStopStatus.stopped) return;
        final delay = attempt++ < 6
            ? const Duration(milliseconds: 500)
            : const Duration(seconds: 5);
        await Future<void>.delayed(delay);
      }
    });
  }

  Future<TaskStopStatus> checkUncertainAnalysis({
    bool stopFirst = false,
  }) async {
    final run = _uncertainNativeRun;
    final engine = analysisEngine;
    if (run == null) return TaskStopStatus.stopped;
    if (_disposed) return TaskStopStatus.unknown;
    if (engine is! NativeAnalysisEngine || checkingUncertainAnalysis) {
      return TaskStopStatus.unknown;
    }
    checkingUncertainAnalysis = true;
    if (!_disposed) notifyListeners();
    try {
      if (stopFirst) await engine.requestNativeStop();
      final outcome = await engine.nativeAnalysisStatus();
      if (outcome == TaskStopStatus.stopped &&
          identical(_uncertainNativeRun, run)) {
        _confirmedStoppedAnalysisRuns[run] = true;
        _uncertainNativeRun = null;
        uncertainAnalysisDiagnostic = null;
        uncertainAnalysisStatus = null;
        return TaskStopStatus.stopped;
      }
      if (!identical(_uncertainNativeRun, run)) return TaskStopStatus.unknown;
      uncertainAnalysisStatus = outcome == TaskStopStatus.running
          ? '上次任务仍在运行，请稍候或再次尝试停止。'
          : '无法确认上次任务是否停止。';
      return outcome;
    } on Object catch (error, stack) {
      final diagnostic = MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'analysis',
      );
      if (identical(_uncertainNativeRun, run)) {
        uncertainAnalysisStatus = '无法确认上次任务是否停止。';
        uncertainAnalysisDiagnostic ??= diagnostic;
      }
      return TaskStopStatus.unknown;
    } finally {
      checkingUncertainAnalysis = false;
      if (!_disposed) notifyListeners();
    }
  }

  int _videoPreparationGeneration = 0;
  DateTime? analysisStartedAt;

  String? _heavyTaskBlockReason({required bool startingAnalysis}) {
    if (hasUncertainAnalysis || hasUncertainExport) {
      return '上次任务尚未确认结束，请先确认停止。';
    }
    if (analysing) return '正在分析，请等待分析结束。';
    if (exporting ||
        (startingAnalysis && NativeMediaExportEngine.activeDrain != null)) {
      return '正在导出，请等待导出结束。';
    }
    return null;
  }

  String? get analysisStartBlockReason =>
      _heavyTaskBlockReason(startingAnalysis: true);
  String? get exportStartBlockReason =>
      _heavyTaskBlockReason(startingAnalysis: false);

  bool get canStartAnalysis =>
      hasVideo &&
      analysisStartBlockReason == null &&
      !preparingVideo &&
      !relinkingVideo &&
      videoSourceFailure == null;
  bool get hasVideo => project.video != null;
  bool get sourceVideoExists =>
      project.video != null && File(project.video!.path).existsSync();
  Duration get analysisElapsed => analysisStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(analysisStartedAt!);

  Future<Directory> _dataDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/BHE Mobile');
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> _projectPath(
    String id, {
    String area = '',
    String suffix = '',
  }) async => projectStoragePath(
    await _dataDirectory(),
    id,
    area: area,
    suffix: suffix,
  );

  Future<VideoInfo> _inspectVideo(File file, {VideoInfo? expected}) async {
    if (!await file.exists()) {
      throw FileSystemException('Missing source video', file.path);
    }
    final VideoInfo actual;
    final probe = videoProbe;
    if (probe != null) {
      actual = await probe(file);
    } else {
      final controller = VideoPlayerController.file(file);
      try {
        await controller.initialize();
        final value = controller.value;
        actual = VideoInfo(
          path: file.path,
          name: file.uri.pathSegments.last,
          sizeBytes: await file.length(),
          durationMs: value.duration.inMilliseconds,
          width: value.size.width.round(),
          height: value.size.height.round(),
          sha256: await _sha256(file),
        );
      } finally {
        await controller.dispose();
      }
    }
    if (expected != null &&
        (expected.width != actual.width ||
            expected.height != actual.height ||
            (expected.durationMs - actual.durationMs).abs() > 1500 ||
            (expected.sha256 != null && expected.sha256 != actual.sha256))) {
      throw const VideoSourceMismatch();
    }
    return actual;
  }

  Future<VideoInfo> _storeVideo(
    String path,
    ProjectSnapshot snapshot,
    int generation, {
    bool fromPicker = false,
    bool replace = false,
    String? name,
    int? projectIntent,
  }) async {
    bool current() =>
        _isCurrentVideoPreparation(generation, snapshot.id, projectIntent);
    return _videoStore.save(
      sourcePath: path,
      projectId: snapshot.id,
      previousPath: snapshot.video?.path,
      fromPicker: fromPicker,
      isCurrent: current,
      validate: (file) =>
          _inspectVideo(file, expected: replace ? null : snapshot.video),
      commit: (action) => _mutations.run(action),
      persist: (localPath, info) async {
        if (!current()) throw const VideoSourceCancelled();
        final before = project;
        final video = VideoInfo(
          path: localPath,
          name: name ?? before.video?.name ?? info.name,
          sizeBytes: info.sizeBytes,
          durationMs: info.durationMs,
          width: info.width,
          height: info.height,
          sha256: info.sha256,
        );
        final next = before.copyWith(
          video: video,
          name: replace
              ? video.name.replaceFirst(RegExp(r'\.[^.]+$'), '')
              : before.name,
          clearHoopRoi: replace,
          clearRimRoi: replace,
          clearNetRoi: replace,
          candidates: replace ? const [] : before.candidates,
          clearLastAnalysis: replace,
        );
        await _writeProject(next);
        if (!current()) {
          await _writeProject(project);
          throw const VideoSourceCancelled();
        }
        project = next;
        reviewHistory.clear();
        _setReviewNotice(null);
        videoSourceRevision++;
      },
    );
  }

  Future<File> _projectFile(String id) async {
    final file = File(
      await _projectPath(id, area: 'projects', suffix: '.json'),
    );
    await file.parent.create(recursive: true);
    return file;
  }

  Future<File> _coverFile(String id) async {
    final file = File(
      await _projectPath(id, area: 'projects', suffix: '_cover.jpg'),
    );
    await file.parent.create(recursive: true);
    return file;
  }

  Future<void> _loadCovers() async {
    final covers = <String, String>{};
    for (final item in recentProjects) {
      final file = await _coverFile(item.id);
      if (await file.exists()) covers[item.id] = file.path;
    }
    coverPaths = covers;
    notifyListeners();
    for (final item in recentProjects) {
      if (!covers.containsKey(item.id)) await _updateCover(item);
    }
  }

  /// Uses the first kept shot that passed the rim check, else the first kept
  /// shot, else the first candidate.
  Future<void> _updateCover(ProjectSnapshot snapshot) async {
    final video = snapshot.video;
    if (video == null || snapshot.candidates.isEmpty) return;
    final candidates = [...snapshot.candidates]
      ..sort((a, b) => a.eventMs.compareTo(b.eventMs));
    final kept = candidates
        .where((item) => item.selection == CandidateSelection.included)
        .toList();
    final cover = kept.firstWhere(
      (item) => item.rimCheckStatus == 'made',
      orElse: () => kept.isEmpty ? candidates.first : kept.first,
    );
    final file = await _coverFile(snapshot.id);
    final saved = await analysisEngine.extractCover(
      videoPath: video.path,
      timeMs: cover.eventMs,
      outputPath: file.path,
    );
    if (!saved) return;
    await FileImage(file).evict();
    coverPaths = {...coverPaths, snapshot.id: file.path};
    notifyListeners();
  }

  Future<String> _sha256(File file) async {
    const sampleSize = 1024 * 1024;
    final handle = await file.open();
    try {
      final length = await handle.length();
      final first = await handle.read(
        length < sampleSize ? length : sampleSize,
      );
      if (length > sampleSize) await handle.setPosition(length - sampleSize);
      final last = length > sampleSize
          ? await handle.read(sampleSize)
          : const <int>[];
      return sha256.convert([
        ...first,
        ...last,
        ...utf8.encode('$length'),
      ]).toString();
    } finally {
      await handle.close();
    }
  }

  Future<bool> _matchesProjectVideo({bool Function()? applyResult}) async {
    final expected = project.video;
    if (expected == null) return false;
    try {
      await _inspectVideo(File(expected.path), expected: expected);
      if (project.video == expected && (applyResult?.call() ?? true)) {
        videoSourceFailure = null;
        diagnosticError = null;
        errorMessage = null;
      }
      return true;
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'project');
      if (project.video == expected && (applyResult?.call() ?? true)) {
        _recordVideoFailure(error, expected.path, stack);
      }
      return false;
    }
  }

  Future<void> _validateImportedVideoIfPresent({int? projectIntent}) async {
    final snapshot = project;
    final video = snapshot.video;
    if (video == null) {
      errorMessage = '项目已打开，请重新选择原视频后继续。';
      return;
    }
    final generation = _videoPreparationGeneration;
    try {
      final source = await File(video.path).exists()
          ? video.path
          : await _videoStore.existingVideo(snapshot.id);
      if (source == null) {
        throw FileSystemException('Missing source video', video.path);
      }
      // Existing records may share a legacy cache path. Migration is a copy;
      // only a fresh picker selection grants permission to move its cache.
      await _storeVideo(
        source,
        snapshot,
        generation,
        projectIntent: projectIntent,
      );
      if (_isCurrentVideoPreparation(generation, snapshot.id, projectIntent)) {
        videoSourceFailure = null;
        diagnosticError = null;
        errorMessage = null;
      }
    } on VideoSourceCancelled {
      return;
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'project');
      if (_isCurrentVideoPreparation(generation, snapshot.id, projectIntent)) {
        _recordVideoFailure(error, video.path, stack);
      }
    }
  }

  void _notifyProjectManagement() => notifyListeners();

  Future<ProjectCatalog> listSavedProjects() => _mutations.run(() async {
    try {
      return await readProjectCatalog(await _dataDirectory());
    } on Object catch (error, stack) {
      recordDiagnosticFailure(error, stack, operation: 'project.catalog');
      Error.throwWithStackTrace(error, stack);
    }
  });

  Future<void> loadSavedProject() async {
    try {
      await _mutations.run(() async {
        final directory = await _dataDirectory();
        final indexFile = File('${directory.path}/project_index.json');
        final legacyFile = File('${directory.path}/project.bhe.json');
        if (await indexFile.exists()) {
          final ids =
              (jsonDecode(await indexFile.readAsString()) as List?)
                  ?.whereType<String>()
                  .where(isSafeProjectId)
                  .toSet()
                  .toList() ??
              const <String>[];
          final loadedProjects = <ProjectSnapshot>[];
          for (final id in ids) {
            final file = await _projectFile(id);
            if (!await file.exists()) continue;
            try {
              loadedProjects.add(
                const ProjectPackageCodec().decode(await file.readAsString(), includeLocalHistory: true),
              );
            } on Object catch (error, stack) {
              MobileDiagnostics.instance.error(
                error,
                stack,
                operation: 'project',
              );
              developer.log(
                'skipping invalid project $id: $error',
                name: 'BHE-Project',
                error: error,
                stackTrace: stack,
              );
            }
          }
          recentProjects = loadedProjects;
          if (recentProjects.isNotEmpty) project = recentProjects.first;
          await _persistProjects();
          unawaited(_loadCovers());
        } else if (await legacyFile.exists()) {
          project = const ProjectPackageCodec().decode(
            await legacyFile.readAsString(),
          );
          recentProjects = [project];
          await _persistProjects();
        }
      });
      if (project.video != null) await _validateImportedVideoIfPresent();
      if (project.lastAnalysisStatus == 'running') {
        unawaited(_recoverRunningAnalysis());
      }
    } on Object catch (error, stack) {
      recordDiagnosticFailure(error, stack, operation: 'project.load');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _recoverRunningAnalysis() async {
    final id = project.id, session = _projectSession;
    bool current() =>
        !_disposed && project.id == id && _projectSession == session;
    var receivedState = false;
    try {
      await for (final update in analysisEngine.recoverAnalysis()) {
        if (!current()) return;
        receivedState = true;
        if (stage != update.stage) {
          MobileDiagnostics.instance.event('analysis.${update.stage.name}');
        }
        stage = update.stage;
        progress = update.progress.clamp(0, 1);
        progressMessage = update.message;
        processedFrames = update.processedFrames;
        totalFrames = update.totalFrames;
        analysing =
            update.stage != AnalysisStage.completed &&
            update.stage != AnalysisStage.cancelled &&
            update.stage != AnalysisStage.failed;
        analysisStartedAt ??= DateTime.now();
        final completed = update.stage == AnalysisStage.completed;
        final stopped =
            update.stage == AnalysisStage.cancelled ||
            update.stage == AnalysisStage.failed;
        if (update.stage == AnalysisStage.failed) {
          recordDiagnosticFailure(
            MobileAnalysisException(update.message),
            null,
            operation: 'analysis.recover',
          );
          progressMessage = errorMessage ?? '';
        }
        final status = completed
            ? 'completed'
            : update.stage == AnalysisStage.cancelled
            ? 'cancelled'
            : stopped
            ? 'failed'
            : 'running';
        final message = completed
            ? '分析完成'
            : stopped
            ? errorMessage ?? update.message
            : update.message;
        final percent = completed ? 100 : (progress * 100).round();
        final completedAt = completed ? DateTime.now() : null;
        final fields = <String>{
          'status',
          'message',
          if (!stopped) 'progress',
          if (completed) ...{'candidates', 'at'},
        };
        if (!await _submitProjectChange(
          (value) => value.copyWith(
            candidates: completed
                ? mergeAnalysisCandidates(value.candidates, update.candidates)
                : null,
            lastAnalysisStatus: status,
            lastAnalysisMessage: message,
            lastAnalysisProgressPercent: stopped ? null : percent,
            lastAnalysisAt: completedAt,
          ),
          inverse: (before) => _restoreOperationFields(before, fields),
          operation: 'analysis.recover',
        )) {
          return;
        }
        if (!current()) return;
        if (completed || stopped) {
          analysing = false;
          analysisStartedAt = null;
          if (completed) unawaited(_updateCover(project));
        }
        notifyListeners();
      }
      if (current() &&
          !receivedState &&
          project.lastAnalysisStatus == 'running') {
        await _submitProjectChange(
          (value) => value.copyWith(
            lastAnalysisStatus: 'interrupted',
            lastAnalysisMessage: '未找到仍在运行的原生分析任务，可重新分析。',
          ),
          inverse: (before) =>
              _restoreOperationFields(before, {'status', 'message'}),
          operation: 'analysis.recover',
        );
      }
    } on Object catch (error, stack) {
      if (!current()) {
        MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'analysis.recover',
        );
        return;
      }
      recordDiagnosticFailure(error, stack, operation: 'analysis.recover');
      analysing = false;
      analysisStartedAt = null;
      await _submitProjectChange(
        (value) => value.copyWith(
          lastAnalysisStatus: 'interrupted',
          lastAnalysisMessage: '出错了：视频分析未完成，请重试。',
        ),
        inverse: (before) =>
            _restoreOperationFields(before, {'status', 'message'}),
        operation: 'analysis.recover',
      );
      notifyListeners();
    }
  }

  Future<void> _writeProject(
    ProjectSnapshot snapshot, {
    bool Function()? commitGuard,
  }) async {
    final file = await _projectFile(snapshot.id);
    final next = [
      snapshot,
      ...recentProjects.where((item) => item.id != snapshot.id),
    ].take(12).toList();
    final index = File('${(await _dataDirectory()).path}/project_index.json');
    final indexContent = jsonEncode(next.map((item) => item.id).toList());
    // Consecutive edits in the same project keep the index unchanged. Merge
    // those redundant index writes while still committing each undo step.
    final indexUnchanged =
        await index.exists() && await index.readAsString() == indexContent;
    await commitProjectFiles(
      {
        file: const ProjectPackageCodec().encode(snapshot, includeLocalHistory: true),
        if (!indexUnchanged) index: indexContent,
      },
      beforeInstall: commitGuard,
      afterInstall: commitGuard,
    );
    recentProjects = next;
  }

  Future<bool> _submitProjectChange(
    ProjectSnapshot Function(ProjectSnapshot) change, {
    required ProjectSnapshot Function(ProjectSnapshot) Function(ProjectSnapshot)
    inverse,
    String operation = 'project',
    void Function()? onSuccess,
    bool allowDuringTransition = false,
    bool Function()? guard,
    bool recheckAfterWrite = false,
  }) {
    if (_projectTransitions != 0 && !allowDuringTransition) {
      return Future.value(false);
    }
    final id = project.id, session = _projectSession;
    return _mutations.run(() async {
      if (_disposed ||
          project.id != id ||
          _projectSession != session ||
          (guard != null && !guard())) {
        return false;
      }
      final next = change(project);
      if (identical(next, project)) return true;
      final rollback = inverse(project);
      project = next;
      notifyListeners();
      var written = false;
      try {
        await _writeProject(
          project,
          commitGuard: recheckAfterWrite ? guard : null,
        );
        written = true;
        if (_disposed || project.id != id || _projectSession != session) {
          return false;
        }
        if (recheckAfterWrite && guard != null && !guard()) {
          project = rollback(project);
          await _writeProject(project);
          notifyListeners();
          return false;
        }
        onSuccess?.call();
        notifyListeners();
        return true;
      } on Object catch (error, stack) {
        if (!_disposed && project.id == id && _projectSession == session) {
          project = rollback(project);
          if (error is ProjectCommitSuperseded) {
            notifyListeners();
            return false;
          }
          if (written) {
            try {
              await _writeProject(project);
            } on Object catch (restoreError, restoreStack) {
              MobileDiagnostics.instance.error(
                restoreError,
                restoreStack,
                operation: '$operation.rollback',
              );
            }
          }
          recordDiagnosticFailure(error, stack, operation: operation);
          notifyListeners();
        } else {
          MobileDiagnostics.instance.error(error, stack, operation: operation);
        }
        return false;
      }
    });
  }

  ProjectSnapshot Function(ProjectSnapshot) _restoreOperationFields(
    ProjectSnapshot before,
    Set<String> fields,
  ) {
    final old = <String, Object?>{
      if (fields.contains('candidates')) 'candidates': before.candidates,
      if (fields.contains('duration'))
        'duration': before.lastAnalysisDurationMs,
      if (fields.contains('at')) 'at': before.lastAnalysisAt,
      if (fields.contains('status')) 'status': before.lastAnalysisStatus,
      if (fields.contains('progress'))
        'progress': before.lastAnalysisProgressPercent,
      if (fields.contains('message')) 'message': before.lastAnalysisMessage,
      if (fields.contains('export')) 'export': before.lastExportDurationMs,
    };
    return (current) => ProjectSnapshot(
      id: current.id,
      name: current.name,
      video: current.video,
      hoopRoi: current.hoopRoi,
      rimRoi: current.rimRoi,
      netRoi: current.netRoi,
      settings: current.settings,
      candidates: old.containsKey('candidates')
          ? old['candidates'] as List<Candidate>
          : current.candidates,
      players: current.players,
      exportHistory: current.exportHistory,
      lastAnalysisDurationMs: old.containsKey('duration')
          ? old['duration'] as int?
          : current.lastAnalysisDurationMs,
      lastAnalysisAt: old.containsKey('at')
          ? old['at'] as DateTime?
          : current.lastAnalysisAt,
      lastAnalysisStatus: old.containsKey('status')
          ? old['status'] as String?
          : current.lastAnalysisStatus,
      lastAnalysisProgressPercent: old.containsKey('progress')
          ? old['progress'] as int?
          : current.lastAnalysisProgressPercent,
      lastAnalysisMessage: old.containsKey('message')
          ? old['message'] as String?
          : current.lastAnalysisMessage,
      lastExportDurationMs: old.containsKey('export')
          ? old['export'] as int?
          : current.lastExportDurationMs,
    );
  }

  ProjectSnapshot Function(ProjectSnapshot) _restoreRois(
    ProjectSnapshot before, {
    bool rim = false,
  }) {
    final hoop = before.hoopRoi,
        net = before.netRoi,
        oldRim = rim ? before.rimRoi : null;
    return (current) => current.copyWith(
      hoopRoi: hoop,
      clearHoopRoi: hoop == null,
      netRoi: net,
      clearNetRoi: net == null,
      rimRoi: oldRim,
      clearRimRoi: rim && oldRim == null,
    );
  }

  ProjectSnapshot Function(ProjectSnapshot) _restorePlayers(
    ProjectSnapshot before,
  ) {
    final oldPlayers = before.players;
    return (current) => current.copyWith(players: oldPlayers);
  }

  Future<bool> renameProject(String name) {
    if (_projectTransitions != 0) return Future.value(false);
    final value = name.trim();
    if (value.isEmpty || value.characters.length > 40) {
      return Future.value(false);
    }
    final id = project.id, session = _projectSession;
    return _mutations.run(() async {
      if (_disposed || project.id != id || _projectSession != session) {
        return false;
      }
      final oldName = project.name;
      if (value == oldName) return true;
      final wasRecent = recentProjects.any((item) => item.id == id);
      final evicted =
          !wasRecent && project.video != null && recentProjects.length >= 12
          ? recentProjects.last
          : null;
      project = project.copyWith(name: value);
      recentProjects = [
        for (final item in recentProjects)
          item.id == id ? item.copyWith(name: value) : item,
      ];
      if (!wasRecent && project.video != null) {
        recentProjects = [project, ...recentProjects].take(12).toList();
      }
      notifyListeners();
      try {
        await _writeProject(project);
        return true;
      } catch (error, stack) {
        if (!_disposed && project.id == id && _projectSession == session) {
          project = project.copyWith(name: oldName);
          recentProjects = [
            for (final item in recentProjects)
              if (item.id != id || wasRecent)
                item.id == id ? item.copyWith(name: oldName) : item,
          ];
          if (evicted != null &&
              recentProjects.every((item) => item.id != evicted.id)) {
            recentProjects = [...recentProjects, evicted];
          }
          recordDiagnosticFailure(error, stack, operation: 'project');
          notifyListeners();
        } else {
          MobileDiagnostics.instance.error(error, stack, operation: 'project');
        }
        return false;
      }
    });
  }

  Future<void> _persistProjects() async {
    final directory = await _dataDirectory();
    final indexFile = File('${directory.path}/project_index.json');
    await indexFile.writeAsString(
      jsonEncode(recentProjects.map((item) => item.id).toList()),
    );
  }

  Future<void> openProject(String id, {bool requireIdle = false}) {
    if (requireIdle && projectManagementBlockReason != null) return Future.value();
    final intent = _newProjectIntent();
    return _withProjectTransition(intent, () async {
      if (analysing) await cancelAnalysis();
      if (!_isProjectIntent(intent)) return;
      _invalidateVideoPreparation();
      final opened = await _mutations.run(() async {
        if (!_isProjectIntent(intent) || (requireIdle && projectManagementBlockReason != null)) return false;
        final file = await _projectFile(id);
        if (!await file.exists() || !_isProjectIntent(intent)) return false;
        final loaded = const ProjectPackageCodec().decode(
          await file.readAsString(),
          includeLocalHistory: true,
        );
        if (!_isProjectIntent(intent) || (requireIdle && projectManagementBlockReason != null)) return false;
        project = loaded;
        _resetTransientState();
        diagnosticError = null;
        errorMessage = null;
        exportedPaths = const [];
        exportAudioSkipped = false;
        exportMergedOverlapCount = null;
        recentProjects = [
          project,
          ...recentProjects.where((item) => item.id != project.id),
        ].take(12).toList();
        await _persistProjects();
        notifyListeners();
        return true;
      });
      if (!opened || !_isProjectIntent(intent)) return;
      await _validateImportedVideoIfPresent(projectIntent: intent);
      if (!_isProjectIntent(intent)) return;
      MobileDiagnostics.instance.event(
        'project.open',
        available: sourceVideoExists,
      );
      notifyListeners();
    }).catchError((Object error, StackTrace stack) {
      if (_isProjectIntent(intent)) {
        recordDiagnosticFailure(error, stack, operation: 'project.open');
        notifyListeners();
      } else {
        MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'project.open',
        );
      }
    });
  }

  Future<void> createNewProject() => _createNewProject(_newProjectIntent());

  Future<void> _createNewProject(int intent, {bool requireIdle = false}) =>
      _withProjectTransition(intent, () async {
        if (requireIdle && projectManagementBlockReason != null) return;
        if (analysing) await cancelAnalysis();
        if (!_isProjectIntent(intent)) return;
        _invalidateVideoPreparation();
        await _mutations.run(() async {
          if (!_isProjectIntent(intent) || (requireIdle && projectManagementBlockReason != null)) return;
          project = _newProject();
          _resetTransientState();
          notifyListeners();
        });
      });

  ProjectSnapshot _newProject() =>
      ProjectSnapshot(id: _newProjectId(), name: '新项目', video: null);

  String _newProjectId() {
    var id = DateTime.now().microsecondsSinceEpoch.toString();
    final usedIds = {project.id, ...recentProjects.map((item) => item.id)};
    var suffix = 0;
    while (usedIds.contains(id)) {
      id = '${DateTime.now().microsecondsSinceEpoch}_${suffix++}';
    }
    return id;
  }

  Future<void> createNewProjectAndPickVideo({bool requireIdle = false}) async {
    if (requireIdle && projectManagementBlockReason != null) return;
    final intent = _newProjectIntent();
    final id = project.id, session = _projectSession;
    try {
      final picked = await _pickVideo();
      if (picked == null ||
          !_isProjectIntent(intent) ||
          project.id != id ||
          _projectSession != session) {
        return;
      }
      await _createNewProject(intent, requireIdle: requireIdle);
      if (!_isProjectIntent(intent) || (requireIdle && project.id == id)) return;
      await _prepareVideo(
        picked.path,
        name: picked.name,
        projectIntent: intent,
      );
    } on Object catch (error, stack) {
      if (!_isProjectIntent(intent)) {
        MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'project.new',
        );
        return;
      }
      recordDiagnosticFailure(error, stack, operation: 'project.new');
      notifyListeners();
    }
  }

  Future<void> pickVideo() async {
    final intent = _projectIntent, id = project.id, session = _projectSession;
    if (analysing) await cancelAnalysis();
    if (!_isProjectIntent(intent) ||
        project.id != id ||
        _projectSession != session) {
      return;
    }
    _invalidateVideoPreparation();
    final picked = await _pickVideo();
    if (picked == null ||
        !_isProjectIntent(intent) ||
        project.id != id ||
        _projectSession != session) {
      return;
    }
    await _prepareVideo(picked.path, name: picked.name, projectIntent: intent);
  }

  Future<({String path, String name})?> _pickVideo() async {
    final result = await _pickFiles(type: FileType.video, kind: 'video');
    final file = result?.files.single;
    final path = file?.path;
    if (path == null) return null;
    final pathName = path.split(Platform.pathSeparator).last;
    return (
      path: path,
      name: file?.name.trim().isNotEmpty == true ? file!.name : pathName,
    );
  }

  Future<void> _prepareVideo(
    String path, {
    String? name,
    int? projectIntent,
  }) async {
    final projectId = project.id;
    final preparationGeneration = ++_videoPreparationGeneration;
    videoSourceFailure = null;
    preparingVideo = true;
    preparingVideoMessage = '正在读取视频信息';
    diagnosticError = null;
    errorMessage = null;
    notifyListeners();
    try {
      preparingVideoMessage = '正在保存视频到本机';
      notifyListeners();
      await _storeVideo(
        path,
        project,
        preparationGeneration,
        fromPicker: true,
        replace: true,
        name: name,
        projectIntent: projectIntent,
      );
      if (!_isCurrentVideoPreparation(
        preparationGeneration,
        projectId,
        projectIntent,
      )) {
        return;
      }
      diagnosticError = null;
      errorMessage = null;
      preparingVideoMessage = '正在识别篮筐区域';
      notifyListeners();
      try {
        final suggestion = await analysisEngine.suggestRoi(
          video: project.video!,
          startMs: project.settings.startMs,
          modelSize: project.settings.modelInputSize,
        );
        if (!_isCurrentVideoPreparation(
          preparationGeneration,
          projectId,
          projectIntent,
        )) {
          return;
        }
        final rawRoi = suggestion?['roi'];
        if (rawRoi is Map) {
          final analysisRoi = Roi.fromJson(
            rawRoi.map((key, value) => MapEntry(key.toString(), value)),
          );
          final rawNet = suggestion?['net_roi'];
          final rawRim = suggestion?['rim_roi'];
          final rimRoi = rawRim is Map
              ? Roi.fromJson(
                  rawRim.map((key, value) => MapEntry(key.toString(), value)),
                )
              : null;
          final netRoi = rawNet is Map
              ? Roi.fromJson(
                  rawNet.map((key, value) => MapEntry(key.toString(), value)),
                )
              : rimRoi != null
              ? netRoiFromRim(analysisRoi, rimRoi)
              : Roi(
                  left: analysisRoi.left,
                  top: (analysisRoi.top + .06).clamp(0, 1),
                  right: analysisRoi.right,
                  bottom: (analysisRoi.bottom + .18).clamp(0, 1),
                );
          await _submitProjectChange(
            (current) => current.copyWith(
              hoopRoi: analysisRoi,
              rimRoi: rimRoi,
              netRoi: netRoi,
            ),
            inverse: (before) => _restoreRois(before, rim: true),
          );
        }
      } on Object catch (error, stack) {
        MobileDiagnostics.instance.error(error, stack, operation: 'project');
        developer.log(
          'automatic ROI suggestion failed: $error',
          name: 'BHE-Project',
          error: error,
          stackTrace: stack,
        );
      }
    } on VideoSourceCancelled {
      return;
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'project');
      developer.log(
        'video preparation failed: $error',
        name: 'BHE-Project',
        error: error,
        stackTrace: stack,
      );
      if (_isCurrentVideoPreparation(
        preparationGeneration,
        projectId,
        projectIntent,
      )) {
        _recordVideoFailure(error, path, stack);
      }
    } finally {
      if (preparationGeneration == _videoPreparationGeneration) {
        preparingVideo = false;
        preparingVideoMessage = '';
        notifyListeners();
      }
    }
  }

  bool _isCurrentVideoPreparation(
    int generation,
    String projectId, [
    int? intent,
  ]) =>
      !_disposed &&
      generation == _videoPreparationGeneration &&
      project.id == projectId &&
      (intent == null || _isProjectIntent(intent));

  void _invalidateVideoPreparation() {
    _videoPreparationGeneration++;
    preparingVideo = false;
    preparingVideoMessage = '';
    _relinkSerial++;
    relinkingVideo = false;
    relinkCancelling = false;
  }

  void _resetTransientState() {
    _exportDrainTimer?.cancel();
    if (exporting && !_exportPreflight) _watchOldExport();
    if (exporting && !_exportPreflight && !_mergeCommitted) {
      unawaited(
        exportEngine.cancel().catchError((Object error, StackTrace stack) {
          MobileDiagnostics.instance.error(
            error,
            stack,
            operation: 'export.cancel',
          );
        }),
      );
    }
    final waiting = _analysisNativeWait;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    _analysisNativeWait = null;
    _analysisLaunchBarrier = null;
    _exportRun++;
    _exportPreflight = false;
    _mergeCommitted = false;
    _projectSession++;
    _rosterSelection = null;
    _analysisGeneration++;
    reviewHistory.clear();
    reviewDiagnosticError = null;
    _setReviewNotice(null);
    videoSourceFailure = null;
    diagnosticError = null;
    errorMessage = null;
    exportHistoryWarning = null;
    _historyActiveMode = null;
    _historyPlannedCount = 0;
    _historyExportStartedAt = null;
    stage = AnalysisStage.idle;
    progress = 0;
    progressMessage = '';
    processedFrames = null;
    totalFrames = null;
    eta = null;
    analysing = false;
    exporting = false;
    exportedPaths = const [];
    exportBatchTotal = 0;
    exportBatchFiles = const [];
    _batchExport = false;
    _batchStopRequested = false;
    exportAudioSkipped = false;
    exportMergedOverlapCount = null;
    analysisStartedAt = null;
  }

  Future<void> importProject({bool requireIdle = false}) async {
    if (requireIdle && projectManagementBlockReason != null) return;
    final intent = _newProjectIntent();
    final id = project.id, session = _projectSession;
    try {
      final result = await _pickFiles(
        type: FileType.custom,
        kind: 'project',
        allowedExtensions: ['bhe', 'json'],
      );
      final path = result?.files.single.path;
      if (path == null ||
          !_isProjectIntent(intent) ||
          project.id != id ||
          _projectSession != session) {
        return;
      }
      final file = File(path);
      final content = path.toLowerCase().endsWith('.bhe')
          ? _readProjectFromArchive(await file.readAsBytes())
          : await file.readAsString();
      if (!_isProjectIntent(intent) ||
          project.id != id ||
          _projectSession != session) {
        return;
      }
      await _withProjectTransition(intent, () async {
        if (requireIdle && projectManagementBlockReason != null) return;
        if (analysing) await cancelAnalysis();
        if (!_isProjectIntent(intent)) return;
        _invalidateVideoPreparation();
        final imported = await _mutations.run(() async {
          if (!_isProjectIntent(intent) || (requireIdle && projectManagementBlockReason != null)) return false;
          final existing = await existingProjectStorageIds(
            await _dataDirectory(),
          );
          if (!_isProjectIntent(intent) || (requireIdle && projectManagementBlockReason != null)) return false;
          final value = const ProjectPackageCodec().decode(
            content,
            existingIds: [
              project.id,
              ...recentProjects.map((item) => item.id),
              ...existing,
            ],
          );
          await _writeProject(value);
          project = value;
          _resetTransientState();
          diagnosticError = null;
          errorMessage = null;
          notifyListeners();
          return true;
        });
        if (!imported || !_isProjectIntent(intent)) return;
        await _validateImportedVideoIfPresent(projectIntent: intent);
        if (_isProjectIntent(intent)) notifyListeners();
      });
    } on Object catch (error, stack) {
      if (!_isProjectIntent(intent)) {
        MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'project.import',
        );
        return;
      }
      recordDiagnosticFailure(error, stack, operation: 'project.import');
      notifyListeners();
    }
  }

  Future<void> relinkVideo() async {
    if (relinkingVideo || preparingVideo || exporting) return;
    var snapshot = project;
    final intent = _projectIntent;
    final generation = ++_videoPreparationGeneration;
    final operation = ++_relinkSerial;
    relinkingVideo = true;
    relinkCancelling = false;
    notifyListeners();
    String? path;
    bool current() =>
        _isCurrentVideoPreparation(generation, snapshot.id, intent);
    try {
      if (analysing) {
        await cancelAnalysis();
        if (!current()) return;
        snapshot = snapshot.copyWith(
          lastAnalysisStatus: project.lastAnalysisStatus,
          lastAnalysisMessage: project.lastAnalysisMessage,
        );
      }
      if (!current()) return;
      final picked = await _pickVideo();
      if (picked == null || !current()) return;
      path = picked.path;
      await _storeVideo(
        path,
        snapshot,
        generation,
        fromPicker: true,
        name: picked.name,
        projectIntent: intent,
      );
      if (!current()) return;
      videoSourceFailure = null;
      diagnosticError = null;
      errorMessage = null;
    } on VideoSourceCancelled {
      // Switching project, cancelling, or closing never changes the new page.
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'project');
      if (current()) _recordVideoFailure(error, path, stack);
    } finally {
      if (!_disposed && operation == _relinkSerial) {
        relinkingVideo = false;
        relinkCancelling = false;
        notifyListeners();
      }
    }
  }

  Future<bool> updateSettings(
    AnalysisSettings settings, {
    Set<String>? fields,
  }) {
    final changed = fields == null
        ? const {
            'mode',
            'clip',
            'startMs',
            'endMs',
            'sampleFps',
            'confidenceThreshold',
            'modelSize',
            'inferenceBatchSize',
          }
        : Set<String>.of(fields);
    return _submitProjectChange(
      (current) {
        final now = current.settings;
        return current.copyWith(
          settings: AnalysisSettings(
            mode: changed.contains('mode') ? settings.mode : now.mode,
            clip: changed.contains('clip') ? settings.clip : now.clip,
            startMs: changed.contains('startMs')
                ? settings.startMs
                : now.startMs,
            endMs: changed.contains('endMs') ? settings.endMs : now.endMs,
            sampleFps: changed.contains('sampleFps')
                ? settings.sampleFps
                : now.sampleFps,
            confidenceThreshold: changed.contains('confidenceThreshold')
                ? settings.confidenceThreshold
                : now.confidenceThreshold,
            modelSize: changed.contains('modelSize')
                ? settings.modelSize
                : now.modelSize,
            inferenceBatchSize: changed.contains('inferenceBatchSize')
                ? settings.inferenceBatchSize
                : now.inferenceBatchSize,
          ),
        );
      },
      inverse: (before) {
        final settingsBefore = before.settings;
        final old = <String, Object?>{
          if (changed.contains('mode')) 'mode': settingsBefore.mode,
          if (changed.contains('clip')) 'clip': settingsBefore.clip,
          if (changed.contains('startMs')) 'startMs': settingsBefore.startMs,
          if (changed.contains('endMs')) 'endMs': settingsBefore.endMs,
          if (changed.contains('sampleFps'))
            'sampleFps': settingsBefore.sampleFps,
          if (changed.contains('confidenceThreshold'))
            'confidenceThreshold': settingsBefore.confidenceThreshold,
          if (changed.contains('modelSize'))
            'modelSize': settingsBefore.modelSize,
          if (changed.contains('inferenceBatchSize'))
            'inferenceBatchSize': settingsBefore.inferenceBatchSize,
        };
        return (current) {
          final now = current.settings;
          return current.copyWith(
            settings: AnalysisSettings(
              mode: old.containsKey('mode')
                  ? old['mode'] as AnalysisMode
                  : now.mode,
              clip: old.containsKey('clip')
                  ? old['clip'] as ClipSettings
                  : now.clip,
              startMs: old.containsKey('startMs')
                  ? old['startMs'] as int
                  : now.startMs,
              endMs: old.containsKey('endMs')
                  ? old['endMs'] as int?
                  : now.endMs,
              sampleFps: old.containsKey('sampleFps')
                  ? old['sampleFps'] as double?
                  : now.sampleFps,
              confidenceThreshold: old.containsKey('confidenceThreshold')
                  ? old['confidenceThreshold'] as double
                  : now.confidenceThreshold,
              modelSize: old.containsKey('modelSize')
                  ? old['modelSize'] as int?
                  : now.modelSize,
              inferenceBatchSize: old.containsKey('inferenceBatchSize')
                  ? old['inferenceBatchSize'] as int
                  : now.inferenceBatchSize,
            ),
          );
        };
      },
    );
  }

  Future<bool> updateRoi(Roi roi) => updateRois(
    hoop: roi,
    net: Roi(
      left: roi.left,
      top: (roi.top + .06).clamp(0, 1),
      right: roi.right,
      bottom: (roi.bottom + .18).clamp(0, 1),
    ),
  );

  Future<bool> updateRois({required Roi hoop, required Roi net}) =>
      _submitProjectChange(
        (current) => current.copyWith(hoopRoi: hoop, netRoi: net),
        inverse: _restoreRois,
      );

  Future<void> clearProject() {
    final intent = _newProjectIntent();
    return _withProjectTransition(intent, () async {
      if (analysing) await cancelAnalysis();
      if (!_isProjectIntent(intent)) return;
      _invalidateVideoPreparation();
      await _mutations.run(() async {
        if (!_isProjectIntent(intent)) return;
        final deletedId = project.id;
        stage = AnalysisStage.idle;
        diagnosticError = null;
        errorMessage = null;
        _resetTransientState();
        final file = await _projectFile(deletedId);
        if (await file.exists()) await file.delete();
        final cover = await _coverFile(deletedId);
        if (await cover.exists()) await cover.delete();
        coverPaths = {...coverPaths}..remove(deletedId);
        recentProjects = recentProjects
            .where((item) => item.id != deletedId)
            .toList();
        await _persistProjects();
        if (recentProjects.isEmpty) {
          project = _newProject();
        } else {
          project = recentProjects.first;
          exportedPaths = const [];
          exportAudioSkipped = false;
          exportMergedOverlapCount = null;
        }
        final directory = await _dataDirectory();
        for (final name in ['project.bhe.json', 'project.bhe']) {
          final legacy = File('${directory.path}/$name');
          if (await legacy.exists()) await legacy.delete();
        }
        for (final name in ['exports', 'package_staging']) {
          final artifactDirectory = Directory(
            await _projectPath(deletedId, area: name),
          );
          if (await artifactDirectory.exists()) {
            await artifactDirectory.delete(recursive: true);
          }
        }
        final videoDirectory = Directory(
          await _projectPath(deletedId, area: 'videos'),
        );
        if (await videoDirectory.exists()) {
          await videoDirectory.delete(recursive: true);
        }
        notifyListeners();
      });
      if (_isProjectIntent(intent) && project.video != null) {
        await _validateImportedVideoIfPresent(projectIntent: intent);
      }
    });
  }

  Future<ReviewActionResult> toggleCandidate(
    String id,
    CandidateSelection selection,
  ) => _changeReviewResult(
    kind: ReviewChange.selection,
    focusId: id,
    notice: selection == CandidateSelection.included ? '已保留' : '已排除',
    change: (items) => [
      for (final item in items)
        item.id == id
            ? item.copyWith(selection: selection, reviewed: true)
            : item,
    ],
  );

  Future<bool> addCandidate(Candidate candidate) => _submitProjectChange(
    (current) {
      final candidates = [...current.candidates, candidate]
        ..sort((a, b) => a.eventMs.compareTo(b.eventMs));
      return current.copyWith(candidates: candidates);
    },
    inverse: (_) =>
        (current) => current.copyWith(
          candidates: current.candidates
              .where((item) => item.id != candidate.id)
              .toList(),
        ),
  );

  Future<bool> setAllCandidates(CandidateSelection selection) => _changeReview(
    kind: ReviewChange.selection,
    focusId: project.candidates.isEmpty ? '' : project.candidates.first.id,
    notice: selection == CandidateSelection.included ? '已保留' : '已排除',
    change: (items) => [
      for (final candidate in items) candidate.copyWith(selection: selection),
    ],
  );

  Future<bool> setCandidatePlayer(String id, String? player) => _changeReview(
    kind: ReviewChange.player,
    focusId: id,
    notice: '已设标签',
    change: (items) => [
      for (final item in items)
        item.id == id
            ? item.copyWith(player: player, clearPlayer: player == null)
            : item,
    ],
  );

  Future<bool> addPlayer(String player) {
    final normalized = player.trim();
    if (normalized.isEmpty) return Future.value(false);
    return _submitProjectChange(
      (current) => current.players.contains(normalized)
          ? current
          : current.copyWith(players: [...current.players, normalized]),
      inverse: _restorePlayers,
    );
  }

  Future<bool> renamePlayer(String oldName, String newName) {
    final value = newName.trim();
    if (value.isEmpty) return Future.value(false);
    return _changePlayer(oldName, value);
  }

  Future<bool> removePlayer(String player) => _changePlayer(player, null);

  Future<bool> _changePlayer(String oldName, String? newName) {
    if (_projectTransitions != 0) return Future.value(false);
    final id = project.id, session = _projectSession;
    return _mutations.run(() async {
      if (_disposed || project.id != id || _projectSession != session) {
        return false;
      }
      if (!project.players.contains(oldName) ||
          (newName != null &&
              newName != oldName &&
              project.players.contains(newName))) {
        return false;
      }
      if (newName == oldName) return true;
      final next = project.copyWith(
        players: [
          for (final name in project.players)
            if (name == oldName) ...[?newName] else name,
        ],
        candidates: [
          for (final c in project.candidates)
            if (c.player == oldName)
              c.copyWith(player: newName, clearPlayer: newName == null)
            else
              c,
        ],
      );
      try {
        await _writeProject(next);
        if (_disposed || project.id != id || _projectSession != session) {
          return false;
        }
        project = next;
        reviewHistory.remapPlayer(oldName, newName);
        lastPlayerOldName = oldName;
        lastPlayerNewName = newName;
        playerMutationRevision++;
        notifyListeners();
        return true;
      } catch (error, stack) {
        if (!_disposed && project.id == id && _projectSession == session) {
          recordDiagnosticFailure(error, stack, operation: 'project');
          notifyListeners();
        } else {
          MobileDiagnostics.instance.error(error, stack, operation: 'project');
        }
        return false;
      }
    });
  }

  Future<void> _loadPlayerGroups() => _groupStore.ready;

  Future<bool> savePlayerGroup(String name, {bool replaceExisting = true}) {
    final value = name.trim();
    if (value.isEmpty || projectTransitioning) return Future.value(false);
    final id = project.id, session = _projectSession;
    // Project queue first; group operations never wait for the project queue.
    return _mutations.run(() async {
      if (_disposed ||
          project.id != id ||
          _projectSession != session ||
          projectTransitioning) {
        return false;
      }
      final players = List<String>.of(project.players);
      return _groupStore.change((groups, currentDefault) {
        final exists = groups.any((group) => group.name == value);
        if (exists && !replaceExisting) return null;
        return (
          groups: [
            for (final group in groups)
              if (group.name == value)
                (name: value, players: players)
              else
                group,
            if (!exists) (name: value, players: players),
          ],
          defaultName: currentDefault,
        );
      });
    });
  }

  Future<bool> deletePlayerGroup(String name) =>
      _groupStore.change((groups, currentDefault) {
        if (!groups.any((group) => group.name == name)) return null;
        return (
          groups: [
            for (final group in groups)
              if (group.name != name) group,
          ],
          defaultName: currentDefault == name ? null : currentDefault,
        );
      });

  Future<bool> setDefaultPlayerGroup(String? name) => _groupStore.change((
    groups,
    currentDefault,
  ) {
    if (name != null && !groups.any((group) => group.name == name)) return null;
    return (groups: groups, defaultName: name);
  });

  Future<bool> renamePlayerGroup(String original, String name) {
    final value = name.trim();
    if (value.isEmpty) return Future.value(false);
    return _groupStore.change((groups, currentDefault) {
      if (!groups.any((group) => group.name == original) ||
          groups.any(
            (group) => group.name == value && group.name != original,
          )) {
        return null;
      }
      return (
        groups: [
          for (final group in groups)
            if (group.name == original)
              (name: value, players: group.players)
            else
              group,
        ],
        defaultName: currentDefault == original ? value : currentDefault,
      );
    });
  }

  Future<bool> editPlayerGroup(
    String original,
    String name,
    List<String> players, {
    List<String>? expectedPlayers,
  }) {
    final value = name.trim();
    final cleaned = players.map((player) => player.trim()).toList();
    if (value.isEmpty ||
        cleaned.any((player) => player.isEmpty) ||
        cleaned.toSet().length != cleaned.length) {
      return Future.value(false);
    }
    final expected = expectedPlayers == null
        ? null
        : List<String>.of(expectedPlayers);
    return _groupStore.change((groups, currentDefault) {
      final matches = groups.where((group) => group.name == original);
      if (matches.isEmpty ||
          groups.any(
            (group) => group.name == value && group.name != original,
          )) {
        return null;
      }
      final current = matches.first.players;
      if (expected != null &&
          (expected.length != current.length ||
              List.generate(
                expected.length,
                (i) => i,
              ).any((i) => expected[i] != current[i]))) {
        return null;
      }
      return (
        groups: [
          for (final group in groups)
            if (group.name == original)
              (name: value, players: cleaned)
            else
              group,
        ],
        defaultName: currentDefault == original ? value : currentDefault,
      );
    });
  }

  Future<bool> importPlayers(List<String> players) {
    final requested = List<String>.of(players);
    if (requested.isEmpty) return Future.value(true);
    return _submitProjectChange((current) {
      final all = [...current.players];
      for (final name in requested) {
        if (!all.contains(name)) all.add(name);
      }
      return current.copyWith(players: all);
    }, inverse: _restorePlayers);
  }

  Future<void> exportProjectPackage() async {
    final id = project.id, session = _projectSession;
    bool current() =>
        !_disposed &&
        !projectTransitioning &&
        project.id == id &&
        _projectSession == session;
    if (!current()) return;
    try {
      final package = await _mutations.run(() async {
        if (!current()) return null;
        final snapshot = project;
        final staging = Directory(
          await _projectPath(id, area: 'package_staging'),
        );
        try {
          if (await staging.exists()) await staging.delete(recursive: true);
          await staging.create(recursive: true);
          final projectJson = File('${staging.path}/project.json');
          await projectJson.writeAsString(
            const ProjectPackageCodec().encode(snapshot),
          );
          final file = File(await _projectPath(id, suffix: '.bhe'));
          final encoder = ZipFileEncoder()
            ..create(file.path, level: ZipFileEncoder.store);
          try {
            encoder.addFileSync(projectJson, 'project.json');
          } finally {
            encoder.closeSync();
          }
          if (!current()) {
            if (await file.exists()) await file.delete();
            return null;
          }
          return file;
        } finally {
          if (await staging.exists()) await staging.delete(recursive: true);
        }
      });
      if (package == null || !current()) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(package.path)]));
    } on Object catch (error, stack) {
      if (current()) {
        recordDiagnosticFailure(error, stack, operation: 'export');
        notifyListeners();
      } else {
        MobileDiagnostics.instance.error(error, stack, operation: 'export');
      }
    }
  }

  Future<void> exportClips() async {
    await exportClipsInScope(ExportScope.all);
  }

  Future<void> mergeClips() async {
    await mergeClipsInScope(ExportScope.all);
  }

  void _notifyLabelExport() => notifyListeners();
  void _notifyHistory() => notifyListeners();

  int? _beginExport() {
    if (projectTransitioning || exportStartBlockReason != null) {
      notifyListeners();
      return null;
    }
    _exportDrainTimer?.cancel();
    final run = ++_exportRun;
    exporting = true;
    progress = 0;
    progressMessage = '正在检查视频';
    _exportPreflight = true;
    _mergeCommitted = false;
    exportCancelled = false;
    exportedPaths = const [];
    exportBatchTotal = 0;
    exportBatchFiles = const [];
    _batchExport = false;
    _batchStopRequested = false;
    exportAudioSkipped = false;
    exportMergedOverlapCount = null;
    diagnosticError = null;
    errorMessage = null;
    exportHistoryWarning = null;
    _historyActiveMode = null;
    _historyPlannedCount = 0;
    _historyExportStartedAt = DateTime.now();
    MobileDiagnostics.instance.event('export.start');
    notifyListeners();
    return run;
  }

  Future<void> exportClipsInScope(ExportScope scope) async {
    final run = _beginExport();
    if (run == null) return;
    final stopwatch = Stopwatch()..start();
    final projectId = project.id, session = _projectSession;
    bool current() =>
        !_disposed &&
        project.id == projectId &&
        _projectSession == session &&
        _exportRun == run;
    bool eligible() => current() && !exportCancelled;
    var plannedCount = 0;
    Directory? batchDirectory;
    try {
      if (!await _matchesProjectVideo(applyResult: eligible)) {
        if (!eligible()) return;
        errorMessage ??= '请先重新选择原视频。';
        notifyListeners();
        return;
      }
      if (!eligible()) return;
      final candidates = project.candidates
          .where(
            (candidate) => candidate.selection == CandidateSelection.included,
          )
          .where(scope.matches)
          .toList();
      if (candidates.isEmpty) {
        errorMessage = '没有符合条件的保留片段。';
        notifyListeners();
        return;
      }
      plannedCount = candidates.length;
      _historyActiveMode = 'clips';
      _historyPlannedCount = plannedCount;
      batchDirectory = await _newExportDirectory(projectId, 'clips_');
      final outputDirectory = batchDirectory.path;
      if (!eligible()) return;
      _exportPreflight = false;
      var firstUpdate = true;
      await for (final update in exportEngine.exportClips(
        video: project.video!,
        candidates: candidates,
        outputDirectory: outputDirectory,
      )) {
        if (!current()) return;
        if (firstUpdate && exportCancelled) await exportEngine.cancel();
        firstUpdate = false;
        if (!current()) return;
        exportAudioSkipped |= update.skippedAudioTracks.isNotEmpty;
        progress = update.progress;
        progressMessage = update.message;
        if (update.outputPath != null) {
          exportedPaths = [...exportedPaths, update.outputPath!];
        }
        notifyListeners();
      }
      if (!current() || (exportCancelled && !_mergeCommitted)) return;
      final duration = stopwatch.elapsedMilliseconds;
      if (!await _submitProjectChange(
        (current) => current.copyWith(lastExportDurationMs: duration),
        inverse: (before) => _restoreOperationFields(before, {'export'}),
        operation: 'export',
      )) {
        return;
      }
      MobileDiagnostics.instance.event('operation.completed');
    } on Object catch (error, stack) {
      if (error is ExportDrainTimeout) _markExportUncertain(error, stack);
      if (current()) {
        recordDiagnosticFailure(error, stack, operation: 'export');
        notifyListeners();
      } else {
        MobileDiagnostics.instance.error(error, stack, operation: 'export');
      }
    } finally {
      stopwatch.stop();
      if (current() && exportedPaths.isNotEmpty) {
        await _recordExportHistory(mode: 'clips', plannedCount: plannedCount, durationMs: stopwatch.elapsedMilliseconds, paths: List.of(exportedPaths), expectedRun: run);
      }
      await _removeEmptyExportDirectory(batchDirectory);
      if (current()) {
        _exportDrainTimer?.cancel();
        exporting = false;
        _exportPreflight = false;
        notifyListeners();
      }
    }
  }

  Future<void> mergeClipsInScope(ExportScope scope) async {
    final run = _beginExport();
    if (run == null) return;
    final stopwatch = Stopwatch()..start();
    final projectId = project.id, session = _projectSession;
    bool current() =>
        !_disposed &&
        project.id == projectId &&
        _projectSession == session &&
        _exportRun == run;
    bool eligible() => current() && !exportCancelled;
    Directory? batchDirectory;
    try {
      if (!await _matchesProjectVideo(applyResult: eligible)) {
        if (!eligible()) return;
        errorMessage ??= '请先重新选择原视频。';
        notifyListeners();
        return;
      }
      if (!eligible()) return;
      final candidates =
          project.candidates
              .where(
                (candidate) =>
                    candidate.selection == CandidateSelection.included,
              )
              .where(
                (candidate) => scope.matches(candidate),
              )
              .toList()
            ..sort((a, b) => a.startMs.compareTo(b.startMs));
      if (candidates.isEmpty) {
        errorMessage = '没有符合条件的保留片段。';
        notifyListeners();
        return;
      }
      _historyActiveMode = 'merged';
      _historyPlannedCount = 1;
      batchDirectory = await _newExportDirectory(projectId, 'merge_');
      final outputPath = '${batchDirectory.path}/${projectId}_merged.mp4';
      if (!eligible()) return;
      _exportPreflight = false;
      var firstUpdate = true;
      await for (final update in exportEngine.mergeClips(
        video: project.video!,
        candidates: candidates,
        outputPath: outputPath,
      )) {
        if (!current()) return;
        if (firstUpdate && exportCancelled && !update.committed) {
          await exportEngine.cancel();
        }
        firstUpdate = false;
        if (!current()) return;
        if (update.committed) {
          _mergeCommitted = true;
          exportCancelled = false;
        }
        exportAudioSkipped |= update.skippedAudioTracks.isNotEmpty;
        exportMergedOverlapCount = update.mergedOverlapCount;
        progress = update.progress;
        progressMessage = update.message;
        if (update.outputPath != null) {
          exportedPaths = [update.outputPath!];
        }
        notifyListeners();
      }
      if (!current() || (exportCancelled && !_mergeCommitted)) return;
      final duration = stopwatch.elapsedMilliseconds;
      if (!await _submitProjectChange(
        (current) => current.copyWith(lastExportDurationMs: duration),
        inverse: (before) => _restoreOperationFields(before, {'export'}),
        operation: 'export',
      )) {
        exportMergedOverlapCount = null;
        return;
      }
      MobileDiagnostics.instance.event('operation.completed');
    } on Object catch (error, stack) {
      if (error is ExportDrainTimeout) _markExportUncertain(error, stack);
      if (current()) {
        if (error is ExportDrainTimeout && _mergeCommitted) {
          final duration = stopwatch.elapsedMilliseconds;
          if (await _submitProjectChange(
            (current) => current.copyWith(lastExportDurationMs: duration),
            inverse: (before) => _restoreOperationFields(before, {'export'}),
            operation: 'export',
          )) {
            MobileDiagnostics.instance.event('operation.completed');
          }
        } else {
          if (!_mergeCommitted) exportMergedOverlapCount = null;
          recordDiagnosticFailure(error, stack, operation: 'export');
          notifyListeners();
        }
      } else {
        MobileDiagnostics.instance.error(error, stack, operation: 'export');
      }
    } finally {
      stopwatch.stop();
      if (current() && exportedPaths.isNotEmpty) {
        await _recordExportHistory(mode: 'merged', plannedCount: 1, durationMs: stopwatch.elapsedMilliseconds, paths: List.of(exportedPaths), expectedRun: run);
      }
      await _removeEmptyExportDirectory(batchDirectory);
      if (current()) {
        _exportDrainTimer?.cancel();
        exporting = false;
        _exportPreflight = false;
        notifyListeners();
      }
    }
  }

  Future<void> cancelExport() async {
    if (!exporting) return;
    if (_batchExport) {
      _batchStopRequested = true;
      if (_mergeCommitted) {
        notifyListeners();
        return;
      }
    }
    if (_mergeCommitted || exportCancelled) return;
    final run = _exportRun;
    exportCancelled = true;
    if (!_batchExport) exportMergedOverlapCount = null;
    if (_exportPreflight) {
      _exportRun++;
      _exportPreflight = false;
      exporting = false;
      progressMessage = '导出已取消';
      notifyListeners();
      return;
    }
    notifyListeners();
    _exportDrainTimer?.cancel();
    _exportDrainTimer = Timer(exportDrainTimeout, () {
      if (_disposed || run != _exportRun || !exporting || _mergeCommitted) {
        return;
      }
      _exportRun++;
      exporting = false;
      _exportPreflight = false;
      final error = TimeoutException('上一次导出尚未结束，请稍后重试。');
      _markExportUncertain(error, StackTrace.current);
      recordDiagnosticFailure(error, StackTrace.current, operation: 'export');
      errorMessage = '上一次导出尚未结束，请稍后重试。';
      progressMessage = errorMessage!;
      _recordTimedOutPartialHistory(run);
      notifyListeners();
    });
    try {
      await exportEngine.cancel().timeout(exportCancelTimeout);
      if (!_disposed && run == _exportRun && !_mergeCommitted) {
        progressMessage = '导出已取消';
      }
    } on Object catch (error, stack) {
      if (!_disposed && run == _exportRun && !_mergeCommitted) {
        recordDiagnosticFailure(error, stack, operation: 'export');
      } else {
        MobileDiagnostics.instance.error(error, stack, operation: 'export');
      }
    }
    if (!_disposed && run == _exportRun) notifyListeners();
  }

  Future<void> shareExportedFiles({List<String>? paths}) async {
    final selectedPaths = paths ?? exportedPaths;
    if (selectedPaths.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: selectedPaths.map(XFile.new).toList()),
      );
    } on Object catch (error, stack) {
      recordDiagnosticFailure(error, stack, operation: 'export');
      notifyListeners();
    }
  }

  Future<void> saveExportedFiles({List<String>? paths}) async {
    final selectedPaths = paths ?? exportedPaths;
    if (selectedPaths.isEmpty) return;
    if (exportStartBlockReason != null) {
      notifyListeners();
      return;
    }
    final run = ++_exportRun;
    final id = project.id, session = _projectSession;
    bool current() => !_disposed && project.id == id && _projectSession == session && _exportRun == run;
    _mergeCommitted = false;
    exporting = true;
    diagnosticError = null;
    errorMessage = null;
    exportHistoryWarning = null;
    _historyActiveMode = null;
    _historyPlannedCount = 0;
    _historyExportStartedAt = null;
    try {
      for (var index = 0; index < selectedPaths.length; index++) {
        progress = index / selectedPaths.length;
        progressMessage = '正在保存到相册 ${index + 1}/${selectedPaths.length}';
        notifyListeners();
        await exportEngine.saveToLibrary(selectedPaths[index]);
        if (!current()) return;
        await _markHistoryGallerySaved(selectedPaths[index], id: id, session: session);
        if (!current()) return;
      }
      progress = 1;
      progressMessage = '已保存 ${selectedPaths.length} 个片段到相册';
    } on Object catch (error, stack) {
      if (current()) {
        recordDiagnosticFailure(error, stack, operation: 'export');
      } else {
        MobileDiagnostics.instance.error(error, stack, operation: 'export');
      }
    } finally {
      if (current()) {
        exporting = false;
        notifyListeners();
      }
    }
  }

  Future<void> startAnalysis({
    List<String>? rosterPlayers,
    String? expectedRosterGroup,
    String? expectedProjectId,
    int? expectedSession,
    int? expectedVideoGeneration,
  }) async {
    final intentProjectId = expectedProjectId ?? project.id;
    final intentSession = expectedSession ?? projectSession;
    final intentVideoGeneration =
        expectedVideoGeneration ?? videoPreparationGeneration;
    final cancelIntent = _analysisCancelIntent;
    final groupRevision = expectedRosterGroup == null
        ? null
        : _groupStore.revisionFor(expectedRosterGroup);
    final selectedPlayers = List<String>.of(rosterPlayers ?? const []);
    bool rosterCurrent() =>
        !_disposed &&
        project.id == intentProjectId &&
        projectSession == intentSession &&
        videoPreparationGeneration == intentVideoGeneration &&
        !projectTransitioning;
    if (!rosterCurrent()) return;
    if (analysisStartBlockReason != null) {
      notifyListeners();
      return;
    }
    if (!hasVideo || project.hoopRoi == null || project.netRoi == null) {
      errorMessage = '请先选择视频并设置投篮分析区、篮网检测区。';
      notifyListeners();
      return;
    }
    stage = AnalysisStage.validateInput;
    progress = 0.01;
    progressMessage = '正在检查视频';
    analysing = true;
    diagnosticError = null;
    errorMessage = null;
    final stopwatch = Stopwatch()..start();
    final generation = ++_analysisGeneration;
    analysisStartedAt = DateTime.now();
    notifyListeners();
    try {
      var checkingInput = true;
      final videoMatches =
          await _matchesProjectVideo(
            applyResult: () =>
                checkingInput && generation == _analysisGeneration,
          ).timeout(
            const Duration(seconds: 45),
            onTimeout: () {
              checkingInput = false;
              return false;
            },
          );
      checkingInput = false;
      if (generation != _analysisGeneration) return;
      if (!videoMatches) {
        throw const MobileAnalysisException('视频检查未通过或耗时过长，请重新选择可正常播放的原视频。');
      }
      if (!rosterCurrent()) return;
      var rosterCommitted = false;
      bool intentCurrent() {
        if (!rosterCurrent() ||
            generation != _analysisGeneration ||
            cancelIntent != _analysisCancelIntent) {
          return false;
        }
        if (rosterCommitted || expectedRosterGroup == null) return true;
        return _groupStore.revisionFor(expectedRosterGroup) == groupRevision &&
            playerGroups.any((group) => group.name == expectedRosterGroup) &&
            (_rosterSelection == null ||
                (!_rosterSelection!.groupChanged &&
                    _rosterSelection!.groupName == expectedRosterGroup));
      }

      if (selectedPlayers.isNotEmpty) {
        if (!await _submitProjectChange(
          (current) {
            final players = List<String>.of(current.players);
            final selected = selectedPlayers.toSet();
            final ordered = expectedRosterGroup == null
                ? selectedPlayers
                : playerGroups
                      .firstWhere((group) => group.name == expectedRosterGroup)
                      .players
                      .where(selected.contains);
            for (final name in ordered) {
              if (!players.contains(name)) players.add(name);
            }
            return current.copyWith(players: players);
          },
          guard: intentCurrent,
          inverse: _restorePlayers,
          operation: 'analysis',
        )) {
          return;
        }
      }
      if (selectedPlayers.isEmpty && !intentCurrent()) return;
      rosterCommitted = true;
      if (!intentCurrent()) return;
      final engine = analysisEngine;
      PreparedNativeAnalysis? prepared;
      if (engine is NativeAnalysisEngine) {
        stage = AnalysisStage.prepareProxy;
        progress = 0.03;
        progressMessage = '正在准备本地模型';
        notifyListeners();
        prepared = await engine.prepareAnalysis();
        if (prepared == null || !intentCurrent()) return;
      }
      StreamIterator<AnalysisProgress>? nativeIterator;
      AnalysisProgress? firstNativeUpdate;
      if (engine is NativeAnalysisEngine) {
        final iterator = StreamIterator(
          engine.startPrepared(
            prepared!,
            video: project.video!,
            hoopRoi: project.hoopRoi!,
            rimRoi: project.rimRoi,
            netRoi: project.netRoi!,
            settings: project.settings,
          ),
        );
        nativeIterator = iterator;
        final cancelled = Completer<void>();
        _analysisNativeWait = cancelled;
        _waitingNativeRun = prepared;
        bool hasUpdate;
        try {
          try {
            hasUpdate = await Future.any([
              iterator.moveNext(),
              cancelled.future.then((_) => false),
            ]).timeout(analysisStartupTimeout);
          } on TimeoutException {
            _markNativeUncertain(prepared);
            unawaited(
              engine
                  .cancelPrepared(prepared)
                  .timeout(analysisCancelTimeout)
                  .catchError((Object error, StackTrace stack) {
                    MobileDiagnostics.instance.error(
                      error,
                      stack,
                      operation: 'analysis.cancel',
                    );
                  }),
            );
            unawaited(iterator.cancel());
            throw const MobileAnalysisException('分析启动超时，正在尝试停止，请检查设备后重试。');
          }
          final pendingCancel = _analysisCancelPending;
          if (pendingCancel != null) await pendingCancel;
        } finally {
          if (identical(_analysisNativeWait, cancelled)) {
            _analysisNativeWait = null;
          }
          if (identical(_waitingNativeRun, prepared)) _waitingNativeRun = null;
        }
        if (!hasUpdate || !intentCurrent()) {
          if (!prepared.cancelled &&
              !identical(_uncertainNativeRun, prepared)) {
            try {
              await engine.cancelPrepared(prepared);
            } on Object catch (error, stack) {
              MobileDiagnostics.instance.error(
                error,
                stack,
                operation: 'analysis.cancel',
              );
            }
          }
          unawaited(iterator.cancel());
          return;
        }
        firstNativeUpdate = iterator.current;
      }
      Stream<AnalysisProgress> replayNative() async* {
        final iterator = nativeIterator!;
        try {
          yield firstNativeUpdate!;
          while (await iterator.moveNext()) {
            yield iterator.current;
          }
        } finally {
          await iterator.cancel();
        }
      }

      final initialMessage = progressMessage;
      StreamController<AnalysisProgress>? controller;
      StreamSubscription<AnalysisProgress>? sourceSubscription;
      if (!await _submitProjectChange(
        (current) => current.copyWith(
          candidates: const [],
          lastAnalysisStatus: 'running',
          lastAnalysisProgressPercent: 0,
          lastAnalysisMessage: initialMessage,
        ),
        guard: intentCurrent,
        recheckAfterWrite: true,
        inverse: (before) => _restoreOperationFields(before, {
          'candidates',
          'status',
          'progress',
          'message',
        }),
        operation: 'analysis',
        onSuccess: () {
          final output = StreamController<AnalysisProgress>(
            onCancel: () => sourceSubscription?.cancel(),
          );
          controller = output;
          final launched = Completer<void>();
          _analysisLaunchBarrier = launched.future;
          void markLaunched() {
            if (!launched.isCompleted) launched.complete();
          }

          final source = engine is NativeAnalysisEngine
              ? replayNative()
              : engine.analyze(
                  video: project.video!,
                  hoopRoi: project.hoopRoi!,
                  rimRoi: project.rimRoi,
                  netRoi: project.netRoi!,
                  settings: project.settings,
                );
          sourceSubscription = source.listen(
            (update) {
              markLaunched();
              output.add(update);
            },
            onError: (Object error, StackTrace stack) {
              markLaunched();
              output.addError(error, stack);
            },
            onDone: () {
              markLaunched();
              output.close();
            },
          );
          // Stream.listen starts synchronous engines immediately and schedules
          // async generators before this microtask, without waiting for data.
          scheduleMicrotask(markLaunched);
          reviewHistory.clear();
          _setReviewNotice(null);
        },
      )) {
        if (engine is NativeAnalysisEngine && prepared != null) {
          try {
            await engine.cancelPrepared(prepared);
          } on Object catch (error, stack) {
            MobileDiagnostics.instance.error(
              error,
              stack,
              operation: 'analysis.cancel',
            );
          }
          unawaited(nativeIterator!.cancel());
        }
        return;
      }
      if (generation != _analysisGeneration) {
        await sourceSubscription?.cancel();
        return;
      }
      progress = 0.02;
      progressMessage = '正在准备本地分析';
      notifyListeners();
      var lastCheckpoint = -1;
      List<Candidate>? latestCandidates;
      await for (final update in controller!.stream) {
        if (generation != _analysisGeneration) break;
        if (stage != update.stage) {
          MobileDiagnostics.instance.event('analysis.${update.stage.name}');
        }
        stage = update.stage;
        progress = update.progress.clamp(0, 1);
        progressMessage = update.message;
        processedFrames = update.processedFrames;
        totalFrames = update.totalFrames;
        eta = update.eta;
        final percent = (progress * 100).round();
        latestCandidates = update.candidates;
        final checkpoint =
            percent == 100 || (percent % 5 == 0 && percent != lastCheckpoint);
        if (!checkpoint) {
          notifyListeners();
          continue;
        }
        lastCheckpoint = percent;
        if (!await _submitProjectChange(
          (current) => current.copyWith(
            candidates: mergeAnalysisCandidates(
              current.candidates,
              update.candidates,
            ),
            lastAnalysisStatus: 'running',
            lastAnalysisProgressPercent: percent,
            lastAnalysisMessage: update.message,
          ),
          inverse: (before) => _restoreOperationFields(before, {
            'candidates',
            'status',
            'progress',
            'message',
          }),
          operation: 'analysis',
        )) {
          return;
        }
        notifyListeners();
      }
      if (generation != _analysisGeneration) return;
      stopwatch.stop();
      final duration = stopwatch.elapsedMilliseconds;
      final completedAt = DateTime.now();
      if (!await _submitProjectChange(
        (current) => current.copyWith(
          candidates: latestCandidates == null
              ? null
              : mergeAnalysisCandidates(current.candidates, latestCandidates),
          lastAnalysisDurationMs: duration,
          lastAnalysisAt: completedAt,
          lastAnalysisStatus: 'completed',
          lastAnalysisProgressPercent: 100,
          lastAnalysisMessage: '分析完成',
        ),
        inverse: (before) => _restoreOperationFields(before, {
          if (latestCandidates != null) 'candidates',
          'duration',
          'at',
          'status',
          'progress',
          'message',
        }),
        operation: 'analysis',
      )) {
        return;
      }
      unawaited(
        _updateCover(project).catchError((Object error, StackTrace stack) {
          MobileDiagnostics.instance.error(
            error,
            stack,
            operation: 'analysis.cover',
          );
        }),
      );
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'project');
      if (generation != _analysisGeneration) return;
      stage = AnalysisStage.failed;
      if (videoSourceFailure == null) {
        recordDiagnosticFailure(error, stack, operation: 'analysis');
      } else {
        diagnosticError = MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'analysis',
        );
        errorMessage = videoSourceFailure!.message;
      }
      final message = errorMessage;
      await _submitProjectChange(
        (current) => current.copyWith(
          lastAnalysisStatus: 'failed',
          lastAnalysisMessage: message,
        ),
        inverse: (before) =>
            _restoreOperationFields(before, {'status', 'message'}),
        operation: 'analysis',
      );
      notifyListeners();
    } finally {
      stopwatch.stop();
      if (generation == _analysisGeneration) {
        _analysisLaunchBarrier = null;
        analysing = false;
        analysisStartedAt = null;
        notifyListeners();
      }
    }
  }

  Future<void> cancelAnalysis() {
    final pending = _analysisCancelPending;
    if (pending != null) return pending;
    if (!analysing) return Future.value();
    final completion = Completer<void>();
    final result = completion.future;
    _analysisCancelPending = result;
    () async {
      try {
        await _cancelAnalysisOnce();
      } finally {
        if (identical(_analysisCancelPending, result)) {
          _analysisCancelPending = null;
        }
        completion.complete();
      }
    }();
    return result;
  }

  Future<void> _cancelAnalysisOnce() async {
    final priorCancelIntent = _analysisCancelIntent;
    final cancelIntent = ++_analysisCancelIntent;
    final generation = _analysisGeneration;
    final projectId = project.id;
    final engine = analysisEngine;
    final nativeRun = engine is NativeAnalysisEngine ? engine.activeRun : null;
    try {
      final launch = _analysisLaunchBarrier;
      if (launch != null) await launch;
      await analysisEngine.cancel().timeout(analysisCancelTimeout);
    } on Object catch (error, stack) {
      if (generation == _analysisGeneration &&
          project.id == projectId &&
          !_disposed) {
        if (_analysisCancelIntent == cancelIntent) {
          _analysisCancelIntent = priorCancelIntent;
        }
        recordDiagnosticFailure(error, stack, operation: 'analysis');
        if (nativeRun != null && nativeRun.dispatched) {
          _markNativeUncertain(nativeRun, diagnostic: diagnosticError);
        }
        final run = _waitingNativeRun;
        if (error is TimeoutException && run != null) {
          if (!identical(_uncertainNativeRun, run)) {
            _markNativeUncertain(run, diagnostic: diagnosticError);
          }
          final waiting = _analysisNativeWait;
          if (waiting != null && !waiting.isCompleted) waiting.complete();
          _analysisNativeWait = null;
          _analysisGeneration++;
          analysing = false;
          analysisStartedAt = null;
          stage = AnalysisStage.failed;
          progressMessage = '无法确认分析已停止，请稍候再试。';
          errorMessage = progressMessage;
        }
        notifyListeners();
      }
      return;
    }
    if (generation != _analysisGeneration ||
        project.id != projectId ||
        _disposed) {
      return;
    }
    if (nativeRun != null &&
        nativeRun.dispatched &&
        !identical(_uncertainNativeRun, nativeRun)) {
      _markNativeUncertain(nativeRun, cancellationAcknowledged: true);
      unawaited(checkUncertainAnalysis());
    }
    final waiting = _analysisNativeWait;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    _analysisNativeWait = null;
    _analysisGeneration++;
    _analysisLaunchBarrier = null;
    analysing = false;
    analysisStartedAt = null;
    stage = AnalysisStage.cancelled;
    progressMessage = '分析已取消';
    final message = progressMessage;
    await _submitProjectChange(
      (current) => current.copyWith(
        lastAnalysisStatus: 'cancelled',
        lastAnalysisMessage: message,
      ),
      inverse: (before) =>
          _restoreOperationFields(before, {'status', 'message'}),
      operation: 'analysis',
      allowDuringTransition: true,
    );
    notifyListeners();
  }

  Future<bool> updateCandidate(Candidate candidate) => _changeReview(
    kind: ReviewChange.range,
    focusId: candidate.id,
    notice: '已改时长',
    change: (items) => [
      for (final item in items)
        item.id == candidate.id
            ? item.copyWith(
                startMs: candidate.startMs,
                endMs: candidate.endMs,
                rangeEdited: candidate.rangeEdited,
              )
            : item,
    ],
  );

  Future<int> applyBatchClipRange({
    required int beforeSeconds,
    required int afterSeconds,
    Iterable<String>? candidateIds,
    String? focusId,
    bool overwriteManual = false,
  }) async {
    final ids = candidateIds?.toSet();
    var updated = 0;
    final changed = await _changeReview(
      kind: ReviewChange.range,
      focusId:
          focusId ??
          ids?.firstOrNull ??
          project.candidates.firstOrNull?.id ??
          '',
      notice: '已改时长',
      change: (items) {
        final video = project.video;
        if (video == null) return items;
        final beforeMs = beforeSeconds.clamp(0, 3600) * 1000;
        final afterMs = afterSeconds.clamp(0, 3600) * 1000;
        return [
          for (final item in items)
            if ((ids == null || ids.contains(item.id)) &&
                (!item.rangeEdited || overwriteManual))
              () {
                final start = (item.eventMs - beforeMs)
                    .clamp(0, video.durationMs)
                    .toInt();
                final end = (item.eventMs + afterMs)
                    .clamp(0, video.durationMs)
                    .toInt();
                if (end <= start) return item;
                updated++;
                return item.copyWith(
                  startMs: start,
                  endMs: end,
                  rangeEdited: false,
                );
              }()
            else
              item,
        ];
      },
    );
    return changed ? updated : 0;
  }

  Future<bool> updateCandidateNote(String id, String? note) => _changeReview(
    kind: ReviewChange.note,
    focusId: id,
    notice: '已改备注',
    change: (items) => [
      for (final item in items)
        item.id == id
            ? item.copyWith(
                note: note,
                clearNote: note == null || note.trim().isEmpty,
              )
            : item,
    ],
  );
}

Roi netRoiFromRim(Roi analysisRoi, Roi rimRoi) {
  final centerX = (rimRoi.left + rimRoi.right) / 2;
  final rimWidth = (rimRoi.right - rimRoi.left).clamp(0.004, 1.0).toDouble();
  final rimHeight = (rimRoi.bottom - rimRoi.top).clamp(0.008, 1.0).toDouble();
  final analysisWidth = analysisRoi.right - analysisRoi.left;
  final width = (rimWidth * 1.5)
      .clamp(analysisWidth * 0.08, analysisWidth * 0.34)
      .toDouble();
  final left = (centerX - width / 2).clamp(
    analysisRoi.left,
    analysisRoi.right - width,
  );
  final right = left + width;
  // The net starts below the physical rim, not at the top edge of the rim
  // detection box. Using rimRoi.top makes the net overlay appear vertically
  // flipped and includes the backboard/upper hoop area.
  final top = rimRoi.bottom
      .clamp(analysisRoi.top, analysisRoi.bottom)
      .toDouble();
  final bottom = analysisRoi.bottom < top + 4.5 * rimHeight
      ? analysisRoi.bottom
      : top + 4.5 * rimHeight;
  return Roi(
    left: left.clamp(0.0, 1.0).toDouble(),
    top: top.clamp(0.0, 1.0).toDouble(),
    right: right.clamp(0.0, 1.0).toDouble(),
    bottom: bottom.clamp(0.0, 1.0).toDouble(),
  );
}

String _readProjectFromArchive(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final project = archive.files.cast<ArchiveFile?>().firstWhere(
    (file) => file?.name == 'project.json',
    orElse: () => null,
  );
  if (project == null) throw const FormatException('项目包缺少 project.json');
  return utf8.decode(project.readBytes() ?? const <int>[]);
}

/// 可注入的系统文件选择器：默认是 file_picker 的真实实现，测试里换成假实现。
typedef MobileFilePicker =
    Future<FilePickerResult?> Function({
      required FileType type,
      List<String>? allowedExtensions,
    });

Future<FilePickerResult?> _systemFilePicker({
  required FileType type,
  List<String>? allowedExtensions,
}) => FilePicker.platform.pickFiles(
  type: type,
  allowedExtensions: allowedExtensions,
);
