import 'dart:io';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_log.dart';
import '../../core/contact_actions.dart';

Future<void> openLogDirectory({
  required String directory,
  Future<bool> Function(String) opener = openExternalUri,
}) async {
  await Directory(directory).create(recursive: true);
  if (!await opener(directory)) {
    throw const FileSystemException('系统未能打开日志目录');
  }
}

/// “关于”和更多菜单共用入口；失败时保留可手动定位的路径。
Future<void> openLogDirectoryWithFeedback(
  BuildContext context, {
  Future<void> Function()? open,
}) async {
  final directory = engineLogDirectory(Platform.environment);
  try {
    await (open ?? () => openLogDirectory(directory: directory))();
    appLog('info', 'logs', '打开日志目录');
  } catch (error) {
    appLog('warn', 'logs', '打开日志目录失败: $error');
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.bheText('无法打开日志目录')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.bheText('可以复制下面的路径，在文件管理器中手动打开。')),
            const SizedBox(height: 12),
            SelectableText(directory),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.bheText('关闭')),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: directory));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: Text(context.bheText('复制路径')),
          ),
        ],
      ),
    );
  }
}
