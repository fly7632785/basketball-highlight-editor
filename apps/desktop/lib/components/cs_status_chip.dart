// lib/components/cs_status_chip.dart
import 'package:flutter/cupertino.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

enum ReviewStatus { goal, pending, excluded }

class CsStatusChip extends StatelessWidget {
  const CsStatusChip({required this.status, this.compact = false, super.key});
  final ReviewStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (label, color, icon) = switch (status) {
      ReviewStatus.goal => ('已确认', c.goal, CupertinoIcons.check_mark),
      ReviewStatus.pending => ('待审核', c.pending, CupertinoIcons.clock),
      ReviewStatus.excluded => ('已排除', c.excluded, CupertinoIcons.xmark),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? Spacing.sm : Spacing.md,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(CsRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 11 : 13, color: color),
          SizedBox(width: compact ? 3 : 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
