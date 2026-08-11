import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsWorkspace extends StatelessWidget {
  const CsWorkspace({
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const <Widget>[],
    this.padding = const EdgeInsets.all(Spacing.lg),
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      children: <Widget>[
        Container(
          height: WorkspaceMetrics.pageBarHeight,
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          decoration: BoxDecoration(
            color: c.background,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final titleBlock = Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
                    ),
                ],
              );
              if (actions.isEmpty) return titleBlock;
              if (constraints.maxWidth < 700) {
                return Row(
                  children: <Widget>[
                    Expanded(child: titleBlock),
                    const SizedBox(width: Spacing.sm),
                    SizedBox(
                      width: constraints.maxWidth * 0.62,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: _joinActions(actions),
                        ),
                      ),
                    ),
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Flexible(child: titleBlock),
                  const Spacer(),
                  ..._joinActions(actions),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: Padding(padding: padding, child: child),
        ),
      ],
    );
  }

  List<Widget> _joinActions(List<Widget> children) => <Widget>[
    for (var index = 0; index < children.length; index++) ...<Widget>[
      if (index > 0) const SizedBox(width: Spacing.sm),
      children[index],
    ],
  ];
}

class InspectorSection extends StatelessWidget {
  const InspectorSection({
    required this.title,
    required this.child,
    this.trailing,
    this.compact = false,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: c.border),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? Spacing.sm : Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c.textTertiary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.7,
                  ),
                ),
                const Spacer(),
                if (trailing != null) ...<Widget>[trailing!],
              ],
            ),
            SizedBox(height: compact ? Spacing.xs : Spacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}
