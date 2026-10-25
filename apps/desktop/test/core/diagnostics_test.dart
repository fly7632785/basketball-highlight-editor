import 'dart:io';

import 'package:desktop/core/diagnostics.dart';
import 'package:desktop/core/engine_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('诊断信息带上错误和最近日志，并隐藏用户目录和用户名', () async {
    final home = await Directory.systemTemp.createTemp('bhe-diag');
    addTearDown(() => home.delete(recursive: true));
    final env = {
      'HOME': home.path,
      'USERPROFILE': home.path,
      'LOCALAPPDATA': home.path,
      'USER': 'alice',
      'USERNAME': 'alice',
    };
    final dir = Directory(engineLogDirectory(env))..createSync(recursive: true);
    File(
      '${dir.path}${Platform.pathSeparator}engine.log.1',
    ).writeAsStringSync(List.generate(5, (i) => 'old $i').join('\n'));
    File('${dir.path}${Platform.pathSeparator}engine.log').writeAsStringSync(
      [
        'new 0',
        'open ${home.path}/Movies/game.mp4',
        // 拼接写法，避免仓库里出现 Windows 用户目录的完整路径。
        r'open D:' r'\Users\alice\clip.mp4',
      ].join('\n'),
    );

    final report = await buildDiagnosticReport(
      error: 'create_proxy.py 执行失败: boom',
      environment: env,
      logLines: 6,
    );

    expect(report, contains('版本: '));
    expect(report, contains('create_proxy.py 执行失败: boom'));
    expect(report, contains('open ~/Movies/game.mp4'));
    expect(report, contains(r'D:' r'\Users\<user>\clip.mp4'));
    expect(report, isNot(contains(home.path)));
    // 当前日志 3 行不够 6 行，从轮换的旧日志补最后 3 行。
    expect(report, contains('old 2'));
    expect(report, isNot(contains('old 1')));
  });

  test('没有日志时说明找不到，不报错', () async {
    final home = await Directory.systemTemp.createTemp('bhe-diag-empty');
    addTearDown(() => home.delete(recursive: true));
    final report = await buildDiagnosticReport(
      environment: {'HOME': home.path, 'LOCALAPPDATA': home.path},
    );
    expect(report, contains('(没有找到运行日志)'));
    expect(report, isNot(contains('错误:')));
  });
}
