import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  bool _roiSaved = false;
  bool _savingRoi = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(projectProvider);
    _roi = state.suggestedRoi;
    _roiSaved = state.roiSource != null && state.suggestedRoi != null;
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

  Future<void> _saveRoi() async {
    final roi = _roi;
    if (roi == null) return;
    setState(() => _savingRoi = true);
    try {
      await ref.read(projectProvider.notifier).saveRoi(roi);
      if (mounted) setState(() => _roiSaved = true);
    } finally {
      if (mounted) setState(() => _savingRoi = false);
    }
  }

  Future<void> _startAnalysis() async {
    await ref.read(projectProvider.notifier).startAnalysis();
    if (mounted) context.go('/review');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    // 视频切换时重置 ROI 为引擎建议值。
    ref.listen<ProjectState>(projectProvider, (previous, next) {
      if (previous?.videoPath != next.videoPath) {
        setState(() {
          _roi = next.suggestedRoi;
          _roiSaved = next.roiSource != null && next.suggestedRoi != null;
        });
      }
    });

    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final hasVideo = state.videoPath != null;
    final hasRoi = _roi != null;
    final width = (state.video?['width'] as num?)?.toDouble() ?? 16;
    final height = (state.video?['height'] as num?)?.toDouble() ?? 9;
    final roiBusy = state.busy || _savingRoi;

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
                style: theme.textTheme.bodyLarge?.copyWith(color: c.textSecondary),
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
                      child: Row(
                        children: [
                          Icon(LucideIcons.film, size: 18, color: c.textSecondary),
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
                          const SizedBox(width: Spacing.md),
                          CsButton(
                            label: Text(hasVideo ? '更换视频' : '选择视频'),
                            icon: LucideIcons.folderOpen,
                            variant: CsButtonVariant.secondary,
                            onPressed: state.busy ? null : _selectVideo,
                          ),
                        ],
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
                    ],

                    const SizedBox(height: Spacing.xl),

                    // ── ROI 提示 ──
                    if (state.roiSource == 'auto' && hasRoi) ...[
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
                      enabled: hasVideo,
                      previewPath: state.previewPath,
                      aspectRatio:
                          width > 0 && height > 0 ? width / height : 16 / 9,
                      roi: _roi,
                      onChanged: (value) => setState(() {
                        _roi = value;
                        _roiSaved = false;
                      }),
                    ),
                    const SizedBox(height: Spacing.md),

                    // ── 保存 ROI 行 ──
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            hasRoi
                                ? (_roiSaved
                                      ? 'ROI 已保存。如需调整，直接拖拽重新框选后再次保存。'
                                      : '已生成检测区域，调整后请点击保存。')
                                : '拖拽覆盖篮筐上方轨迹、篮筐、篮网和下方区域。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.md),
                        CsButton(
                          label: const Text('保存 ROI'),
                          icon: LucideIcons.slidersHorizontal,
                          variant: CsButtonVariant.secondary,
                          isLoading: _savingRoi,
                          onPressed: (hasRoi && !roiBusy) ? _saveRoi : null,
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
    return '$w×$h · $fps fps · 时长 ${_formatDuration(duration)} · 编码 $codec';
  }
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

/// ROI 拖拽画布。pan 逻辑迁移自 3700bbc(原样),仅视觉精致化:
/// 边框 `border` → 激活 `indigo`,选区 `indigo` 18% + 2px + 四角手柄。
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
    final c = AppColors.of(context);
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
                color: widget.enabled ? c.surface2 : c.surface3,
                borderRadius: BorderRadius.circular(CsRadius.lg),
                border: Border.all(
                  color: widget.enabled ? c.indigo : c.border,
                  width: widget.enabled ? 1.5 : 1,
                ),
              ),
              child: Stack(
                children: [
                  if (widget.previewPath != null)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(CsRadius.lg),
                        child: Image.file(
                          File(widget.previewPath!),
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, _) => const SizedBox
                              .shrink(),
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
                  else
                    Center(
                      child: Text(
                        'ROI 预览区域\n拖拽框选篮筐',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textTertiary, fontSize: 13),
                      ),
                    ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RoiPainter(roi: widget.roi, color: c.indigo),
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
}

/// ROI 选区绘制:18% 填充 + 2px 描边 + 四角手柄。
class _RoiPainter extends CustomPainter {
  const _RoiPainter({required this.roi, required this.color});

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
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
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
