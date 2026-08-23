import 'dart:async';
import 'dart:convert';
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

  bool get hasVideo => project.video != null;
  bool get sourceVideoExists => project.video != null && File(project.video!.path).existsSync();

  Future<Directory> _dataDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/BHE Mobile');
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> _sha256(File file) async {
    const sampleSize = 1024 * 1024;
    final handle = await file.open();
    try {
      final length = await handle.length();
      final first = await handle.read(length < sampleSize ? length : sampleSize);
      if (length > sampleSize) await handle.setPosition(length - sampleSize);
      final last = length > sampleSize ? await handle.read(sampleSize) : const <int>[];
      return sha256.convert([...first, ...last, ...utf8.encode('$length')]).toString();
    } finally {
      await handle.close();
    }
  }

  Future<bool> _matchesProjectVideo() async {
    final expected = project.video;
    if (expected == null) return false;
    final file = File(expected.path);
    if (!await file.exists()) return false;
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      final actual = controller.value;
      if (actual.size.width.round() != expected.width ||
          actual.size.height.round() != expected.height ||
          (actual.duration.inMilliseconds - expected.durationMs).abs() > 1500) {
        return false;
      }
      if (expected.sha256 != null && await _sha256(file) != expected.sha256) return false;
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
      final file = File('${directory.path}/project.bhe.json');
      if (await file.exists()) {
        project = const ProjectPackageCodec().decode(await file.readAsString());
        if (project.lastAnalysisStatus == 'running') {
          project = project.copyWith(
            lastAnalysisStatus: 'interrupted',
            lastAnalysisMessage: '应用上次退出时分析未完成，可重新分析。',
          );
          await _queueSave();
        }
      }
    } on Object catch (error) {
      errorMessage = '读取本地项目失败：$error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _writeProject(ProjectSnapshot snapshot) async {
    final directory = await _dataDirectory();
    final file = File('${directory.path}/project.bhe.json');
    await file.writeAsString(const ProjectPackageCodec().encode(snapshot));
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
      project = project.copyWith(
        name: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        video: VideoInfo(
          path: path,
          name: name,
          sizeBytes: await file.length(),
          durationMs: value.duration.inMilliseconds,
          width: value.size.width.round(),
          height: value.size.height.round(),
          sha256: await _sha256(file),
        ),
        clearHoopRoi: true,
        clearNetRoi: true,
        candidates: const [],
        clearLastAnalysis: true,
      );
      errorMessage = null;
      await _queueSave();
      notifyListeners();
    } finally {
      await controller.dispose();
    }
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
              (previous.durationMs - value.duration.inMilliseconds).abs() > 1500)) {
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
    project = ProjectSnapshot(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: '新项目',
      video: null,
    );
    stage = AnalysisStage.idle;
    errorMessage = null;
    final directory = await _dataDirectory();
    for (final name in ['project.bhe.json', 'project.bhe']) {
      final file = File('${directory.path}/$name');
      if (await file.exists()) await file.delete();
    }
    for (final name in ['exports', 'package_staging']) {
      final artifactDirectory = Directory('${directory.path}/$name');
      if (await artifactDirectory.exists()) await artifactDirectory.delete(recursive: true);
    }
    notifyListeners();
  }

  void toggleCandidate(String id, CandidateSelection selection) {
    project = project.copyWith(
      candidates: project.candidates
          .map((candidate) => candidate.id == id
              ? candidate.copyWith(selection: selection)
              : candidate)
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void setCandidatePlayer(String id, String? player) {
    project = project.copyWith(
      candidates: project.candidates
          .map((candidate) => candidate.id == id
              ? candidate.copyWith(player: player, clearPlayer: player == null)
              : candidate)
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

  Future<void> exportProjectPackage() async {
    final directory = await _dataDirectory();
    final staging = Directory('${directory.path}/package_staging');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final projectJson = File('${staging.path}/project.json');
    await projectJson.writeAsString(const ProjectPackageCodec().encode(project));
    final file = File('${directory.path}/${project.name}.bhe');
    final encoder = ZipFileEncoder()..create(file.path, level: ZipFileEncoder.store);
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
        .where((candidate) => candidate.selection == CandidateSelection.included)
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
        outputDirectory: '${directory.path}/exports',
      )) {
        progress = update.progress;
        progressMessage = update.message;
        if (update.outputPath != null) exportedPaths = [...exportedPaths, update.outputPath!];
        notifyListeners();
      }
      project = project.copyWith(lastExportDurationMs: stopwatch.elapsedMilliseconds);
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
    await SharePlus.instance.share(ShareParams(files: exportedPaths.map(XFile.new).toList()));
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
    if (!await _matchesProjectVideo()) {
      errorMessage = '当前原视频不可用或与项目记录不一致，请重新选择原视频。';
      notifyListeners();
      return;
    }
    stage = AnalysisStage.validateInput;
    progress = 0;
    progressMessage = '正在准备本地分析';
    analysing = true;
    errorMessage = null;
    project = project.copyWith(candidates: const []);
    project = project.copyWith(
      lastAnalysisStatus: 'running',
      lastAnalysisProgressPercent: 0,
      lastAnalysisMessage: progressMessage,
    );
    await _queueSave();
    final stopwatch = Stopwatch()..start();
    final generation = ++_analysisGeneration;
    notifyListeners();
    try {
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
        notifyListeners();
      }
    }
  }

  Future<void> cancelAnalysis() async {
    if (!analysing) return;
    _analysisGeneration++;
    await analysisEngine.cancel();
    analysing = false;
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

  void updateCandidateNote(String id, String? note) {
    project = project.copyWith(
      candidates: project.candidates
          .map((item) => item.id == id
              ? item.copyWith(note: note, clearNote: note == null || note.trim().isEmpty)
              : item)
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }
}

class BheMobileApp extends StatefulWidget {
  const BheMobileApp({super.key});

  @override
  State<BheMobileApp> createState() => _BheMobileAppState();
}

class _BheMobileAppState extends State<BheMobileApp> {
  final state = MobileAppState();
  int tab = 0;

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'BHE',
          theme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xfff08c46),
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xff111315),
            useMaterial3: true,
          ),
          home: Scaffold(
            body: SafeArea(child: _body()),
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (value) => setState(() => tab = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: '项目'),
                NavigationDestination(icon: Icon(Icons.rate_review_outlined), selectedIcon: Icon(Icons.rate_review), label: '审核'),
                NavigationDestination(icon: Icon(Icons.ios_share_outlined), selectedIcon: Icon(Icons.ios_share), label: '导出'),
              ],
            ),
          ),
        ),
      );

  Widget _body() {
    if (state.loading) return const Center(child: CircularProgressIndicator());
    if (tab == 1) return ReviewPage(state: state);
    if (tab == 2) return ExportPage(state: state);
    return ProjectPage(state: state, onOpenReview: () => setState(() => tab = 1));
  }
}

class ProjectPage extends StatelessWidget {
  const ProjectPage({required this.state, required this.onOpenReview, super.key});
  final MobileAppState state;
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        children: [
          Row(children: [
            Expanded(child: Text('BHE', style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700))),
            IconButton(onPressed: state.importProject, icon: const Icon(Icons.file_open_outlined), tooltip: '打开项目包'),
            IconButton(onPressed: () => _confirmReset(context), icon: const Icon(Icons.delete_outline), tooltip: '删除当前项目'),
          ]),
          Text('Basketball Highlight Editor', style: TextStyle(color: Colors.grey.shade400)),
          const SizedBox(height: 24),
          if (!state.hasVideo)
            _EmptyVideo(onPick: state.pickVideo)
          else if (!state.sourceVideoExists)
            _MissingVideo(onRelink: state.relinkVideo)
          else
            _ProjectSetup(state: state, onOpenReview: onOpenReview),
      ],
    );

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除当前项目？'),
        content: const Text('项目设置、候选审核状态和本地记录都会删除，原视频文件不会受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) await state.clearProject();
  }
}

class _MissingVideo extends StatelessWidget {
  const _MissingVideo({required this.onRelink});
  final VoidCallback onRelink;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.video_file_outlined, size: 42),
            const SizedBox(height: 16),
            Text('需要重新选择原视频', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('项目包只保存分析结果，不包含大视频文件。请选择同一段原视频后继续审核或分析。'),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: onRelink, icon: const Icon(Icons.folder_open), label: const Text('重新选择视频')),
          ]),
        ),
      );
}

class _EmptyVideo extends StatelessWidget {
  const _EmptyVideo({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.sports_basketball, size: 42),
            const SizedBox(height: 18),
            Text('创建第一个项目', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('选择比赛视频后，在手机本地完成篮筐标注、分析、审核和导出。'),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: onPick, icon: const Icon(Icons.video_library_outlined), label: const Text('选择视频')),
          ]),
        ),
      );
}

class _ProjectSetup extends StatelessWidget {
  const _ProjectSetup({required this.state, required this.onOpenReview});
  final MobileAppState state;
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) {
    final video = state.project.video!;
    final settings = state.project.settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(state.project.name, style: Theme.of(context).textTheme.headlineSmall)), IconButton(onPressed: state.pickVideo, icon: const Icon(Icons.swap_horiz), tooltip: '更换视频')]),
      Text('${video.width} × ${video.height} · ${_duration(video.durationMs)} · ${_size(video.sizeBytes)}', style: TextStyle(color: Colors.grey.shade400)),
      const SizedBox(height: 20),
      _Section(title: '分析设置', child: Column(children: [
        DropdownButtonFormField<AnalysisMode>(
          initialValue: settings.mode,
          decoration: const InputDecoration(labelText: '分析质量'),
          items: const [
            DropdownMenuItem(value: AnalysisMode.standard, child: Text('标准 · 640×480 / 3fps')),
            DropdownMenuItem(value: AnalysisMode.highQuality, child: Text('高质量 · 960×720 / 5fps')),
          ],
          onChanged: (value) {
            if (value != null) state.updateSettings(AnalysisSettings(mode: value, clip: settings.clip, startMs: settings.startMs, endMs: settings.endMs));
          },
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _SecondsField(label: '进球前', value: settings.clip.beforeSeconds, onChanged: (value) => state.updateSettings(AnalysisSettings(mode: settings.mode, clip: ClipSettings(beforeSeconds: value, afterSeconds: settings.clip.afterSeconds), startMs: settings.startMs, endMs: settings.endMs)))),
          const SizedBox(width: 12),
          Expanded(child: _SecondsField(label: '进球后', value: settings.clip.afterSeconds, onChanged: (value) => state.updateSettings(AnalysisSettings(mode: settings.mode, clip: ClipSettings(beforeSeconds: settings.clip.beforeSeconds, afterSeconds: value), startMs: settings.startMs, endMs: settings.endMs)))),
        ]),
      ])),
      const SizedBox(height: 12),
      _Section(title: '篮筐区域', child: Row(children: [
        Expanded(child: Text(state.project.hoopRoi == null ? '尚未设置，将在分析前配置' : '已设置篮筐与篮网区域')),
        TextButton(onPressed: () => _showRoiDialog(context), child: Text(state.project.hoopRoi == null ? '设置' : '调整')),
      ])),
      const SizedBox(height: 18),
      if (state.project.lastAnalysisDurationMs != null) ...[
        Text('上次分析：${_duration(state.project.lastAnalysisDurationMs!)}${state.project.lastAnalysisAt == null ? '' : ' · ${_dateTime(state.project.lastAnalysisAt!)}'}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 10),
      ],
      if (state.project.lastAnalysisStatus == 'interrupted')
        const _InfoBox(message: '上次分析没有完成，可以直接点击“重新分析”。'),
      if (state.project.lastAnalysisStatus == 'failed')
        _InfoBox(message: '上次分析失败：${state.project.lastAnalysisMessage ?? '请检查视频和检测区域后重试。'}'),
      if (state.project.lastAnalysisStatus == 'cancelled')
        const _InfoBox(message: '上次分析已取消，可以重新开始分析。'),
      if (state.errorMessage != null) _ErrorBox(message: state.errorMessage!),
      if (state.analysing) ...[
        LinearProgressIndicator(value: state.progress),
        const SizedBox(height: 8),
        Text(state.progressMessage),
        if (state.processedFrames != null && state.totalFrames != null)
          Text('${state.processedFrames} / ${state.totalFrames} 帧'),
        if (state.eta != null) Text('预计还需 ${_duration(state.eta!.inMilliseconds)}'),
        TextButton(onPressed: state.cancelAnalysis, child: const Text('取消分析')),
      ] else
        FilledButton.icon(onPressed: state.startAnalysis, icon: const Icon(Icons.play_arrow), label: Text(state.project.candidates.isEmpty ? '开始本地分析' : '重新分析')),
      if (state.project.candidates.isNotEmpty) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: onOpenReview, icon: const Icon(Icons.rate_review_outlined), label: Text('审核 ${state.project.candidates.length} 个候选')),
      ],
    ]);
  }

  Future<void> _showRoiDialog(BuildContext context) async {
    final result = await showDialog<({Roi hoop, Roi net})>(
      context: context,
      builder: (_) => _RoiDialog(videoPath: state.project.video!.path, hoop: state.project.hoopRoi, net: state.project.netRoi),
    );
    if (result != null) state.updateRois(hoop: result.hoop, net: result.net);
  }
}

class _RoiDialog extends StatefulWidget {
  const _RoiDialog({required this.videoPath, this.hoop, this.net});
  final String videoPath;
  final Roi? hoop;
  final Roi? net;
  @override
  State<_RoiDialog> createState() => _RoiDialogState();
}

class _RoiDialogState extends State<_RoiDialog> {
  late Roi hoop = widget.hoop ?? const Roi(left: .25, top: .25, right: .75, bottom: .58);
  late Roi net = widget.net ?? const Roi(left: .25, top: .58, right: .75, bottom: .82);
  String active = 'hoop';
  VideoPlayerController? controller;
  bool ready = false;
  String? dragHandle;

  @override
  void initState() {
    super.initState();
    controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        if (mounted) setState(() => ready = true);
      });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  Roi get current => active == 'hoop' ? hoop : net;

  void move(Offset delta, Size size) {
    final roi = current;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    final width = roi.right - roi.left;
    final height = roi.bottom - roi.top;
    final left = (roi.left + dx).clamp(0.0, 1.0 - width);
    final top = (roi.top + dy).clamp(0.0, 1.0 - height);
    final next = Roi(left: left, top: top, right: left + width, bottom: top + height);
    setState(() => active == 'hoop' ? hoop = next : net = next);
  }

  String? _handleAt(Offset point, Size size) {
    final roi = current;
    final corners = <String, Offset>{
      'topLeft': Offset(roi.left * size.width, roi.top * size.height),
      'topRight': Offset(roi.right * size.width, roi.top * size.height),
      'bottomLeft': Offset(roi.left * size.width, roi.bottom * size.height),
      'bottomRight': Offset(roi.right * size.width, roi.bottom * size.height),
    };
    for (final entry in corners.entries) {
      if ((entry.value - point).distance <= 22) return entry.key;
    }
    return null;
  }

  void resize(Offset delta, Size size) {
    final roi = current;
    var left = roi.left;
    var top = roi.top;
    var right = roi.right;
    var bottom = roi.bottom;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    if (dragHandle?.contains('Left') == true) left = (left + dx).clamp(0.0, right - .05);
    if (dragHandle?.contains('Right') == true) right = (right + dx).clamp(left + .05, 1.0);
    if (dragHandle?.contains('top') == true) top = (top + dy).clamp(0.0, bottom - .05);
    if (dragHandle?.contains('bottom') == true) bottom = (bottom + dy).clamp(top + .05, 1.0);
    final next = Roi(left: left, top: top, right: right, bottom: bottom);
    setState(() => active == 'hoop' ? hoop = next : net = next);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('设置检测区域'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('拖动画面中的区域；橙色是篮筐，蓝色是篮网。'),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'hoop', label: Text('篮筐')),
                ButtonSegment(value: 'net', label: Text('篮网')),
              ],
              selected: {active},
              onSelectionChanged: (value) => setState(() => active = value.first),
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: ready && controller != null ? controller!.value.aspectRatio : 16 / 9,
              child: LayoutBuilder(builder: (context, constraints) => GestureDetector(
                onPanStart: (details) => dragHandle = _handleAt(details.localPosition, constraints.biggest),
                onPanUpdate: (details) => dragHandle == null ? move(details.delta, constraints.biggest) : resize(details.delta, constraints.biggest),
                onPanEnd: (_) => dragHandle = null,
                child: Stack(fit: StackFit.expand, children: [
                  if (ready && controller != null) VideoPlayer(controller!) else const ColoredBox(color: Color(0xff202326), child: Center(child: CircularProgressIndicator())),
                  CustomPaint(painter: _RoiPainter(hoop: hoop, net: net, active: active)),
                ]),
              )),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, (hoop: hoop, net: net)), child: const Text('完成')),
        ],
      );
}

class _RoiPainter extends CustomPainter {
  const _RoiPainter({required this.hoop, required this.net, required this.active});
  final Roi hoop;
  final Roi net;
  final String active;

  @override
  void paint(Canvas canvas, Size size) {
    void draw(Roi roi, Color color, String label) {
      final rect = Rect.fromLTRB(roi.left * size.width, roi.top * size.height, roi.right * size.width, roi.bottom * size.height);
      final paint = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = active == label ? 3 : 2;
      canvas.drawRect(rect, paint);
      canvas.drawRect(rect.inflate(1), paint..color = color.withValues(alpha: .18)..style = PaintingStyle.fill);
      if (active == label) {
        final handlePaint = Paint()..color = color..style = PaintingStyle.fill;
        for (final point in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
          canvas.drawCircle(point, 5, handlePaint);
        }
      }
    }
    draw(hoop, const Color(0xffffa35c), 'hoop');
    draw(net, const Color(0xff6fb1ff), 'net');
  }

  @override
  bool shouldRepaint(_RoiPainter oldDelegate) => oldDelegate.hoop != hoop || oldDelegate.net != net || oldDelegate.active != active;
}

class ReviewPage extends StatefulWidget {
  const ReviewPage({required this.state, super.key});
  final MobileAppState state;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  VideoPlayerController? controller;
  int selectedIndex = 0;
  bool initialised = false;
  double playbackSpeed = 1;
  int _controllerGeneration = 0;
  String? _openedVideoPath;

  MobileAppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _openVideo();
  }

  @override
  void didUpdateWidget(covariant ReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_openedVideoPath != widget.state.project.video?.path) _openVideo();
  }

  Future<void> _openVideo() async {
    final generation = ++_controllerGeneration;
    final path = state.project.video?.path;
    if (path == null || !File(path).existsSync()) return;
    final next = VideoPlayerController.file(File(path));
    await next.initialize();
    if (!mounted || generation != _controllerGeneration) {
      await next.dispose();
      return;
    }
    final previous = controller;
    next.addListener(_videoChanged);
    await previous?.dispose();
    if (!mounted || generation != _controllerGeneration) {
      await next.dispose();
      return;
    }
    setState(() {
      controller = next;
      initialised = true;
      _openedVideoPath = path;
    });
    if (state.project.candidates.isNotEmpty) {
      await _replay(state.project.candidates.first);
    }
  }

  @override
  void dispose() {
    controller?.removeListener(_videoChanged);
    controller?.dispose();
    super.dispose();
  }

  void _videoChanged() {
    final value = controller?.value;
    final candidate = selected;
    if (value != null && candidate != null && value.position.inMilliseconds >= candidate.endMs && value.isPlaying) {
      controller?.pause();
    }
    if (mounted) setState(() {});
  }

  Candidate? get selected {
    if (state.project.candidates.isEmpty) return null;
    return state.project.candidates[selectedIndex.clamp(0, state.project.candidates.length - 1)];
  }

  Future<void> _select(int index) async {
    if (index < 0 || index >= state.project.candidates.length) return;
    setState(() => selectedIndex = index);
    await controller?.seekTo(Duration(milliseconds: state.project.candidates[index].startMs));
    await controller?.play();
  }

  Future<void> _replay(Candidate candidate) async {
    await controller?.seekTo(Duration(milliseconds: candidate.startMs));
    await controller?.play();
    if (mounted) setState(() {});
  }

  Future<void> _showPlayerDialog(Candidate candidate) async {
    final controller = TextEditingController(text: candidate.player ?? '');
    final player = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('球员标签'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '例如：#10 Kobe'),
              onChanged: (_) => setDialogState(() {}),
            ),
            if (state.project.players.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text('已有标签'),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: state.project.players.map((player) => ActionChip(label: Text(player), onPressed: () { controller.text = player; setDialogState(() {}); })).toList()),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            if (candidate.player != null) TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('清除')),
            FilledButton(onPressed: controller.text.trim().isEmpty ? null : () => Navigator.pop(context, controller.text.trim()), child: const Text('保存')),
          ],
        ),
      ),
    );
    controller.dispose();
    if (player != null) {
      state.setCandidatePlayer(candidate.id, player.isEmpty ? null : player);
      if (player.isNotEmpty) state.addPlayer(player);
    }
  }

  Future<void> _showNoteDialog(Candidate candidate) async {
    final noteController = TextEditingController(text: candidate.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('候选备注'),
        content: TextField(
          controller: noteController,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '记录这段视频的说明'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, noteController.text), child: const Text('保存')),
        ],
      ),
    );
    noteController.dispose();
    if (note != null) state.updateCandidateNote(candidate.id, note);
  }

  Future<void> _showRangeDialog(Candidate candidate) async {
    final duration = controller?.value.duration.inMilliseconds ?? state.project.video?.durationMs ?? candidate.endMs;
    var start = candidate.startMs.toDouble();
    var end = candidate.endMs.toDouble();
    final result = await showDialog<({int start, int end})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('调整片段范围'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${_duration(start.round())} — ${_duration(end.round())}'),
            RangeSlider(
              min: 0,
              max: duration.toDouble().clamp(1, double.infinity),
              values: RangeValues(start, end),
              labels: RangeLabels(_duration(start.round()), _duration(end.round())),
              onChanged: (values) {
                if (values.end - values.start < 500) return;
                setDialogState(() { start = values.start; end = values.end; });
              },
            ),
            const Text('拖动两端调整开始和结束时间', style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, (start: start.round(), end: end.round())), child: const Text('完成')),
          ],
        ),
      ),
    );
    if (result != null) {
      state.updateCandidate(candidate.copyWith(startMs: result.start, endMs: result.end));
      await controller?.seekTo(Duration(milliseconds: result.start));
    }
  }

  void _togglePlayback() {
    final player = controller;
    if (player == null) return;
    if (player.value.isPlaying) {
      player.pause();
    } else {
      player.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final candidate = selected;
    if (candidate == null) return const Center(child: Text('分析完成后，候选片段会显示在这里。'));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      children: [
        Text('审核', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        _ReviewPlayer(
          controller: controller,
          initialised: initialised,
          candidate: candidate,
          onTap: _togglePlayback,
          onSwipe: (delta) => _select(selectedIndex + (delta < 0 ? 1 : -1)),
        ),
        if (controller != null && initialised) ...[
          VideoProgressIndicator(controller!, allowScrubbing: true, padding: EdgeInsets.zero, colors: VideoProgressColors(playedColor: Theme.of(context).colorScheme.primary)),
          Row(children: [
            Text(_duration(controller!.value.position.inMilliseconds), style: Theme.of(context).textTheme.labelSmall),
            const Spacer(),
            DropdownButton<double>(value: playbackSpeed, underline: const SizedBox.shrink(), items: const <double>[0.5, 1, 1.25, 1.5, 2].map((value) => DropdownMenuItem<double>(value: value, child: Text('${value}x'))).toList(), onChanged: (value) { if (value != null) { setState(() => playbackSpeed = value); controller!.setPlaybackSpeed(value); } }),
            IconButton(onPressed: () => _replay(candidate), icon: const Icon(Icons.replay), tooltip: '重播'),
          ]),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => state.toggleCandidate(candidate.id, CandidateSelection.included), icon: const Icon(Icons.check), label: const Text('保留'))),
          const SizedBox(width: 12),
          Expanded(child: OutlinedButton.icon(onPressed: () => state.toggleCandidate(candidate.id, CandidateSelection.excluded), icon: const Icon(Icons.close), label: const Text('排除'))),
        ]),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: () => _showPlayerDialog(candidate), icon: const Icon(Icons.person_outline), label: Text(candidate.player == null ? '添加球员标签' : candidate.player!)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: () => _showRangeDialog(candidate), icon: const Icon(Icons.content_cut), label: const Text('调整片段范围'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: () => _showNoteDialog(candidate), icon: const Icon(Icons.notes_outlined), label: Text(candidate.note == null ? '添加备注' : '编辑备注'))),
        ]),
        const SizedBox(height: 10),
        _CandidateDetails(candidate: candidate),
        const SizedBox(height: 18),
        Text('候选片段', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...List.generate(state.project.candidates.length, (index) => _CandidateTile(state: state, candidate: state.project.candidates[index], selected: index == selectedIndex, onTap: () => _select(index))),
      ],
    );
  }
}

class _ReviewPlayer extends StatelessWidget {
  const _ReviewPlayer({required this.controller, required this.initialised, required this.candidate, required this.onTap, required this.onSwipe});
  final VideoPlayerController? controller;
  final bool initialised;
  final Candidate candidate;
  final VoidCallback onTap;
  final ValueChanged<double> onSwipe;

  @override
  Widget build(BuildContext context) {
    final player = controller;
    return AspectRatio(
      aspectRatio: player != null && initialised ? player.value.aspectRatio : 16 / 9,
      child: GestureDetector(
        onTap: onTap,
        onVerticalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity.abs() > 200) onSwipe(velocity);
        },
        child: Stack(fit: StackFit.expand, children: [
          if (player != null && initialised) VideoPlayer(player) else const ColoredBox(color: Color(0xff202326), child: Center(child: CircularProgressIndicator())),
          Align(alignment: Alignment.bottomLeft, child: Container(margin: const EdgeInsets.all(12), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), color: Colors.black54, child: Text('${_duration(candidate.eventMs)} · ${_duration(candidate.endMs - candidate.startMs)}'))),
        ]),
      ),
    );
  }
}

class _CandidateDetails extends StatelessWidget {
  const _CandidateDetails({required this.candidate});
  final Candidate candidate;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _Metric(label: '置信度', value: '${(candidate.confidence * 100).round()}%'),
              if (candidate.trajectoryScore != null) _Metric(label: '轨迹', value: _score(candidate.trajectoryScore!)),
              if (candidate.crossingScore != null) _Metric(label: '穿框', value: _score(candidate.crossingScore!)),
              if (candidate.netMotionScore != null) _Metric(label: '篮网运动', value: _score(candidate.netMotionScore!)),
              _Metric(label: '状态', value: candidate.selection == CandidateSelection.included ? '保留' : '排除'),
            ],
          ),
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Text(label, style: Theme.of(context).textTheme.labelSmall), Text(value, style: Theme.of(context).textTheme.titleSmall)]);
}

String _score(double value) => '${(value * 100).round()}%';

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.state, required this.candidate, required this.selected, required this.onTap});
  final MobileAppState state;
  final Candidate candidate;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        color: selected ? Theme.of(context).colorScheme.surfaceContainerHighest : null,
        child: ListTile(
          onTap: onTap,
          leading: CircleAvatar(child: Text(candidate.id.replaceAll(RegExp(r'\D'), '').padLeft(2, '0'))),
          title: Text('${_duration(candidate.eventMs)} · ${_duration(candidate.endMs - candidate.startMs)}'),
          subtitle: Text([
            '置信度 ${(candidate.confidence * 100).round()}%',
            if (candidate.player != null) candidate.player!,
            if (candidate.note != null && candidate.note!.trim().isNotEmpty) candidate.note!,
          ].join(' · ')),
          trailing: SegmentedButton<CandidateSelection>(
            segments: const [
              ButtonSegment(value: CandidateSelection.included, icon: Icon(Icons.check), label: Text('保留')),
              ButtonSegment(value: CandidateSelection.excluded, icon: Icon(Icons.close), label: Text('排除')),
            ],
            selected: {candidate.selection},
            onSelectionChanged: (value) => state.toggleCandidate(candidate.id, value.first),
          ),
        ),
      );
}

class ExportPage extends StatelessWidget {
  const ExportPage({required this.state, super.key});
  final MobileAppState state;

  @override
  Widget build(BuildContext context) {
    final included = state.project.candidates.where((c) => c.selection == CandidateSelection.included).length;
    final players = state.project.players.toSet()..addAll(state.project.candidates.map((candidate) => candidate.player).whereType<String>());
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('导出', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$included 个候选片段可导出'),
        const SizedBox(height: 6),
        const Text('视频始终在本机处理。项目包只保存结果，不包含原视频。'),
        const SizedBox(height: 16),
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.icon(onPressed: included == 0 || state.exporting ? null : state.exportClips, icon: const Icon(Icons.movie_creation_outlined), label: Text(state.exporting ? '正在导出…' : '导出片段')),
          OutlinedButton.icon(onPressed: state.exportProjectPackage, icon: const Icon(Icons.ios_share), label: const Text('分享项目包')),
        ]),
        if (players.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('按球员导出', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: players.map((player) => ActionChip(label: Text(player), onPressed: state.exporting ? null : () => state.exportClipsForPlayer(player))).toList()),
        ],
        if (state.progressMessage.isNotEmpty) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: state.progress == 0 ? null : state.progress),
          const SizedBox(height: 6),
          Text(state.progressMessage),
          if (state.project.lastExportDurationMs != null && !state.exporting)
            Text('上次导出耗时 ${_duration(state.project.lastExportDurationMs!)}', style: Theme.of(context).textTheme.bodySmall),
        ],
        if (state.exportedPaths.isNotEmpty && !state.exporting) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: state.saveExportedFiles, icon: const Icon(Icons.photo_library_outlined), label: const Text('保存到相册')),
            OutlinedButton.icon(onPressed: state.shareExportedFiles, icon: const Icon(Icons.share_outlined), label: Text('分享 ${state.exportedPaths.length} 个片段')),
          ]),
        ],
        if (state.errorMessage != null) ...[const SizedBox(height: 12), _ErrorBox(message: state.errorMessage!)],
      ]))),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 14), child])));
}

class _SecondsField extends StatelessWidget {
  const _SecondsField({required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<int>(initialValue: value, decoration: InputDecoration(labelText: '$label（秒）'), items: const [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15].map((v) => DropdownMenuItem(value: v, child: Text('$v 秒'))).toList(), onChanged: (v) { if (v != null) onChanged(v); });
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)), child: Text(message));
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(message),
      );
}

String _duration(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _dateTime(DateTime value) => '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _readProjectFromArchive(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final project = archive.files.cast<ArchiveFile?>().firstWhere(
        (file) => file?.name == 'project.json',
        orElse: () => null,
      );
  if (project == null) throw const FormatException('项目包缺少 project.json');
  return utf8.decode(project.readBytes() ?? const <int>[]);
}

String _size(int bytes) {
  if (bytes > 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}
