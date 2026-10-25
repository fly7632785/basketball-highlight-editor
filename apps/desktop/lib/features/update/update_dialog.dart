import 'dart:io';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../providers/project_state.dart';
import '../../providers/update_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// 检查更新窗口：打开时如果还没查过（或上次失败）就查一次。
Future<void> showUpdateDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const UpdateDialog(),
  );
}

class UpdateDialog extends ConsumerStatefulWidget {
  const UpdateDialog({super.key});

  @override
  ConsumerState<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<UpdateDialog> {
  @override
  void initState() {
    super.initState();
    final status = ref.read(updateProvider).status;
    if (status == UpdateStatus.idle ||
        status == UpdateStatus.upToDate ||
        status == UpdateStatus.failed &&
            ref.read(updateProvider).manifest == null) {
      Future.microtask(
        () => ref.read(updateProvider.notifier).check(manual: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final english = l10n?.localeName.startsWith('en') == true;
    final update = ref.watch(updateProvider);
    final notifier = ref.read(updateProvider.notifier);
    final appVersion = ref.watch(appVersionProvider);
    final project = ref.watch(projectProvider);
    final busy =
        project.analysisRunning ||
        project.exportRunning ||
        project.analysisQueue.isNotEmpty && !project.queuePaused;
    final manifest = update.manifest;
    final package = update.package;
    final hasUpdate =
        manifest != null &&
        package != null &&
        (update.status == UpdateStatus.available ||
            update.status == UpdateStatus.downloading ||
            update.status == UpdateStatus.ready ||
            update.status == UpdateStatus.failed);

    final body = <Widget>[];
    final actions = <Widget>[];
    switch (update.status) {
      case UpdateStatus.idle:
      case UpdateStatus.checking:
        body.add(
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Spacing.sm),
              Text(context.bheText('正在检查更新…')),
            ],
          ),
        );
      case UpdateStatus.upToDate:
        body.add(Text(context.bheText('已经是最新版本（v$appVersion）')));
      case UpdateStatus.failed when !hasUpdate:
        body.add(_ErrorText(update.error ?? ''));
        actions.add(
          FilledButton(
            onPressed: () => notifier.check(manual: true),
            child: Text(context.bheText('重新检查')),
          ),
        );
      default:
        break;
    }

    if (hasUpdate) {
      body.addAll([
        Text(
          context.bheText('新版本 v${manifest.version}'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 2),
        Text(
          '${context.bheText('当前版本')} v$appVersion · ${_megabytes(package.size)} MB',
          style: theme.textTheme.bodySmall?.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: Spacing.md),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 200),
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(CsRadius.sm),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _noteLines(
                  manifest.notesFor(english: english),
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '· $line',
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),
      ]);
      switch (update.status) {
        case UpdateStatus.available:
          actions.addAll([
            TextButton(
              onPressed: () async {
                await notifier.skip();
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(context.bheText('跳过这个版本')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.bheText('稍后')),
            ),
            FilledButton.icon(
              key: const Key('update-download'),
              onPressed: notifier.download,
              icon: const Icon(LucideIcons.download, size: 16),
              label: Text(context.bheText('下载更新')),
            ),
          ]);
        case UpdateStatus.downloading:
          body.addAll([
            LinearProgressIndicator(value: update.received / package.size),
            const SizedBox(height: Spacing.xs),
            Text(
              context.bheText(
                '已下载 ${_megabytes(update.received)} / ${_megabytes(package.size)} MB',
              ),
              style: theme.textTheme.bodySmall,
            ),
          ]);
          actions.addAll([
            TextButton(
              onPressed: notifier.cancelDownload,
              child: Text(context.bheText('取消')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.bheText('后台下载')),
            ),
          ]);
        case UpdateStatus.failed:
          body.add(_ErrorText(update.error ?? ''));
          actions.add(
            FilledButton(
              onPressed: notifier.download,
              child: Text(context.bheText('继续下载')),
            ),
          );
        case UpdateStatus.ready:
          body.add(
            Text(
              context.bheText(
                Platform.isWindows
                    ? '下载完成。退出 BHE，把压缩包解压后替换原来的 BHE 文件夹，再重新打开。项目保存在别的位置，不会丢。'
                    : '下载完成。退出 BHE，打开安装包把 BHE 拖进「应用程序」替换旧版本，再重新打开。项目保存在别的位置，不会丢。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          );
          if (busy) {
            body.addAll([
              const SizedBox(height: Spacing.xs),
              Text(
                context.bheText('现在有分析或导出在进行，等它完成再退出替换。'),
                style: theme.textTheme.bodySmall?.copyWith(color: c.orange),
              ),
            ]);
          }
          actions.add(
            FilledButton.icon(
              key: const Key('update-open'),
              onPressed: notifier.openPackage,
              icon: const Icon(LucideIcons.packageOpen, size: 16),
              label: Text(
                context.bheText(Platform.isWindows ? '打开所在文件夹' : '打开安装包'),
              ),
            ),
          );
        default:
          break;
      }
    }

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
                  Icon(LucideIcons.circleArrowUp, color: c.orange, size: 20),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      context.bheText('检查更新'),
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
              const SizedBox(height: Spacing.md),
              ...body,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Spacing.xs,
                  runSpacing: Spacing.xs,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      context.bheText(message),
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: AppColors.of(context).error),
    );
  }
}

String _megabytes(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(0);

/// README 表格里一条更新说明用「；」分隔，拆成多行显示。
List<String> _noteLines(String notes) => notes
    .split(RegExp('[；;]'))
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList();
