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
void appLog(String level, String module, String message) {
  final line = '[$level] [$module] ${sanitizeLogText(message)}';
  // 卡顿报警自己不算「最后一步」，否则连续卡顿时报警文字会一层层嵌套变长。
  if (module != 'ui') lastAppLogLine = line;
  appendEngineLog(line);
}

const _maxLogMessageLength = 800;
const _maxScanLength = 4000;

final _secretPatterns = <(RegExp, String)>[
  // URL 查询参数里常见的凭据
  (RegExp(r'([?&](?:token|access_token|key|api_key|apikey|secret|sig|signature|password|pwd)=)[^&\s"]+', caseSensitive: false), r'$1***'),
  // Authorization / Bearer
  (RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]+', caseSensitive: false), r'$1***'),
  // key: value / key=value 形式的凭据
  (RegExp(r'((?:token|secret|password|passwd|api[_-]?key|authorization)["\s]*[:=]["\s]*)[^\s,;"}&]+', caseSensitive: false), r'$1***'),
];

/// 写日志前对文本限长并遮掉常见的凭据样式（URL 查询参数、Bearer、token=…）。
/// 只是兜底，不能当作脱敏保证；日志里本来就不应该放密钥。
String sanitizeLogText(String text) {
  // 先按上限截断再跑正则：超长异常文本不会让界面线程在正则上花时间；
  // 最终只保留前 800 个字符，所以 4000 之后的内容本来就不会写出。
  var result = text.length > _maxScanLength ? text.substring(0, _maxScanLength) : text;
  for (final (pattern, replacement) in _secretPatterns) {
    result = result.replaceAllMapped(pattern, (match) {
      var out = replacement;
      for (var i = 1; i <= match.groupCount; i++) {
        out = out.replaceAll('\$$i', match.group(i) ?? '');
      }
      return out;
    });
  }
  if (result.length > _maxLogMessageLength) {
    result = '${result.substring(0, _maxLogMessageLength)}…(已截断，原长 ${text.length})';
  }
  return result;
}

/// 界面层最近写的一行，卡顿监控报警时用它说明「卡在哪一步之后」。
String lastAppLogLine = '';

final _lastThrottledLog = <String, DateTime>{};

/// 同类高频事件（拖动、连续切页等）用 [key] 节流：同一 key 至少间隔 [interval] 才写一行。
/// 只影响日志，不影响业务；写失败同样不抛。
void appLogThrottled(
  String key,
  String level,
  String module,
  String message, {
  Duration interval = const Duration(seconds: 1),
}) {
  final now = DateTime.now();
  final previous = _lastThrottledLog[key];
  if (previous != null && now.difference(previous) < interval) return;
  _lastThrottledLog[key] = now;
  appLog(level, module, message);
}
