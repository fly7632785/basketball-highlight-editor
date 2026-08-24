import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/contact_actions.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

Future<void> showCourtsideAboutDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _CourtsideAboutDialog(),
  );
}

class _CourtsideAboutDialog extends StatelessWidget {
  const _CourtsideAboutDialog();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: c.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: c.orange.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(CsRadius.md),
                    ),
                    child: Icon(LucideIcons.volleyball, color: c.orange),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('BHE', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                          'basketball-highlight-editor',
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          '篮球高光视频助手',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              Text(
                '从固定机位视频中识别投篮候选，审核后快速导出个人或全场高光。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: c.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              _InfoRow(label: '处理方式', value: '本地处理，原始视频不会自动上传'),
              _InfoRow(label: '反馈邮箱', value: feedbackEmail),
              _InfoRow(label: 'GitHub', value: '即将开放'),
              const SizedBox(height: Spacing.lg),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: () async {
                    await openExternalUri(feedbackMailto());
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(LucideIcons.mail, size: 17),
                  label: const Text('发送反馈'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: c.textTertiary),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
