import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'media_bridge.dart';
import 'native_analysis_engine.dart';

class MobileAppState extends ChangeNotifier {
  MobileAppState({MobileAnalysisEngine? analysisEngine})
    : analysisEngine = analysisEngine ?? NativeAnalysisEngine() {
    unawaited(loadSavedProject());
  }

  final MobileAnalysisEngine analysisEngine;
  final MobileExportEngine exportEngine = const NativeMediaExportEngine();

  ProjectSnapshot project = ProjectSnapshot(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: '新项目',
    video: null,
  );
  List<ProjectSnapshot> recentProjects = const [];
  AnalysisStage stage = AnalysisStage.idle;
  double progress = 0;
  String progressMessage = '';
  int? processedFrames;
  int? totalFrames;
  Duration? eta;
  String? errorMessage;
  bool loading = true;
  bool analysing = false;
  bool exporting = false;
  List<String> exportedPaths = const [];
  Future<void> _saveChain = Future<void>.value();
  int _analysisGeneration = 0;
  DateTime? analysisStartedAt;

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

  Future<Directory> _projectsDirectory() async {
    final directory = Directory('${(await _dataDirectory()).path}/projects');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _projectFile(String id) async {
    final directory = await _projectsDirectory();
    return File('${directory.path}/$id.json');
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

  Future<bool> _matchesProjectVideo() async {
    final expected = project.video;
    if (expected == null) return false;
    developer.log(
      'video validation started: ${expected.path}',
      name: 'BHE-Analysis',
    );
    final file = File(expected.path);
    if (!await file.exists()) return false;
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      developer.log('video initialized', name: 'BHE-Analysis');
      final actual = controller.value;
      if (actual.size.width.round() != expected.width ||
          actual.size.height.round() != expected.height ||
          (actual.duration.inMilliseconds - expected.durationMs).abs() > 1500) {
        return false;
      }
      if (expected.sha256 != null) {
        developer.log('video hash validation started', name: 'BHE-Analysis');
        if (await _sha256(file) != expected.sha256) return false;
      }
      developer.log('video validation succeeded', name: 'BHE-Analysis');
      return true;
    } on Object {
      return false;
    } finally {
      await controller.dispose();
    }
  }

  Future<void> _validateImportedVideoIfPresent() async {
    if (project.video == null || !sourceVideoExists) {
      errorMessage = '项目已打开，请重新选择原视频后继续。';
      return;
    }
    if (!await _matchesProjectVideo()) {
      errorMessage = '项目已打开，但当前原视频与项目记录不一致，请重新选择原视频。';
    }
  }

  Future<void> loadSavedProject() async {
    try {
      final directory = await _dataDirectory();
      final indexFile = File('${directory.path}/project_index.json');
      final legacyFile = File('${directory.path}/project.bhe.json');
      if (await indexFile.exists()) {
        final ids =
            (jsonDecode(await indexFile.readAsString()) as List?)
                ?.whereType<String>()
                .toList() ??
            const <String>[];
        for (final id in ids) {
          final file = await _projectFile(id);
          if (!await file.exists()) continue;
          recentProjects = [
            ...recentProjects,
            const ProjectPackageCodec().decode(await file.readAsString()),
          ];
        }
        if (recentProjects.isNotEmpty) project = recentProjects.first;
      } else if (await legacyFile.exists()) {
        project = const ProjectPackageCodec().decode(
          await legacyFile.readAsString(),
        );
        recentProjects = [project];
        await _persistProjects();
      }
      if (project.lastAnalysisStatus == 'running') {
        project = project.copyWith(
          lastAnalysisStatus: 'interrupted',
          lastAnalysisMessage: '应用上次退出时分析未完成，可重新分析。',
        );
        await _queueSave();
      }
    } on Object catch (error) {
      errorMessage = '读取本地项目失败：$error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _writeProject(ProjectSnapshot snapshot) async {
    final file = await _projectFile(snapshot.id);
    await file.writeAsString(const ProjectPackageCodec().encode(snapshot));
    recentProjects = [
      snapshot,
      ...recentProjects.where((item) => item.id != snapshot.id),
    ].take(12).toList();
    await _persistProjects();
  }

  Future<void> _persistProjects() async {
    final directory = await _dataDirectory();
    final indexFile = File('${directory.path}/project_index.json');
    await indexFile.writeAsString(
      jsonEncode(recentProjects.map((item) => item.id).toList()),
    );
  }

  Future<void> openProject(String id) async {
    if (analysing) await cancelAnalysis();
    final file = await _projectFile(id);
    if (!await file.exists()) return;
    project = const ProjectPackageCodec().decode(await file.readAsString());
    errorMessage = null;
    exportedPaths = const [];
    await _validateImportedVideoIfPresent();
    recentProjects = [
      project,
      ...recentProjects.where((item) => item.id != project.id),
    ];
    await _persistProjects();
    notifyListeners();
  }

  Future<void> createNewProject() async {
    if (analysing) await cancelAnalysis();
    project = ProjectSnapshot(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: '新项目',
      video: null,
    );
    stage = AnalysisStage.idle;
    errorMessage = null;
    exportedPaths = const [];
    notifyListeners();
  }

  Future<void> createNewProjectAndPickVideo() async {
    await createNewProject();
    await pickVideo();
  }

  Future<void> _queueSave() {
    final snapshot = project;
    _saveChain = _saveChain.then<void>(
      (_) => _writeProject(snapshot),
      onError: (Object error, StackTrace stack) => _writeProject(snapshot),
    );
    return _saveChain;
  }

  Future<void> pickVideo() async {
    if (analysing) await cancelAnalysis();
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = result?.files.single.path;
    if (path == null) return;
    final file = File(path);
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      final value = controller.value;
      final name = path.split(Platform.pathSeparator).last;
      final sizeBytes = await file.length();
      project = project.copyWith(
        name: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        video: VideoInfo(
          path: path,
          name: name,
          sizeBytes: sizeBytes,
          durationMs: value.duration.inMilliseconds,
          width: value.size.width.round(),
          height: value.size.height.round(),
        ),
        clearHoopRoi: true,
        clearNetRoi: true,
        candidates: const [],
        clearLastAnalysis: true,
      );
      errorMessage = null;
      await _queueSave();
      notifyListeners();
      unawaited(_finishVideoHash(path, sizeBytes, value));
    } finally {
      await controller.dispose();
    }
  }

  Future<void> _finishVideoHash(
    String path,
    int sizeBytes,
    VideoPlayerValue metadata,
  ) async {
    final hash = await _sha256(File(path));
    if (project.video?.path != path) return;
    project = project.copyWith(
      video: VideoInfo(
        path: path,
        name: project.video!.name,
        sizeBytes: sizeBytes,
        durationMs: metadata.duration.inMilliseconds,
        width: metadata.size.width.round(),
        height: metadata.size.height.round(),
        sha256: hash,
      ),
    );
    await _queueSave();
    notifyListeners();
  }

  Future<void> importProject() async {
    if (analysing) await cancelAnalysis();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bhe', 'json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      final file = File(path);
      final content = path.toLowerCase().endsWith('.bhe')
          ? _readProjectFromArchive(await file.readAsBytes())
          : await file.readAsString();
      project = const ProjectPackageCodec().decode(content);
      errorMessage = null;
      await _validateImportedVideoIfPresent();
      await _queueSave();
      notifyListeners();
    } on Object catch (error) {
      errorMessage = '项目包无法打开：$error';
      notifyListeners();
    }
  }

  Future<void> relinkVideo() async {
    if (analysing) await cancelAnalysis();
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = result?.files.single.path;
    if (path == null) return;
    final file = File(path);
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      final value = controller.value;
      final previous = project.video;
      if (previous != null &&
          (previous.width != value.size.width.round() ||
              previous.height != value.size.height.round() ||
              (previous.durationMs - value.duration.inMilliseconds).abs() >
                  1500)) {
        errorMessage = '所选视频的分辨率或时长与项目记录不一致，请选择同一段原视频。';
        notifyListeners();
        return;
      }
      final fileHash = await _sha256(file);
      if (previous?.sha256 != null && previous!.sha256 != fileHash) {
        errorMessage = '所选视频文件与项目记录不一致，请选择原始视频。';
        notifyListeners();
        return;
      }
      final name = path.split(Platform.pathSeparator).last;
      project = project.copyWith(
        video: VideoInfo(
          path: path,
          name: name,
          sizeBytes: await file.length(),
          durationMs: value.duration.inMilliseconds,
          width: value.size.width.round(),
          height: value.size.height.round(),
          sha256: fileHash,
        ),
      );
      errorMessage = null;
      await _queueSave();
      notifyListeners();
    } finally {
      await controller.dispose();
    }
  }

  void updateSettings(AnalysisSettings settings) {
    project = project.copyWith(settings: settings);
    unawaited(_queueSave());
    notifyListeners();
  }

  void updateRoi(Roi roi) {
    updateRois(
      hoop: roi,
      net: Roi(
        left: roi.left,
        top: (roi.top + .06).clamp(0, 1),
        right: roi.right,
        bottom: (roi.bottom + .18).clamp(0, 1),
      ),
    );
  }

  void updateRois({required Roi hoop, required Roi net}) {
    project = project.copyWith(hoopRoi: hoop, netRoi: net);
    unawaited(_queueSave());
    notifyListeners();
  }

  Future<void> clearProject() async {
    if (analysing) await cancelAnalysis();
    await _saveChain;
    final deletedId = project.id;
    project = ProjectSnapshot(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: '新项目',
      video: null,
    );
    stage = AnalysisStage.idle;
    errorMessage = null;
    final file = await _projectFile(deletedId);
    if (await file.exists()) await file.delete();
    recentProjects = recentProjects
        .where((item) => item.id != deletedId)
        .toList();
    await _persistProjects();
    final directory = await _dataDirectory();
    for (final name in ['project.bhe.json', 'project.bhe']) {
      final legacy = File('${directory.path}/$name');
      if (await legacy.exists()) await legacy.delete();
    }
    for (final name in ['exports', 'package_staging']) {
      final artifactDirectory = Directory('${directory.path}/$name/$deletedId');
      if (await artifactDirectory.exists()) {
        await artifactDirectory.delete(recursive: true);
      }
    }
    notifyListeners();
  }

  void toggleCandidate(String id, CandidateSelection selection) {
    project = project.copyWith(
      candidates: project.candidates
          .map(
            (candidate) => candidate.id == id
                ? candidate.copyWith(selection: selection)
                : candidate,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void addCandidate(Candidate candidate) {
    final candidates = [...project.candidates, candidate]
      ..sort((a, b) => a.eventMs.compareTo(b.eventMs));
    project = project.copyWith(candidates: candidates);
    unawaited(_queueSave());
    notifyListeners();
  }

  void setAllCandidates(CandidateSelection selection) {
    project = project.copyWith(
      candidates: project.candidates
          .map((candidate) => candidate.copyWith(selection: selection))
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void setCandidatePlayer(String id, String? player) {
    project = project.copyWith(
      candidates: project.candidates
          .map(
            (candidate) => candidate.id == id
                ? candidate.copyWith(
                    player: player,
                    clearPlayer: player == null,
                  )
                : candidate,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void addPlayer(String player) {
    final normalized = player.trim();
    if (normalized.isEmpty || project.players.contains(normalized)) return;
    project = project.copyWith(players: [...project.players, normalized]);
    unawaited(_queueSave());
    notifyListeners();
  }

  void removePlayer(String player) {
    project = project.copyWith(
      players: project.players.where((item) => item != player).toList(),
      candidates: project.candidates
          .map(
            (candidate) => candidate.player == player
                ? candidate.copyWith(clearPlayer: true)
                : candidate,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  Future<void> exportProjectPackage() async {
    final directory = await _dataDirectory();
    final staging = Directory(
      '${directory.path}/package_staging/${project.id}',
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final projectJson = File('${staging.path}/project.json');
    await projectJson.writeAsString(
      const ProjectPackageCodec().encode(project),
    );
    final file = File('${directory.path}/${project.id}.bhe');
    final encoder = ZipFileEncoder()
      ..create(file.path, level: ZipFileEncoder.store);
    encoder.addFileSync(projectJson, 'project.json');
    encoder.closeSync();
    await staging.delete(recursive: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  Future<void> exportClips() async {
    await exportClipsForPlayer(null);
  }

  Future<void> exportClipsForPlayer(String? player) async {
    if (exporting) return;
    if (!await _matchesProjectVideo()) {
      errorMessage = '请先重新选择原视频。';
      notifyListeners();
      return;
    }
    final directory = await _dataDirectory();
    final candidates = project.candidates
        .where(
          (candidate) => candidate.selection == CandidateSelection.included,
        )
        .where((candidate) => player == null || candidate.player == player)
        .toList();
    if (candidates.isEmpty) {
      errorMessage = '没有符合条件的保留片段。';
      notifyListeners();
      return;
    }
    exporting = true;
    exportedPaths = const [];
    final stopwatch = Stopwatch()..start();
    errorMessage = null;
    try {
      await for (final update in exportEngine.exportClips(
        video: project.video!,
        candidates: candidates,
        outputDirectory: '${directory.path}/exports/${project.id}',
      )) {
        progress = update.progress;
        progressMessage = update.message;
        if (update.outputPath != null) {
          exportedPaths = [...exportedPaths, update.outputPath!];
        }
        notifyListeners();
      }
      project = project.copyWith(
        lastExportDurationMs: stopwatch.elapsedMilliseconds,
      );
      await _queueSave();
    } on Object catch (error) {
      errorMessage = error.toString();
      notifyListeners();
    } finally {
      stopwatch.stop();
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> shareExportedFiles() async {
    if (exportedPaths.isEmpty) return;
    await SharePlus.instance.share(
      ShareParams(files: exportedPaths.map(XFile.new).toList()),
    );
  }

  Future<void> saveExportedFiles() async {
    if (exportedPaths.isEmpty) return;
    exporting = true;
    errorMessage = null;
    try {
      for (var index = 0; index < exportedPaths.length; index++) {
        progress = index / exportedPaths.length;
        progressMessage = '正在保存到相册 ${index + 1}/${exportedPaths.length}';
        notifyListeners();
        await exportEngine.saveToLibrary(exportedPaths[index]);
      }
      progress = 1;
      progressMessage = '已保存 ${exportedPaths.length} 个片段到相册';
    } on Object catch (error) {
      errorMessage = error.toString();
    } finally {
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> startAnalysis() async {
    if (analysing) return;
    if (!hasVideo || project.hoopRoi == null || project.netRoi == null) {
      errorMessage = '请先选择视频并设置篮筐、篮网检测区域。';
      notifyListeners();
      return;
    }
    stage = AnalysisStage.validateInput;
    progress = 0.01;
    progressMessage = '正在检查视频';
    analysing = true;
    errorMessage = null;
    project = project.copyWith(candidates: const []);
    project = project.copyWith(
      lastAnalysisStatus: 'running',
      lastAnalysisProgressPercent: 0,
      lastAnalysisMessage: progressMessage,
    );
    final stopwatch = Stopwatch()..start();
    final generation = ++_analysisGeneration;
    analysisStartedAt = DateTime.now();
    notifyListeners();
    unawaited(_queueSave());
    try {
      final videoMatches = await _matchesProjectVideo().timeout(
        const Duration(seconds: 45),
        onTimeout: () => false,
      );
      if (!videoMatches) {
        throw const MobileAnalysisException('视频检查未通过或耗时过长，请重新选择可正常播放的原视频。');
      }
      if (generation != _analysisGeneration) return;
      progress = 0.02;
      progressMessage = '正在准备本地分析';
      notifyListeners();
      await for (final update in analysisEngine.analyze(
        video: project.video!,
        hoopRoi: project.hoopRoi!,
        netRoi: project.netRoi!,
        settings: project.settings,
      )) {
        if (generation != _analysisGeneration) break;
        stage = update.stage;
        progress = update.progress.clamp(0, 1);
        progressMessage = update.message;
        processedFrames = update.processedFrames;
        totalFrames = update.totalFrames;
        eta = update.eta;
        project = project.copyWith(candidates: update.candidates);
        final percent = (progress * 100).round();
        project = project.copyWith(
          lastAnalysisStatus: 'running',
          lastAnalysisProgressPercent: percent,
          lastAnalysisMessage: update.message,
        );
        if (percent == 100 || percent % 5 == 0) unawaited(_queueSave());
        notifyListeners();
      }
      if (generation != _analysisGeneration) return;
      stopwatch.stop();
      project = project.copyWith(
        lastAnalysisDurationMs: stopwatch.elapsedMilliseconds,
        lastAnalysisAt: DateTime.now(),
        lastAnalysisStatus: 'completed',
        lastAnalysisProgressPercent: 100,
        lastAnalysisMessage: '分析完成',
      );
      await _queueSave();
    } on Object catch (error) {
      if (generation != _analysisGeneration) return;
      stage = AnalysisStage.failed;
      errorMessage = error.toString();
      project = project.copyWith(
        lastAnalysisStatus: 'failed',
        lastAnalysisMessage: errorMessage,
      );
      unawaited(_queueSave());
      notifyListeners();
    } finally {
      stopwatch.stop();
      if (generation == _analysisGeneration) {
        analysing = false;
        analysisStartedAt = null;
        notifyListeners();
      }
    }
  }

  Future<void> cancelAnalysis() async {
    if (!analysing) return;
    _analysisGeneration++;
    await analysisEngine.cancel();
    analysing = false;
    analysisStartedAt = null;
    stage = AnalysisStage.cancelled;
    progressMessage = '分析已取消';
    project = project.copyWith(
      lastAnalysisStatus: 'cancelled',
      lastAnalysisMessage: progressMessage,
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void updateCandidate(Candidate candidate) {
    project = project.copyWith(
      candidates: project.candidates
          .map((item) => item.id == candidate.id ? candidate : item)
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  /// Applies an event-centered clip range to all or selected candidates.
  /// Manually edited ranges are preserved unless explicitly overwritten.
  int applyBatchClipRange({
    required int beforeSeconds,
    required int afterSeconds,
    Iterable<String>? candidateIds,
    bool overwriteManual = false,
  }) {
    final video = project.video;
    if (video == null) return 0;
    final ids = candidateIds?.toSet();
    var updated = 0;
    final beforeMs = beforeSeconds.clamp(0, 3600) * 1000;
    final afterMs = afterSeconds.clamp(0, 3600) * 1000;
    final candidates = project.candidates.map((candidate) {
      if (ids != null && !ids.contains(candidate.id)) return candidate;
      if (candidate.rangeEdited && !overwriteManual) return candidate;
      final start = (candidate.eventMs - beforeMs)
          .clamp(0, video.durationMs)
          .toInt();
      final end = (candidate.eventMs + afterMs)
          .clamp(0, video.durationMs)
          .toInt();
      if (end <= start) return candidate;
      updated++;
      return candidate.copyWith(startMs: start, endMs: end, rangeEdited: false);
    }).toList();
    if (updated == 0) return 0;
    project = project.copyWith(candidates: candidates);
    unawaited(_queueSave());
    notifyListeners();
    return updated;
  }

  void updateCandidateNote(String id, String? note) {
    project = project.copyWith(
      candidates: project.candidates
          .map(
            (item) => item.id == id
                ? item.copyWith(
                    note: note,
                    clearNote: note == null || note.trim().isEmpty,
                  )
                : item,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }
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
