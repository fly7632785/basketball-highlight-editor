import 'dart:io';

import 'package:desktop/core/app_diagnostics.dart';
import 'package:desktop/core/app_log.dart';
import 'package:desktop/core/diagnostics.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _VideoNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState(exportStartUnconfirmed: true);
  void setVideo(Map<String, dynamic>? video) =>
      state = state.copyWith(video: video);
}

void main() {
  setUp(() {
    final file = appLogFileOverride!;
    if (file.existsSync()) file.deleteSync();
  });

  String log() {
    final file = appLogFileOverride!;
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  group('卡顿判定', () {
    const interval = Duration(milliseconds: 250);
    const threshold = Duration(milliseconds: 1500);
    test('按时触发不算卡顿', () {
      expect(
        uiStallMilliseconds(
          elapsed: const Duration(milliseconds: 260),
          interval: interval,
          threshold: threshold,
        ),
        isNull,
      );
    });
    test('晚了超过阈值，返回卡了多久', () {
      expect(
        uiStallMilliseconds(
          elapsed: const Duration(milliseconds: 8250),
          interval: interval,
          threshold: threshold,
        ),
        8000,
      );
    });
  });

  test('会话开始一行带版本、系统、屏幕和缩放', () {
    final line = sessionStartLine(
      version: '0.1.14',
      mode: 'release',
      os: 'windows 10',
      arch: 'windows_x64',
      cpus: 8,
      locale: 'zh_CN',
      displays: ['view0 physical=2880x1800 dpr=2.0'],
      textScale: 1.25,
    );
    expect(line, contains('version=0.1.14'));
    expect(line, contains('mode=release'));
    expect(line, contains('physical=2880x1800 dpr=2.0'));
    expect(line, contains('textScale=1.25'));
  });

  test('视频规格描述不带路径，只留扩展名', () {
    final text = describeVideoForLog({
      'id': 'v1',
      'source_path': '/Users/someone/Movies/私人比赛.MP4',
      'width': 2688,
      'height': 1512,
      'fps': 29.97,
      'video_codec': 'hevc',
      'audio_codec': 'aac',
      'rotation': 90,
      'duration_ms': 1041000,
      'source_size_bytes': 5414000000,
    });
    expect(text, contains('2688x1512'));
    expect(text, contains('fps=29.97'));
    expect(text, contains('video=hevc'));
    expect(text, contains('ext=mp4'));
    expect(text, isNot(contains('someone')));
    expect(text, isNot(contains('私人比赛')));
  });

  test('appLog 记住最近一行，卡顿报警时用它说明卡在哪一步之后', () {
    appLog('info', 'export', '选择输出位置开始 mode=merge');
    expect(lastAppLogLine, '[info] [export] 选择输出位置开始 mode=merge');
  });

  test('换当前视频时写一行视频规格', () {
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(_VideoNotifier.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(projectProvider.notifier) as _VideoNotifier;
    notifier.setVideo({
      'id': 'v9',
      'source_path': '/a/b.mov',
      'width': 1920,
      'height': 1080,
      'fps': 60,
    });
    expect(log(), contains('[video] 当前视频 id=v9 1920x1080 fps=60'));
    expect(log(), contains('ext=mov'));
  });

  test('用户看到的每条提示都写进日志', () async {
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(_VideoNotifier.new)],
    );
    addTearDown(container.dispose);
    await container.read(projectProvider.notifier).export('merge');
    expect(log(), contains('[warn] [notice] 上一次导出启动结果未确认'));
  });

  test('诊断信息带上屏幕信息', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final report = await buildDiagnosticReport(
      environment: {
        'HOME': Directory.systemTemp.path,
        'USERPROFILE': Directory.systemTemp.path,
        'LOCALAPPDATA': Directory.systemTemp.path,
      },
    );
    expect(report, contains('屏幕: '));
  });

  group('日志文本兜底', () {
    test('遮掉 URL 查询参数和 Bearer 里的凭据', () {
      final text = sanitizeLogText(
        'GET https://x.example/a?token=abc123&name=ok&api_key=zzz Authorization: Bearer eyJhbGciOi.payload.sig',
      );
      expect(text, isNot(contains('abc123')));
      expect(text, isNot(contains('zzz')));
      expect(text, isNot(contains('eyJhbGciOi')));
      expect(text, contains('name=ok'));
    });

    test('遮掉 password=… 这类键值', () {
      final text = sanitizeLogText('login failed password=hunter2 user=bob');
      expect(text, isNot(contains('hunter2')));
      expect(text, contains('user=bob'));
    });

    test('过长的文本被截断并注明原长', () {
      final text = sanitizeLogText('x' * 5000);
      expect(text.length, lessThan(900));
      expect(text, contains('已截断'));
    });

    test('appLog 写进文件的内容也经过兜底', () {
      appLog('error', 'player', '打开失败 https://h/v.mp4?token=SECRETVALUE');
      expect(log(), isNot(contains('SECRETVALUE')));
    });

    test('卡顿报警不会成为「最后一步」，不会层层嵌套', () {
      appLog('info', 'export', '开始导出');
      appLog('warn', 'ui', '界面线程卡顿约 3000 ms；卡顿前最后记录的一步：$lastAppLogLine');
      appLog('warn', 'ui', '界面线程卡顿约 3000 ms；卡顿前最后记录的一步：$lastAppLogLine');
      expect(lastAppLogLine, '[info] [export] 开始导出');
      expect('卡顿前最后记录的一步'.allMatches(log()).length, 2);
      expect(log(), isNot(contains('卡顿前最后记录的一步：[warn]')));
    });
  });
}
