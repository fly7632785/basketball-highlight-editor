import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class ImportVideoScreen extends StatefulWidget {
  const ImportVideoScreen({
    required this.videoPath,
    required this.previewPath,
    required this.video,
    required this.busy,
    this.initialRoi,
    this.initialRoiSaved = false,
    this.roiSource,
    this.roiConfidence,
    this.roiSuggestionError,
    required this.onVideoSelected,
    required this.onRoiSaved,
    required this.onAnalysisStarted,
    super.key,
  });

  final String? videoPath;
  final String? previewPath;
  final Map<String, dynamic>? video;
  final bool busy;
  final Rect? initialRoi;
  final bool initialRoiSaved;
  final String? roiSource;
  final double? roiConfidence;
  final String? roiSuggestionError;
  final Future<void> Function(String) onVideoSelected;
  final Future<void> Function(Rect normalizedRoi) onRoiSaved;
  final Future<void> Function() onAnalysisStarted;

  @override
  State<ImportVideoScreen> createState() => _ImportVideoScreenState();
}

class _ImportVideoScreenState extends State<ImportVideoScreen> {
  Rect? _roi;
  bool _roiSaved = false;
  bool _savingRoi = false;

  @override
  void didUpdateWidget(covariant ImportVideoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _roi = widget.initialRoi;
      _roiSaved = widget.initialRoiSaved && widget.initialRoi != null;
    }
  }

  Future<void> _selectVideo() async {
    const typeGroup = XTypeGroup(
      label: '视频',
      extensions: ['mp4', 'mov', 'm4v', 'avi', 'mkv'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file != null) await widget.onVideoSelected(file.path);
  }

  Future<void> _saveRoi() async {
    final roi = _roi;
    if (roi == null) return;
    setState(() => _savingRoi = true);
    try {
      await widget.onRoiSaved(roi);
      if (mounted) setState(() => _roiSaved = true);
    } finally {
      if (mounted) setState(() => _savingRoi = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasVideo = widget.videoPath != null;
    final hasRoi = _roi != null;
    final width = (widget.video?['width'] as num?)?.toDouble() ?? 16;
    final height = (widget.video?['height'] as num?)?.toDouble() ?? 9;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 30, 32, 42),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('新建分析项目', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                '选择原始视频，系统会优先自动定位篮筐，也可以手动调整检测区域。',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 26),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StepHeader(
                        number: '01',
                        title: '选择原始视频',
                        completed: hasVideo,
                      ),
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: .35),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              hasVideo
                                  ? Icons.movie_outlined
                                  : Icons.video_library_outlined,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.videoPath ??
                                    '支持 MP4 / MOV / H.264 / H.265，原始视频不会被复制。',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            OutlinedButton(
                              onPressed: widget.busy ? null : _selectVideo,
                              child: Text(hasVideo ? '更换视频' : '选择视频'),
                            ),
                          ],
                        ),
                      ),
                      if (widget.video != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _videoSummary(widget.video!),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 28),
                      _StepHeader(
                        number: '02',
                        title: '确认篮筐区域',
                        completed: hasRoi,
                      ),
                      const SizedBox(height: 16),
                      if (widget.roiSource == 'auto' && hasRoi) ...[
                        Row(
                          children: [
                            const Icon(Icons.auto_awesome, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              widget.roiConfidence == null
                                  ? '已自动识别篮筐区域'
                                  : '已自动识别篮筐区域 · 置信度 ${(widget.roiConfidence! * 100).round()}%',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ] else if (widget.roiSuggestionError != null) ...[
                        Text(
                          '自动识别失败：${widget.roiSuggestionError}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      _RoiCanvas(
                        enabled: hasVideo,
                        previewPath: widget.previewPath,
                        aspectRatio: width > 0 && height > 0
                            ? width / height
                            : 16 / 9,
                        roi: _roi,
                        onChanged: (value) => setState(() {
                          _roi = value;
                          _roiSaved = false;
                        }),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              hasRoi
                                  ? (_roiSaved
                                        ? 'ROI 已保存；如需调整，直接拖拽重新框选后再次保存。'
                                        : '已生成检测区域，调整后请点击保存。')
                                  : '自动识别失败时，拖拽覆盖篮筐上方轨迹、篮筐、篮网和下方区域。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: hasRoi && !widget.busy && !_savingRoi
                                ? _saveRoi
                                : null,
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('保存 ROI'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    onPressed: hasVideo && hasRoi && _roiSaved && !widget.busy
                        ? widget.onAnalysisStarted
                        : null,
                    icon: widget.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('开始分析'),
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
    final width = video['width'] ?? '-';
    final height = video['height'] ?? '-';
    final fps = (video['fps'] as num?)?.toStringAsFixed(2) ?? '-';
    final duration = (video['duration_ms'] as num?)?.toInt() ?? 0;
    return '视频信息：$width×$height · $fps fps · 时长 ${_formatDuration(duration)} · 编码 ${video['video_codec'] ?? '-'}';
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.number,
    required this.title,
    required this.completed,
  });
  final String number;
  final String title;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: completed
              ? scheme.primary
              : scheme.surfaceContainerHighest,
          child: completed
              ? Icon(Icons.check, size: 18, color: scheme.onPrimary)
              : Text(number),
        ),
        const SizedBox(width: 12),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (completed) ...[
          const SizedBox(width: 10),
          Text(
            '已完成',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.primary),
          ),
        ],
      ],
    );
  }
}

class _RoiCanvas extends StatefulWidget {
  const _RoiCanvas({
    required this.enabled,
    required this.previewPath,
    required this.aspectRatio,
    required this.roi,
    required this.onChanged,
  });
  final bool enabled;
  final String? previewPath;
  final double aspectRatio;
  final Rect? roi;
  final ValueChanged<Rect> onChanged;

  @override
  State<_RoiCanvas> createState() => _RoiCanvasState();
}

class _RoiCanvasState extends State<_RoiCanvas> {
  Offset? _start;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            onPanStart: widget.enabled
                ? (details) => setState(() => _start = details.localPosition)
                : null,
            onPanUpdate: widget.enabled && _start != null
                ? (details) => widget.onChanged(
                    _normalizedRect(
                      _start!,
                      details.localPosition,
                      constraints.biggest,
                    ),
                  )
                : null,
            onPanEnd: widget.enabled
                ? (_) => setState(() => _start = null)
                : null,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.enabled
                    ? const Color(0xFF202A33)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: widget.enabled
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .55)
                      : Colors.transparent,
                ),
              ),
              child: Stack(
                children: [
                  if (widget.previewPath != null)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.file(
                          File(widget.previewPath!),
                          fit: BoxFit.contain,
                        ),
                      ),
                    )
                  else
                    Center(
                      child: widget.enabled
                          ? const Text(
                              'ROI 预览区域\n拖拽框选篮筐',
                              textAlign: TextAlign.center,
                            )
                          : const Icon(Icons.lock_outline, size: 42),
                    ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RoiPainter(
                        widget.roi,
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

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
}

class _RoiPainter extends CustomPainter {
  const _RoiPainter(this.roi, this.color);
  final Rect? roi;
  final Color color;

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
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: .18));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _RoiPainter oldDelegate) =>
      oldDelegate.roi != roi || oldDelegate.color != color;
}

String _formatDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}'
      : '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}
