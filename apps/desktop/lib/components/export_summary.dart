import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/tokens.dart';
import 'cs_button.dart';
import 'cs_progress_track.dart';

class ExportSummary extends StatelessWidget {
  const ExportSummary({
    required this.includedCount,
    required this.duration,
    required this.running,
    required this.recoverable,
    required this.busy,
    required this.progress,
    required this.stageLabel,
    required this.onMerge,
    required this.onSeparate,
    required this.onCancel,
    required this.onRetry,
    super.key,
  });

  final int includedCount;
  final String duration;
  final bool running;
  final bool recoverable;
  final bool busy;
  final double progress;
  final String stageLabel;
  final VoidCallback? onMerge;
  final VoidCallback? onSeparate;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('输出集锦', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Spacing.xs),
          Text(
            '只导出审核中保留的片段。原始视频不会被修改。',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            children: <Widget>[
              _ExportMetric(
                label: '片段',
                value: '$includedCount 个',
                icon: CupertinoIcons.check_mark_circled,
              ),
              const SizedBox(width: Spacing.lg),
              _ExportMetric(
                label: '预计时长',
                value: duration,
                icon: CupertinoIcons.clock,
              ),
              const SizedBox(width: Spacing.lg),
              const _ExportMetric(
                label: '编码',
                value: 'H.264 / AAC',
                icon: CupertinoIcons.video_camera,
              ),
            ],
          ),
          if (running || recoverable) ...<Widget>[
            const SizedBox(height: Spacing.lg),
            _ExportTaskState(
              running: running,
              recoverable: recoverable,
              progress: progress,
              stageLabel: stageLabel,
              onCancel: onCancel,
              onRetry: onRetry,
            ),
          ],
          const SizedBox(height: Spacing.xl),
          if (!running && !recoverable)
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked = constraints.maxWidth < 520;
                final merge = CsButton(
                  label: const Text('合并成一个视频'),
                  icon: CupertinoIcons.rectangle_stack,
                  isLoading: busy,
                  onPressed: onMerge,
                );
                final separate = CsButton(
                  label: const Text('分别导出'),
                  icon: CupertinoIcons.doc_on_doc,
                  variant: CsButtonVariant.secondary,
                  isLoading: busy,
                  onPressed: onSeparate,
                );
                return stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          merge,
                          const SizedBox(height: Spacing.sm),
                          separate,
                        ],
                      )
                    : Row(
                        children: <Widget>[
                          merge,
                          const SizedBox(width: Spacing.sm),
                          separate,
                        ],
                      );
              },
            ),
        ],
      ),
    );
  }
}

class _ExportMetric extends StatelessWidget {
  const _ExportMetric({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Expanded(
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: c.indigo),
          const SizedBox(width: Spacing.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
              ),
              Text(
                value,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExportTaskState extends StatelessWidget {
  const _ExportTaskState({
    required this.running,
    required this.recoverable,
    required this.progress,
    required this.stageLabel,
    required this.onCancel,
    required this.onRetry,
  });

  final bool running;
  final bool recoverable;
  final double progress;
  final String stageLabel;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final color = recoverable ? c.warning : c.indigo;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(CsRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  recoverable
                      ? '上次导出已中断'
                      : '$stageLabel · ${(progress * 100).round()}%',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: c.textPrimary),
                ),
              ),
              if (recoverable)
                CsButton(
                  label: const Text('重试导出'),
                  icon: CupertinoIcons.arrow_clockwise,
                  size: CsButtonSize.sm,
                  onPressed: onRetry,
                )
              else
                CsButton(
                  label: const Text('取消导出'),
                  icon: CupertinoIcons.stop_fill,
                  variant: CsButtonVariant.secondary,
                  size: CsButtonSize.sm,
                  onPressed: onCancel,
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            recoverable ? '可以用相同设置重新导出。' : '导出在后台进行，审核修改会保留给下一次导出。',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
          ),
          if (running) ...<Widget>[
            const SizedBox(height: Spacing.sm),
            CsProgressTrack(value: progress),
          ],
        ],
      ),
    );
  }
}
