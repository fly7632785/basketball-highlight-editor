// lib/components/cs_empty_state.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsEmptyState extends StatelessWidget {
  const CsEmptyState({required this.icon, required this.title, this.description, this.action, super.key});
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: c.textTertiary),
            const SizedBox(height: Spacing.md),
            Text(title, style: TextStyle(
              color: c.textPrimary, fontSize: 16, fontWeight: FontWeight.w600,
            )),
            if (description != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(description!, textAlign: TextAlign.center, style: TextStyle(
                color: c.textSecondary, fontSize: 13, height: 1.5,
              )),
            ],
            if (action != null) ...[
              const SizedBox(height: Spacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
