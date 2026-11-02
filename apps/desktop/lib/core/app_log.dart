import 'dart:io';

import 'package:flutter/foundation.dart';

String engineLogDirectory(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
  if (Platform.isMacOS) return '$home/Library/Logs/BHE';
  if (Platform.isWindows) return '${env['LOCALAPPDATA'] ?? home}\\BHE\\logs';
  return '${env['XDG_STATE_HOME'] ?? '$home/.local/state'}/bhe/logs';
}

final _latestEnvironment = <String, String>{};

bool isEngineEnvironmentLine(String line) =>
    RegExp(r'^\[[^\]]+\] stderr: \[bhe\] environment ').hasMatch(line);

/// 测试时把日志指向临时文件，避免写进真实日志目录。
@visibleForTesting
File? appLogFileOverride;

void appendEngineLog(String message, {File? file}) {
  final target =
      file ??
      appLogFileOverride ??
      File(
        '${engineLogDirectory(Platform.environment)}${Platform.pathSeparator}engine.log',
      );
  try {
    final entry = '[${DateTime.now().toIso8601String()}] $message\n';
    final environment = message.startsWith('stderr: [bhe] environment ');
    final path = target.absolute.path;
    target.parent.createSync(recursive: true);
    if (target.existsSync() && target.lengthSync() > 2 * 1024 * 1024) {
      target.renameSync('${target.path}.1');
      final carried = _latestEnvironment[path];
      if (!environment && carried != null) {
        target.writeAsStringSync(carried, mode: FileMode.append);
      }
    }
    target.writeAsStringSync(entry, mode: FileMode.append);
    if (environment) _latestEnvironment[path] = entry;
  } on Object {
    // Logging must not interrupt the operation that produced the message.
  }
}

/// 界面层日志：写进同一个 engine.log（诊断复制已带它的尾部），一行一条，
/// 格式 `[级别] [模块] 内容`。写失败不抛。
void appLog(String level, String module, String message) =>
    appendEngineLog('[$level] [$module] $message');
