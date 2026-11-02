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
}
