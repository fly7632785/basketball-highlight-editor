import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/core/app_log.dart';
import 'package:desktop/providers/theme_provider.dart';

void main() {
  test('appLog writes level, module and message to the log file', () {
    final file = appLogFileOverride!;
    if (file.existsSync()) file.deleteSync();
    appLog('info', 'export', '开始导出 mode=merge');
    final line = file.readAsLinesSync().single;
    expect(line, matches(r'^\[[^\]]+\] \[info\] \[export\] 开始导出 mode=merge$'));
  });

  test('a swallowed error on a failure path is written to the log', () async {
    final file = appLogFileOverride!;
    if (file.existsSync()) file.deleteSync();
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadSavedThemeMode();
    final log = file.readAsStringSync();
    expect(log, contains('[warn] [theme_provider] loadSavedThemeMode'));
  });

  test('appLog never throws when the log cannot be written', () {
    final bad = Directory.systemTemp.createTempSync('bhe_bad_log_');
    addTearDown(() => bad.deleteSync(recursive: true));
    final previous = appLogFileOverride;
    appLogFileOverride = File(bad.path); // 目录当文件写：必然失败
    addTearDown(() => appLogFileOverride = previous);
    expect(() => appLog('error', 'export', 'x'), returnsNormally);
  });
}
