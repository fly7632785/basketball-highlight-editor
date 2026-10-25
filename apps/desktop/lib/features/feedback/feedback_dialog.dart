import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/contact_actions.dart';
import '../../core/diagnostics.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

const communityUrl = 'https://bhe.jafir.top/#download';
const githubIssueUrl =
    'https://github.com/fly7632785/basketball-highlight-editor/issues/new?template=bug_report.yml';

/// 反馈入口：先复制诊断信息，再发到交流群、邮件或 GitHub。
/// [error] 不为空时（从报错进来）会一起显示并写进诊断信息。
Future<void> showFeedbackDialog(BuildContext context, {String? error}) {
  return showDialog<void>(
    context: context,
    builder: (_) => FeedbackDialog(error: error),
  );
}

class FeedbackDialog extends StatefulWidget {
  const FeedbackDialog({this.error, super.key});

  final String? error;

  @override
  State<FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<FeedbackDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    final report = await buildDiagnosticReport(error: widget.error);
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final english = l10n?.localeName.startsWith('en') == true;
    final error = widget.error?.trim();
    return Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: c.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.messageCircle, color: c.orange, size: 20),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      context.bheText('反馈问题'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: context.bheText('关闭'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                context.bheText('遇到问题或想提建议，两步就行：'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: Spacing.md),
              _Step(
                index: 1,
                title: context.bheText('复制诊断信息'),
                detail: context.bheText('会带上版本、系统和最近的运行日志，用户名会自动隐藏，不包含视频内容。'),
              ),
              _Step(
                index: 2,
                title: context.bheText('发给我'),
                detail: context.bheText('贴到交流群、小红书私信或邮件都可以，顺便说一下你做了什么操作。'),
              ),
              if (error != null && error.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  context.bheText('错误详情'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: c.textTertiary,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  key: const Key('feedback-error'),
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(Spacing.sm),
                  decoration: BoxDecoration(
                    color: c.error.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                    border: Border.all(color: c.error.withValues(alpha: 0.3)),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      l10n?.text(error) ?? error,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: Spacing.lg),
              Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: [
                  TextButton.icon(
                    onPressed: () => openExternalUri(communityUrl),
                    icon: const Icon(LucideIcons.users, size: 16),
                    label: Text(context.bheText('进交流群（官网扫码）')),
                  ),
                  TextButton.icon(
                    onPressed: () => openExternalUri(
                      feedbackMailto(appVersion: appVersion, english: english),
                    ),
                    icon: const Icon(LucideIcons.mail, size: 16),
                    label: Text(context.bheText('发邮件')),
                  ),
                  TextButton.icon(
                    onPressed: () => openExternalUri(githubIssueUrl),
                    icon: const Icon(LucideIcons.bug, size: 16),
                    label: Text(context.bheText('GitHub 提交')),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('feedback-copy'),
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? LucideIcons.check : LucideIcons.copy,
                    size: 17,
                  ),
                  label: Text(
                    _copied
                        ? context.bheText('已复制，可以粘贴发给我了')
                        : context.bheText('复制诊断信息'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.title, required this.detail});

  final int index;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.orange.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelSmall?.copyWith(color: c.orange),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
