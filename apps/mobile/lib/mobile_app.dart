import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

class MobileAppState extends ChangeNotifier {
  MobileAppState() {
    unawaited(loadSavedProject());
  }

  ProjectSnapshot project = ProjectSnapshot(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: '新项目',
    video: null,
  );
  AnalysisStage stage = AnalysisStage.idle;
  String? errorMessage;
  bool loading = true;

  bool get hasVideo => project.video != null;

  Future<Directory> _dataDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/BHE Mobile');
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> loadSavedProject() async {
    try {
      final directory = await _dataDirectory();
      final file = File('${directory.path}/project.bhe.json');
      if (await file.exists()) {
        project = const ProjectPackageCodec().decode(await file.readAsString());
      }
    } on Object catch (error) {
      errorMessage = '读取本地项目失败：$error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    final directory = await _dataDirectory();
    final file = File('${directory.path}/project.bhe.json');
    await file.writeAsString(const ProjectPackageCodec().encode(project));
  }

  Future<void> pickVideo() async {
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
        ),
      );
      errorMessage = null;
      await _save();
      notifyListeners();
    } finally {
      await controller.dispose();
    }
  }

  Future<void> importProject() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      project = const ProjectPackageCodec().decode(await File(path).readAsString());
      errorMessage = null;
      await _save();
      notifyListeners();
    } on Object catch (error) {
      errorMessage = '项目包无法打开：$error';
      notifyListeners();
    }
  }

  void updateSettings(AnalysisSettings settings) {
    project = project.copyWith(settings: settings);
    unawaited(_save());
    notifyListeners();
  }

  void updateRoi(Roi roi) {
    project = project.copyWith(
      hoopRoi: roi,
      netRoi: Roi(
        left: roi.left,
        top: (roi.top + .06).clamp(0, 1),
        right: roi.right,
        bottom: (roi.bottom + .18).clamp(0, 1),
      ),
    );
    unawaited(_save());
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
    unawaited(_save());
    notifyListeners();
  }

  Future<void> exportProjectPackage() async {
    final directory = await _dataDirectory();
    final file = File('${directory.path}/${project.name}.bhe.json');
    await file.writeAsString(const ProjectPackageCodec().encode(project));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  Future<void> startAnalysis() async {
    if (!hasVideo) return;
    errorMessage = '移动端本地分析引擎尚未接入。视频、项目、设置和审核工作台已可使用，下一步接入 ONNX/Rust 推理核心。';
    stage = AnalysisStage.failed;
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
          ]),
          Text('Basketball Highlight Editor', style: TextStyle(color: Colors.grey.shade400)),
          const SizedBox(height: 24),
          if (!state.hasVideo) _EmptyVideo(onPick: state.pickVideo) else _ProjectSetup(state: state, onOpenReview: onOpenReview),
        ],
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
          value: settings.mode,
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
      if (state.errorMessage != null) _ErrorBox(message: state.errorMessage!),
      FilledButton.icon(onPressed: state.startAnalysis, icon: const Icon(Icons.play_arrow), label: const Text('开始本地分析')),
      if (state.project.candidates.isNotEmpty) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: onOpenReview, icon: const Icon(Icons.rate_review_outlined), label: Text('审核 ${state.project.candidates.length} 个候选')),
      ],
    ]);
  }

  Future<void> _showRoiDialog(BuildContext context) async {
    final roi = await showDialog<Roi>(context: context, builder: (_) => const _RoiDialog());
    if (roi != null) state.updateRoi(roi);
  }
}

class _RoiDialog extends StatefulWidget {
  const _RoiDialog();
  @override
  State<_RoiDialog> createState() => _RoiDialogState();
}

class _RoiDialogState extends State<_RoiDialog> {
  double left = .25, top = .25, right = .75, bottom = .58;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('设置篮筐区域'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('先用近似区域开始，后续可继续微调。'),
          const SizedBox(height: 12),
          _SliderRow(label: '左', value: left, onChanged: (v) => setState(() => left = v)),
          _SliderRow(label: '上', value: top, onChanged: (v) => setState(() => top = v)),
          _SliderRow(label: '右', value: right, onChanged: (v) => setState(() => right = v)),
          _SliderRow(label: '下', value: bottom, onChanged: (v) => setState(() => bottom = v)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, Roi(left: left, top: top, right: right, bottom: bottom)), child: const Text('完成')),
        ],
      );
}

class ReviewPage extends StatelessWidget {
  const ReviewPage({required this.state, super.key});
  final MobileAppState state;

  @override
  Widget build(BuildContext context) => state.project.candidates.isEmpty
      ? const Center(child: Text('分析完成后，候选片段会显示在这里。'))
      : ListView(padding: const EdgeInsets.all(16), children: [
          Text('审核', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          ...state.project.candidates.map((candidate) => _CandidateTile(state: state, candidate: candidate)),
        ]);
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.state, required this.candidate});
  final MobileAppState state;
  final Candidate candidate;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: CircleAvatar(child: Text(candidate.id.replaceAll(RegExp(r'\D'), '').padLeft(2, '0'))),
          title: Text('${_duration(candidate.eventMs)} · ${_duration(candidate.endMs - candidate.startMs)}'),
          subtitle: Text('置信度 ${(candidate.confidence * 100).round()}%${candidate.player == null ? '' : ' · ${candidate.player}'}'),
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
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('导出', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      Card(child: ListTile(title: Text('$included 个候选片段可导出'), subtitle: const Text('项目包不包含原视频，视频始终留在本机。'), trailing: FilledButton(onPressed: state.exportProjectPackage, child: const Text('分享项目包')))),
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
  Widget build(BuildContext context) => DropdownButtonFormField<int>(value: value, decoration: InputDecoration(labelText: '$label（秒）'), items: const [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15].map((v) => DropdownMenuItem(value: v, child: Text('$v 秒'))).toList(), onChanged: (v) { if (v != null) onChanged(v); });
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.label, required this.value, required this.onChanged});
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Row(children: [SizedBox(width: 30, child: Text(label)), Expanded(child: Slider(value: value, min: 0, max: 1, onChanged: onChanged)), Text(value.toStringAsFixed(2))]);
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(12), margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)), child: Text(message));
}

String _duration(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _size(int bytes) {
  if (bytes > 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}
