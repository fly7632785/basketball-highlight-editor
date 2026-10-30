import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

class ReviewModuleTabs extends StatelessWidget {
  const ReviewModuleTabs({
    super.key,
    required this.shooterSelected,
    required this.onSelected,
    this.enabled = true,
  });

  final bool shooterSelected;
  final ValueChanged<bool> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Container(
      key: const Key('review-module-tabs'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Wrap(
        spacing: Spacing.sm,
        children: [
          for (final shooter in [false, true])
            Semantics(
              selected: shooterSelected == shooter,
              child: TextButton.icon(
                key: Key(
                  shooter ? 'open-shooter-quick-label' : 'review-basket-tab',
                ),
                onPressed: enabled ? () => onSelected(shooter) : null,
                style: TextButton.styleFrom(
                  foregroundColor: shooterSelected == shooter
                      ? c.orange
                      : c.textSecondary,
                  backgroundColor: shooterSelected == shooter
                      ? c.orange.withValues(alpha: 0.14)
                      : Colors.transparent,
                  minimumSize: const Size(44, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                  ),
                ),
                icon: Icon(
                  shooter
                      ? Icons.people_alt_outlined
                      : Icons.sports_basketball_outlined,
                  size: 18,
                ),
                label: Text(
                  shooter
                      ? (zh ? '射手快标' : 'Shooter quick label')
                      : (zh ? '进球审核' : 'Basket review'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
