// lib/components/cs_metric_tile.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsMetricTile extends StatelessWidget {
  const CsMetricTile({required this.label, required this.value, this.icon, super.key});
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: c.textTertiary),
            const SizedBox(width: Spacing.sm),
          ],
          Text(label, style: TextStyle(color: c.textSecondary, fontSize: 13)),
          const Spacer(),
          Text(value, style: TextStyle(
            color: c.textPrimary, fontSize: 15, fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          )),
        ],
      ),
    );
  }
}
