// lib/components/cs_empty_state.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsEmptyState extends StatelessWidget {
  const CsEmptyState({
    required this.icon,
    required this.title,
    this.description,
    this.action,
    super.key,
  });
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.hasBoundedHeight && constraints.maxHeight < 160;
        return Center(
          child: Padding(
            padding: EdgeInsets.all(compact ? Spacing.sm : Spacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: compact ? 28 : 48, color: c.textTertiary),
                SizedBox(height: compact ? Spacing.xs : Spacing.md),
                Text(
                  title,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: compact ? 14 : 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!compact && description != null) ...[
                  const SizedBox(height: Spacing.sm),
                  Text(
                    description!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ],
                if (!compact && action != null) ...[
                  const SizedBox(height: Spacing.lg),
                  action!,
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
