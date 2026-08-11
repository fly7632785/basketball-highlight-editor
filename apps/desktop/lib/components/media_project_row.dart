import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class MediaProjectRow extends StatelessWidget {
  const MediaProjectRow({
    required this.name,
    required this.sourceName,
    required this.duration,
    required this.candidates,
    required this.included,
    required this.onOpen,
    this.onDelete,
    super.key,
  });

  final String name;
  final String? sourceName;
  final String duration;
  final int candidates;
  final int included;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        hoverColor: c.surface2.withValues(alpha: 0.74),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Spacing.md, 12, Spacing.sm, 12),
          child: Row(
            children: <Widget>[
              Container(
                width: 76,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: BorderRadius.circular(CsRadius.sm),
                ),
                child: Icon(
                  CupertinoIcons.film,
                  color: c.textTertiary,
                  size: 20,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sourceName?.isNotEmpty == true ? sourceName! : '未关联视频',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              _Metric(label: '时长', value: duration),
              _Metric(label: '候选', value: '$candidates'),
              _Metric(label: '已保留', value: '$included', emphasized: true),
              const SizedBox(width: Spacing.xs),
              PopupMenuButton<_ProjectRowAction>(
                tooltip: '项目操作',
                enabled: onDelete != null,
                icon: Icon(
                  CupertinoIcons.ellipsis,
                  size: 18,
                  color: c.textTertiary,
                ),
                onSelected: (action) {
                  if (action == _ProjectRowAction.delete) onDelete?.call();
                },
                itemBuilder: (context) =>
                    const <PopupMenuEntry<_ProjectRowAction>>[
                      PopupMenuItem(
                        value: _ProjectRowAction.delete,
                        child: Text('删除项目'),
                      ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      width: 84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: emphasized ? c.goal : c.textPrimary,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

enum _ProjectRowAction { delete }
