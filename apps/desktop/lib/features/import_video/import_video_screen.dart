import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_step_indicator.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Import 屏:选择视频 → 框选 ROI → 开始分析。
///
/// 数据来自 [projectProvider];ROI pan state 由本组件持有,
/// 选视频后用 `state.suggestedRoi` 作为初始值。
class ImportVideoScreen extends ConsumerStatefulWidget {
  const ImportVideoScreen({super.key});

  @override
  ConsumerState<ImportVideoScreen> createState() => _ImportVideoScreenState();
}

class _ImportVideoScreenState extends ConsumerState<ImportVideoScreen> {
  Rect? _roi;
  Rect? _netRoi;
  bool _roiSaved = false;
  bool _savingRoi = false;
  bool _roiUserEdited = false;
  bool _netUserEdited = false;
  bool _autoSavingRoi = false;
  bool _roiSaveQueued = false;
  bool _editingNet = false;
  int _analysisStartMs = 0;
  int _analysisEndMs = 0;

  @override
  void initState() {
    super.initState();
    final state = ref.read(projectProvider);
    _roi = state.suggestedRoi;
    _netRoi =
        _netRoiFromState(state) ?? _recommendedNetRoi(_roi, state.hoopBbox);
    _roiSaved = state.roiSource != null && state.suggestedRoi != null;
    _roiUserEdited = state.roiSource == 'manual';
    _analysisStartMs = _analysisStart(state);
    _analysisEndMs = _analysisEnd(state);
  }

  Future<void> _selectVideo() async {
    const typeGroup = XTypeGroup(
      label: '视频',
      extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file != null) {
      await ref.read(projectProvider.notifier).selectVideo(file.path);
    }
  }

  Future<void> _saveRoi({bool showNotice = true}) async {
    final roi = _roi;
    if (roi == null) return;
    setState(() => _savingRoi = true);
    try {
      final saved = await ref
          .read(projectProvider.notifier)
          .saveRoi(roi, netRoi: _netRoi, showNotice: showNotice);
      if (mounted && saved) setState(() => _roiSaved = true);
    } finally {
      if (mounted) setState(() => _savingRoi = false);
    }
  }

  Future<void> _autoSaveRoi() async {
    if (_autoSavingRoi) {
      _roiSaveQueued = true;
      return;
    }
    _autoSavingRoi = true;
    await _saveRoi(showNotice: false);
    _autoSavingRoi = false;
    if (_roiSaveQueued && mounted) {
      _roiSaveQueued = false;
      await _autoSaveRoi();
    }
  }

  Future<void> _startAnalysis() async {
    final started = await ref.read(projectProvider.notifier).startAnalysis();
    if (mounted && started) context.go('/review');
  }

  Future<void> _saveAnalysisRange(int startMs, int endMs) async {
    if (endMs <= startMs) return;
    await ref
        .read(projectProvider.notifier)
        .saveAnalysisRange(startMs, endMs, showNotice: false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    // 视频切换时重置 ROI 为引擎建议值。
    ref.listen<ProjectState>(projectProvider, (previous, next) {
      final videoChanged = previous?.videoPath != next.videoPath;
      final autoRoiChanged =
          previous?.suggestedRoi != next.suggestedRoi &&
          next.roiSource == 'auto';
      if (videoChanged || (autoRoiChanged && !_roiUserEdited)) {
        setState(() {
          _roi = next.suggestedRoi;
          if (videoChanged || !_netUserEdited) {
            _netRoi =
                _netRoiFromState(next) ??
                _recommendedNetRoi(_roi, next.hoopBbox);
          }
          _roiSaved = next.roiSource != null && next.suggestedRoi != null;
          if (videoChanged) {
            _roiUserEdited = false;
            _netUserEdited = false;
            _editingNet = false;
            _analysisStartMs = _analysisStart(next);
            _analysisEndMs = _analysisEnd(next);
          }
        });
      }
    });

    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final hasVideo = state.videoPath != null;
    final hasRoi = _roi != null;
    final width = (state.video?['width'] as num?)?.toDouble() ?? 16;
    final height = (state.video?['height'] as num?)?.toDouble() ?? 9;
    final roiBusy =
        state.busy ||
        state.exportRunning ||
        state.analysisRunning ||
        _savingRoi;

    final steps = <CsStep>[
      (
        index: '01',
        title: '选择原始视频',
        icon: LucideIcons.upload,
        completed: hasVideo,
      ),
      (
        index: '02',
        title: '框选篮筐区域',
        icon: LucideIcons.crop,
        completed: hasRoi && _roiSaved,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('新建分析项目', style: theme.textTheme.displayMedium),
              const SizedBox(height: Spacing.sm),
              Text(
                '选择原始视频，系统会优先自动定位篮筐，也可以手动调整检测区域。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.xl),

              CsCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CsStepIndicator(steps: steps),
                    const SizedBox(height: Spacing.xl),

                    // ── 视频选择行 ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(Spacing.md),
                      decoration: BoxDecoration(
                        color: c.surface2,
                        borderRadius: BorderRadius.circular(CsRadius.lg),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final path = Row(
                            children: [
                              Icon(
                                LucideIcons.film,
                                size: 18,
                                color: c.textSecondary,
                              ),
                              const SizedBox(width: Spacing.md),
                              Expanded(
                                child: SelectableText(
                                  state.videoPath ??
                                      '支持 MP4 / MOV / H.264 / H.265，原始视频不会被复制。',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: hasVideo
                                        ? c.textPrimary
                                        : c.textSecondary,
                                  ),
                                  maxLines: 2,
                                ),
                              ),
                            ],
                          );
                          final picker = CsButton(
                            label: Text(hasVideo ? '更换视频' : '选择视频'),
                            icon: LucideIcons.folderOpen,
                            variant: CsButtonVariant.secondary,
                            onPressed: roiBusy ? null : _selectVideo,
                          );
                          if (constraints.maxWidth < 520) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                path,
                                const SizedBox(height: Spacing.md),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: picker,
                                ),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: path),
                              const SizedBox(width: Spacing.md),
                              picker,
                            ],
                          );
                        },
                      ),
                    ),

                    // ── 视频信息行 ──
                    if (state.video != null) ...[
                      const SizedBox(height: Spacing.sm),
                      Text(
                        _videoSummary(state.video!),
                        style: numericTextStyle(
                          theme.textTheme.labelSmall!.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        _workspaceSummary(state.video!),
                        style: numericTextStyle(
                          theme.textTheme.labelSmall!.copyWith(
                            color:
                                state.video!['disk_space_sufficient'] == false
                                ? c.error
                                : c.textTertiary,
                          ),
                        ),
                      ),
                      const SizedBox(height: Spacing.md),
                      _AnalysisRangeEditor(
                        videoPath: state.videoPath,
                        durationMs:
                            (state.video!['duration_ms'] as num?)?.toInt() ?? 0,
                        startMs: _analysisStartMs,
                        endMs: _analysisEndMs,
                        enabled: !roiBusy,
                        onChanged: (start, end) => setState(() {
                          _analysisStartMs = start;
                          _analysisEndMs = end;
                        }),
                        onCommit: _saveAnalysisRange,
                      ),
                    ],

                    const SizedBox(height: Spacing.xl),

                    // ── ROI 提示 ──
                    if (state.roiDetecting) ...[
                      Row(
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: c.indigo,
                            ),
                          ),
                          const SizedBox(width: Spacing.sm),
                          Expanded(
                            child: Text(
                              '正在自动识别篮筐区域，完成后可以继续调整并保存。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Spacing.sm),
                    ] else if (state.roiSource == 'auto' && hasRoi) ...[
                      Row(
                        children: [
                          Icon(LucideIcons.sparkles, size: 14, color: c.indigo),
                          const SizedBox(width: Spacing.sm),
                          Expanded(
                            child: Text(
                              state.roiConfidence == null
                                  ? '已自动识别篮筐区域'
                                  : '已自动识别篮筐区域 · 置信度 '
                                        '${(state.roiConfidence! * 100).round()}%',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Spacing.sm),
                    ] else if (state.roiSuggestionError != null) ...[
                      Text(
                        '自动识别失败：${state.roiSuggestionError}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: c.error,
                        ),
                      ),
                      const SizedBox(height: Spacing.sm),
                    ],

                    // ── ROI 画布 ──
                    _RoiCanvas(
                      enabled: hasVideo && !roiBusy,
                      previewPath: state.previewPath,
                      aspectRatio: width > 0 && height > 0
                          ? width / height
                          : 16 / 9,
                      roi: _editingNet ? _netRoi : _roi,
                      secondaryRoi: _editingNet ? _roi : _netRoi,
                      activeColor: _editingNet ? Colors.white : c.indigo,
                      secondaryColor: _editingNet ? c.indigo : Colors.white,
                      activeLabel: _editingNet ? '篮网检测区' : '投篮分析区',
                      secondaryLabel: _editingNet ? '投篮分析区' : '篮网检测区',
                      onRefreshPreview: state.video != null && !roiBusy
                          ? () => ref
                                .read(projectProvider.notifier)
                                .refreshPreview()
                          : null,
                      onChanged: (value) => setState(() {
                        if (_editingNet) {
                          _netRoi = value;
                          _netUserEdited = true;
                        } else {
                          _roi = value;
                          _roiSaved = false;
                          _roiUserEdited = true;
                          if (!_netUserEdited) {
                            _netRoi = _recommendedNetRoi(value, state.hoopBbox);
                          }
                        }
                      }),
                      onEditComplete: () => unawaited(_autoSaveRoi()),
                    ),
                    const SizedBox(height: Spacing.md),

                    Text('校准检测区域', style: theme.textTheme.labelLarge),
                    const SizedBox(height: Spacing.xs),
                    Wrap(
                      spacing: Spacing.sm,
                      runSpacing: Spacing.xs,
                      children: [
                        _CalibrationTargetButton(
                          index: '1',
                          label: '投篮分析区',
                          color: c.indigo,
                          selected: !_editingNet,
                          onPressed: hasVideo
                              ? () => setState(() => _editingNet = false)
                              : null,
                        ),
                        _CalibrationTargetButton(
                          index: '2',
                          label: '篮网检测区',
                          color: Colors.white,
                          selected: _editingNet,
                          onPressed: hasVideo
                              ? () => setState(() => _editingNet = true)
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(Spacing.sm),
                      decoration: BoxDecoration(
                        color: c.surface2,
                        borderRadius: BorderRadius.circular(CsRadius.sm),
                        border: Border.all(color: c.border),
                      ),
                      child: Text(
                        _editingNet
                            ? '正在编辑：篮网检测区（白色）。只包住篮圈下方到网底的白网；不要包含篮板、球员或地面。它只用于辅助判断篮网是否摆动。'
                            : '正在编辑：投篮分析区（紫色）。覆盖篮板、篮筐、来球轨迹和篮筐下方的落球区域；它可以明显大于篮网。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: c.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: hasVideo && !roiBusy
                            ? () => setState(() {
                                _netRoi = _recommendedNetRoi(
                                  _roi,
                                  state.hoopBbox,
                                );
                                _netUserEdited = false;
                                _editingNet = true;
                              })
                            : null,
                        icon: const Icon(Icons.restart_alt_rounded, size: 16),
                        label: const Text('重置篮网区为推荐范围'),
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),

                    Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: _savingRoi
                              ? CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: c.indigo,
                                )
                              : Icon(
                                  _roiSaved
                                      ? Icons.cloud_done_outlined
                                      : Icons.edit_outlined,
                                  size: 14,
                                  color: c.textSecondary,
                                ),
                        ),
                        const SizedBox(width: Spacing.xs),
                        Expanded(
                          child: Text(
                            hasRoi
                                ? (_roiSaved
                                      ? '区域已自动保存。拖拽或缩放结束后会再次保存。'
                                      : '调整结束后将自动保存区域。')
                                : '拖拽覆盖篮筐上方轨迹、篮筐、篮网和下方区域。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: Spacing.lg),
              // ── 开始分析 ──
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  CsButton(
                    label: const Text('开始分析'),
                    icon: LucideIcons.play,
                    isLoading: state.busy,
                    onPressed: (hasVideo && hasRoi && _roiSaved && !roiBusy)
                        ? _startAnalysis
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _videoSummary(Map<String, dynamic> video) {
    final w = video['width'] ?? '-';
    final h = video['height'] ?? '-';
    final fps = (video['fps'] as num?)?.toStringAsFixed(2) ?? '-';
    final duration = (video['duration_ms'] as num?)?.toInt() ?? 0;
    final codec = video['video_codec'] ?? '-';
    final audio = video['audio_codec'] ?? '无音频';
    final size = (video['source_size_bytes'] as num?)?.toInt() ?? 0;
    return '$w×$h · $fps fps · ${_formatDuration(duration)} · $codec / $audio · ${_formatBytes(size)}';
  }

  String _workspaceSummary(Map<String, dynamic> video) {
    final available = (video['available_disk_bytes'] as num?)?.toInt() ?? 0;
    final estimated =
        (video['estimated_working_space_bytes'] as num?)?.toInt() ?? 0;
    final sufficient = video['disk_space_sufficient'] != false;
    return sufficient
        ? '预计工作空间 ${_formatBytes(estimated)} · 可用 ${_formatBytes(available)}'
        : '磁盘空间不足：预计需要 ${_formatBytes(estimated)}，当前可用 ${_formatBytes(available)}';
  }
}

int _analysisStart(ProjectState state) =>
    (state.video?['analysis_start_ms'] as num?)?.toInt() ?? 0;

int _analysisEnd(ProjectState state) =>
    (state.video?['analysis_end_ms'] as num?)?.toInt() ??
    ((state.video?['duration_ms'] as num?)?.toInt() ?? 0);

Rect? _netRoiFromState(ProjectState state) => state.netRoi;

Rect? _recommendedNetRoi(Rect? analysisRoi, Rect? hoopBbox) {
  if (analysisRoi == null) return null;
  if (hoopBbox == null) {
    return Rect.fromLTRB(
      (analysisRoi.left + analysisRoi.width * 0.30).clamp(0.0, 1.0),
      (analysisRoi.top + analysisRoi.height * 0.38).clamp(0.0, 1.0),
      (analysisRoi.right - analysisRoi.width * 0.30).clamp(0.0, 1.0),
      (analysisRoi.top + analysisRoi.height * 0.74).clamp(0.0, 1.0),
    );
  }
  final width = (hoopBbox.width * 1.35).clamp(
    analysisRoi.width * 0.08,
    analysisRoi.width * 0.34,
  );
  final left = (hoopBbox.center.dx - width / 2).clamp(
    analysisRoi.left,
    analysisRoi.right - width,
  );
  final top = (hoopBbox.top + hoopBbox.height * 0.42).clamp(
    analysisRoi.top,
    analysisRoi.bottom,
  );
  final height = (hoopBbox.height * 0.95).clamp(
    analysisRoi.height * 0.12,
    analysisRoi.height * 0.30,
  );
  return Rect.fromLTWH(
    left,
    top,
    width,
    height.clamp(0.03, analysisRoi.bottom - top),
  );
}

String _formatDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remaining.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remaining.toString().padLeft(2, '0')}';
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

class _AnalysisRangeEditor extends StatefulWidget {
  const _AnalysisRangeEditor({
    required this.videoPath,
    required this.durationMs,
    required this.startMs,
    required this.endMs,
    required this.enabled,
    required this.onChanged,
    required this.onCommit,
  });

  final String? videoPath;
  final int durationMs;
  final int startMs;
  final int endMs;
  final bool enabled;
  final void Function(int startMs, int endMs) onChanged;
  final Future<void> Function(int startMs, int endMs) onCommit;

  @override
  State<_AnalysisRangeEditor> createState() => _AnalysisRangeEditorState();
}

class _AnalysisRangeEditorState extends State<_AnalysisRangeEditor> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  int _positionMs = 0;
  bool _ready = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _openVideo();
  }

  @override
  void didUpdateWidget(covariant _AnalysisRangeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) _openVideo();
  }

  Future<void> _openVideo() async {
    final path = widget.videoPath;
    await _positionSubscription?.cancel();
    await _player?.dispose();
    _player = null;
    _controller = null;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      if (mounted) setState(() => _ready = false);
      return;
    }
    final player = Player();
    _player = player;
    _controller = VideoController(player);
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted) return;
      final value = position.inMilliseconds;
      if ((value - _positionMs).abs() >= 100) {
        setState(() => _positionMs = value);
      }
    });
    await player.open(Media(Uri.file(path).toString()), play: false);
    if (mounted && identical(player, _player)) {
      setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _seek(int value) async {
    final target = value.clamp(0, widget.durationMs).toInt();
    setState(() => _positionMs = target);
    await _player?.seek(Duration(milliseconds: target));
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null) return;
    if (player.state.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _commitRange(int startMs, int endMs) async {
    if (_saving) return;
    _saving = true;
    try {
      await widget.onCommit(startMs, endMs);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.durationMs <= 1000) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final start = widget.startMs.clamp(0, widget.durationMs - 1000).toInt();
    final end = widget.endMs.clamp(start + 1000, widget.durationMs).toInt();
    final fullRange = start == 0 && end == widget.durationMs;
    final controller = _controller;
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(CsRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('分析范围', style: Theme.of(context).textTheme.labelLarge),
          Text(
            fullRange
                ? '默认扫描完整视频。播放视频后设定起点和终点，可排除热身或结束部分；原视频不会被裁剪。'
                : '仅扫描 ${_formatDuration(start)} - ${_formatDuration(end)}，原视频不会被裁剪。',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: c.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black),
              child: controller == null || !_ready
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: Video(
                            controller: controller,
                            controls: NoVideoControls,
                          ),
                        ),
                        Positioned(
                          top: Spacing.xs,
                          right: Spacing.xs,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.64),
                              borderRadius: BorderRadius.circular(CsRadius.xs),
                            ),
                            child: Text(
                              _formatDuration(_positionMs),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              IconButton(
                tooltip: '播放/暂停',
                onPressed: _ready ? () => unawaited(_togglePlayback()) : null,
                icon: Icon(
                  _player?.state.playing == true
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                '拖动下方两个手柄，视频会跳到正在调整的位置。',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
              ),
            ],
          ),
          RangeSlider(
            min: 0,
            max: widget.durationMs.toDouble(),
            divisions: 1000,
            values: RangeValues(start.toDouble(), end.toDouble()),
            onChanged: widget.enabled
                ? (value) {
                    final nextStart = value.start.round();
                    final nextEnd = value.end.round();
                    final startMoved = (nextStart - start).abs();
                    final endMoved = (nextEnd - end).abs();
                    final seekTarget = startMoved >= endMoved
                        ? nextStart
                        : nextEnd;
                    widget.onChanged(nextStart, nextEnd);
                    unawaited(_seek(seekTarget));
                  }
                : null,
            onChangeEnd: widget.enabled
                ? (value) => unawaited(
                    _commitRange(value.start.round(), value.end.round()),
                  )
                : null,
          ),
          Row(
            children: [
              Text(
                '起点 ${_formatDuration(start)}',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
              ),
              const Spacer(),
              Text(
                '终点 ${_formatDuration(end)}',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
              ),
              const SizedBox(width: Spacing.sm),
              TextButton.icon(
                onPressed: widget.enabled
                    ? () {
                        widget.onChanged(0, widget.durationMs);
                        unawaited(_commitRange(0, widget.durationMs));
                      }
                    : null,
                icon: const Icon(Icons.unfold_more_rounded, size: 16),
                label: const Text('使用全片'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CalibrationTargetButton extends StatelessWidget {
  const _CalibrationTargetButton({
    required this.index,
    required this.label,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String index;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? c.textPrimary : c.textSecondary,
        backgroundColor: selected
            ? color.withValues(alpha: color == Colors.white ? 0.12 : 0.20)
            : Colors.transparent,
        side: BorderSide(color: selected ? color : c.borderStrong),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              index,
              style: TextStyle(
                fontSize: 10,
                color: color == Colors.white ? Colors.black : Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

/// ROI 拖拽画布。pan 逻辑迁移自 3700bbc(原样),仅视觉精致化:
/// 边框 `border` → 激活 `indigo`,选区 `indigo` 18% + 2px + 四角手柄。
class _RoiCanvas extends StatefulWidget {
  const _RoiCanvas({
    required this.enabled,
    required this.previewPath,
    required this.aspectRatio,
    required this.roi,
    required this.secondaryRoi,
    required this.activeColor,
    required this.secondaryColor,
    required this.activeLabel,
    required this.secondaryLabel,
    required this.onRefreshPreview,
    required this.onChanged,
    required this.onEditComplete,
  });

  final bool enabled;
  final String? previewPath;
  final double aspectRatio;
  final Rect? roi;
  final Rect? secondaryRoi;
  final Color activeColor;
  final Color secondaryColor;
  final String activeLabel;
  final String secondaryLabel;
  final VoidCallback? onRefreshPreview;
  final ValueChanged<Rect> onChanged;
  final VoidCallback onEditComplete;

  @override
  State<_RoiCanvas> createState() => _RoiCanvasState();
}

class _RoiCanvasState extends State<_RoiCanvas> {
  Offset? _start;
  Rect? _initialRect;
  _RoiDragMode? _dragMode;
  double _zoom = 1;
  Alignment _focus = Alignment.center;

  @override
  void didUpdateWidget(covariant _RoiCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeLabel != widget.activeLabel) {
      _zoom = 1;
      _focus = _alignmentFor(widget.roi);
    }
  }

  Alignment _alignmentFor(Rect? roi) {
    final center = roi?.center ?? const Offset(0.5, 0.5);
    return Alignment(center.dx * 2 - 1, center.dy * 2 - 1);
  }

  void _changeZoom(double delta) {
    setState(() {
      _zoom = (_zoom + delta).clamp(1.0, 4.0);
      _focus = _alignmentFor(widget.roi);
    });
  }

  void _resetZoom() {
    setState(() {
      _zoom = 1;
      _focus = Alignment.center;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: widget.enabled ? c.surface2 : c.surface3,
              borderRadius: BorderRadius.circular(CsRadius.lg),
              border: Border.all(
                color: widget.enabled ? c.indigo : c.border,
                width: widget.enabled ? 1.5 : 1,
              ),
            ),
            child: Stack(
              children: [
                ClipRect(
                  child: Transform.scale(
                    alignment: _focus,
                    scale: _zoom,
                    child: GestureDetector(
                      onPanStart: widget.enabled
                          ? (details) => _beginDrag(
                              details.localPosition,
                              constraints.biggest,
                            )
                          : null,
                      onPanUpdate:
                          widget.enabled && _start != null && _dragMode != null
                          ? (details) => _updateDrag(
                              details.localPosition,
                              constraints.biggest,
                            )
                          : null,
                      onPanEnd: widget.enabled
                          ? (_) {
                              setState(() {
                                _start = null;
                                _initialRect = null;
                                _dragMode = null;
                              });
                              widget.onEditComplete();
                            }
                          : null,
                      child: Stack(
                        children: [
                          if (widget.previewPath != null &&
                              File(widget.previewPath!).existsSync())
                            Positioned.fill(
                              child: Image.file(
                                File(widget.previewPath!),
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, _) => Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(Spacing.md),
                                    child: Text(
                                      '预览加载失败，请重新生成。',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: c.error,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else if (!widget.enabled)
                            const Center(
                              child: CsEmptyState(
                                icon: LucideIcons.lock,
                                title: '请先选择视频',
                                description: '选择原始视频后即可框选篮筐区域。',
                              ),
                            )
                          else if (widget.previewPath != null)
                            Center(
                              child: CsEmptyState(
                                icon: LucideIcons.circleAlert,
                                title: '预览帧不可用',
                                description: '视频元数据已读取，可以重新生成预览后继续框选。',
                                action: widget.onRefreshPreview == null
                                    ? null
                                    : CsButton(
                                        label: const Text('重新生成预览'),
                                        icon: LucideIcons.refreshCw,
                                        variant: CsButtonVariant.secondary,
                                        size: CsButtonSize.sm,
                                        onPressed: widget.onRefreshPreview,
                                      ),
                              ),
                            )
                          else
                            Center(
                              child: CsEmptyState(
                                icon: LucideIcons.film,
                                title: '正在准备视频预览',
                                description: '预览准备好后即可拖拽框选篮筐区域。',
                                action: widget.onRefreshPreview == null
                                    ? null
                                    : CsButton(
                                        label: const Text('生成预览'),
                                        icon: LucideIcons.refreshCw,
                                        variant: CsButtonVariant.secondary,
                                        size: CsButtonSize.sm,
                                        onPressed: widget.onRefreshPreview,
                                      ),
                              ),
                            ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _RoiPainter(
                                roi: widget.secondaryRoi,
                                color: widget.secondaryColor,
                                label: widget.secondaryLabel,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _RoiPainter(
                                roi: widget.roi,
                                color: widget.activeColor,
                                label: widget.activeLabel,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: Spacing.xs,
                  left: Spacing.xs,
                  child: Material(
                    color: c.background.withValues(alpha: 0.76),
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '缩小',
                          onPressed: _zoom > 1 ? () => _changeZoom(-0.5) : null,
                          icon: const Icon(Icons.remove_rounded, size: 16),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        Text(
                          '${(_zoom * 100).round()}%',
                          style: TextStyle(color: c.textPrimary, fontSize: 11),
                        ),
                        IconButton(
                          tooltip: '放大',
                          onPressed: _zoom < 4 ? () => _changeZoom(0.5) : null,
                          icon: const Icon(Icons.add_rounded, size: 16),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        IconButton(
                          tooltip: '适应画面',
                          onPressed: _zoom > 1 ? _resetZoom : null,
                          icon: const Icon(Icons.fit_screen_outlined, size: 15),
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 像素坐标 → 归一化 [0,1]。迁移自 3700bbc(逻辑层不动)。
  Rect _normalizedRect(Offset start, Offset end, Size size) {
    final left =
        (start.dx < end.dx ? start.dx : end.dx).clamp(0.0, size.width) /
        size.width;
    final top =
        (start.dy < end.dy ? start.dy : end.dy).clamp(0.0, size.height) /
        size.height;
    final right =
        (start.dx > end.dx ? start.dx : end.dx).clamp(0.0, size.width) /
        size.width;
    final bottom =
        (start.dy > end.dy ? start.dy : end.dy).clamp(0.0, size.height) /
        size.height;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _beginDrag(Offset point, Size size) {
    final current = widget.roi;
    _RoiDragMode mode = _RoiDragMode.create;
    if (current != null) {
      final rect = Rect.fromLTRB(
        current.left * size.width,
        current.top * size.height,
        current.right * size.width,
        current.bottom * size.height,
      );
      const handleRadius = 14.0;
      if ((point - rect.topLeft).distance <= handleRadius) {
        mode = _RoiDragMode.topLeft;
      } else if ((point - rect.topRight).distance <= handleRadius) {
        mode = _RoiDragMode.topRight;
      } else if ((point - rect.bottomLeft).distance <= handleRadius) {
        mode = _RoiDragMode.bottomLeft;
      } else if ((point - rect.bottomRight).distance <= handleRadius) {
        mode = _RoiDragMode.bottomRight;
      } else if (rect.contains(point)) {
        mode = _RoiDragMode.move;
      }
    }
    setState(() {
      _start = point;
      _initialRect = current;
      _dragMode = mode;
    });
  }

  void _updateDrag(Offset point, Size size) {
    final start = _start;
    final mode = _dragMode;
    if (start == null || mode == null) return;
    final base = _initialRect;
    if (mode == _RoiDragMode.create || base == null) {
      widget.onChanged(_normalizedRect(start, point, size));
      return;
    }
    final normalized = Offset(
      (point.dx / size.width).clamp(0.0, 1.0),
      (point.dy / size.height).clamp(0.0, 1.0),
    );
    const minimum = 0.03;
    if (mode == _RoiDragMode.move) {
      final dx = (point.dx - start.dx) / size.width;
      final dy = (point.dy - start.dy) / size.height;
      final left = (base.left + dx).clamp(0.0, 1.0 - base.width);
      final top = (base.top + dy).clamp(0.0, 1.0 - base.height);
      widget.onChanged(Rect.fromLTWH(left, top, base.width, base.height));
      return;
    }
    var left = base.left;
    var top = base.top;
    var right = base.right;
    var bottom = base.bottom;
    switch (mode) {
      case _RoiDragMode.topLeft:
        left = normalized.dx.clamp(0.0, right - minimum);
        top = normalized.dy.clamp(0.0, bottom - minimum);
        break;
      case _RoiDragMode.topRight:
        right = normalized.dx.clamp(left + minimum, 1.0);
        top = normalized.dy.clamp(0.0, bottom - minimum);
        break;
      case _RoiDragMode.bottomLeft:
        left = normalized.dx.clamp(0.0, right - minimum);
        bottom = normalized.dy.clamp(top + minimum, 1.0);
        break;
      case _RoiDragMode.bottomRight:
        right = normalized.dx.clamp(left + minimum, 1.0);
        bottom = normalized.dy.clamp(top + minimum, 1.0);
        break;
      case _RoiDragMode.create:
      case _RoiDragMode.move:
        break;
    }
    widget.onChanged(Rect.fromLTRB(left, top, right, bottom));
  }
}

enum _RoiDragMode { create, move, topLeft, topRight, bottomLeft, bottomRight }

/// ROI 选区绘制:18% 填充 + 2px 描边 + 四角手柄。
class _RoiPainter extends CustomPainter {
  const _RoiPainter({
    required this.roi,
    required this.color,
    required this.label,
  });

  final Rect? roi;
  final Color color;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final value = roi;
    if (value == null) return;
    final rect = Rect.fromLTRB(
      value.left * size.width,
      value.top * size.height,
      value.right * size.width,
      value.bottom * size.height,
    );
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color == Colors.white ? Colors.black : Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelRect = Rect.fromLTWH(
      rect.left + 5,
      (rect.top + 5).clamp(0.0, size.height - textPainter.height - 4),
      textPainter.width + 10,
      textPainter.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(3)),
      Paint()..color = color,
    );
    textPainter.paint(canvas, labelRect.topLeft + const Offset(5, 2));
    // 四角手柄
    const handle = 8.0;
    final paint = Paint()..color = color;
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: corner, width: handle, height: handle),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoiPainter oldDelegate) =>
      oldDelegate.roi != roi || oldDelegate.color != color;
}
