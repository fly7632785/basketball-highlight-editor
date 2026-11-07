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
      'source_path': '/Us' 'ers/someone/Movies/私人比赛.MP4',
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

    test('绝对路径统一换成占位，只留扩展名，不留用户名', () {
      final macOs = sanitizeLogText('ffmpeg 退出码 1: /Us' 'ers/bob/Movies/game.mp4: No such file');
      expect(macOs, isNot(contains('bob')));
      expect(macOs, contains('<path>.mp4'));
      final windows = sanitizeLogText(r'open C:\Us' r'ers\alice\Videos\clip.mov failed');
      expect(windows, isNot(contains('alice')));
      expect(windows, contains('<path>.mov'));
      final unc = sanitizeLogText(r'cannot read \\nas\share\a.mkv');
      expect(unc, isNot(contains('nas')));
      final fileUrl = sanitizeLogText('打开 file:///Us' 'ers/bob/a.mp4 失败');
      expect(fileUrl, isNot(contains('bob')));
      expect(fileUrl, contains('<path>.mp4'));
      final tmp = sanitizeLogText('写入 "/private/var/folders/xx/T/bhe-cache/x.part" 失败');
      expect(tmp, isNot(contains('folders')));
    });

    test('网址、比例、页面路径不被当成文件路径误遮', () {
      const text = 'GET https://dl.envsystem.top/BHE-latest.dmg 已用 3/4 nav /home → /review';
      expect(sanitizeLogText(text), text);
    });

    test('超长文本先截断再过正则，耗时有上界且凭据照样被遮', () {
      final watch = Stopwatch()..start();
      final text = sanitizeLogText('password=SECRET1 ${'password ' * 200000}');
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(200));
      expect(text, isNot(contains('SECRET1')));
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

  group('HDR 判定（决定是否给 mpv 设色调映射）', () {
    Map<String, dynamic> video(Map<String, dynamic> overrides) => {
      'pix_fmt': 'yuv420p10le',
      'color_transfer': 'smpte2084',
      'color_primaries': 'bt2020',
      'color_space': 'bt2020nc',
      ...overrides,
    };

    test('没有视频信息时不是 HDR', () {
      expect(isHdrVideoForPlayer(null), isFalse);
    });

    test('普通 8bit SDR 不是 HDR', () {
      expect(
        isHdrVideoForPlayer(video({
          'pix_fmt': 'yuv420p',
          'color_transfer': 'bt709',
          'color_primaries': 'bt709',
          'color_space': 'bt709',
        })),
        isFalse,
      );
    });

    test('PQ + 10bit + BT.2020 是 HDR', () {
      expect(isHdrVideoForPlayer(video({})), isTrue);
    });

    test('HLG 用 p010le 也是 HDR', () {
      expect(
        isHdrVideoForPlayer(video({
          'pix_fmt': 'p010le',
          'color_transfer': 'arib-std-b67',
        })),
        isTrue,
      );
    });

    test('bt2020c 也算 HDR，大小写不敏感', () {
      expect(
        isHdrVideoForPlayer(video({
          'pix_fmt': 'YUV420P10LE',
          'color_transfer': 'SMPTE2084',
          'color_primaries': 'BT2020',
          'color_space': 'BT2020C',
        })),
        isTrue,
      );
    });

    test('缺色彩元数据时保守判为非 HDR', () {
      expect(
        isHdrVideoForPlayer({'pix_fmt': 'yuv420p10le', 'color_transfer': 'unknown'}),
        isFalse,
      );
      expect(isHdrVideoForPlayer({'pix_fmt': 'yuv420p10le'}), isFalse);
    });

    test('10bit + PQ 但非 BT.2020 色彩空间不算 HDR', () {
      expect(
        isHdrVideoForPlayer(video({
          'color_primaries': 'bt709',
          'color_space': 'bt709',
        })),
        isFalse,
      );
      expect(
        isHdrVideoForPlayer(video({
          'pix_fmt': 'yuv420p', // 8bit
        })),
        isFalse,
      );
    });

    test('色调映射属性与导出对齐', () {
      expect(hdrToneMappingProperties['tone-mapping'], 'hable');
      expect(hdrToneMappingProperties['target-prim'], 'bt.709');
      expect(hdrToneMappingProperties['target-trc'], 'bt.1886');
    });
  });


  group('HDR 用过后切到 SDR 要复位（同一个播放器）', () {
    Map<String, dynamic> hdr() => {
      'pix_fmt': 'yuv420p10le',
      'color_transfer': 'smpte2084',
      'color_primaries': 'bt2020',
      'color_space': 'bt2020nc',
    };
    Map<String, dynamic> sdr() => {
      'pix_fmt': 'yuv420p',
      'color_transfer': 'bt709',
      'color_primaries': 'bt709',
      'color_space': 'bt709',
    };

    /// 模拟一个 player：记录属性写入，`applied` 就是 Expando 里记的标记。
    Future<List<List<String>>> run(
      List<Map<String, dynamic>?> videos, {
      Set<String> throwOn = const {},
    }) async {
      final calls = <List<String>>[];
      var applied = false;
      for (final video in videos) {
        applied = await applyToneMappingStep(
          alreadyApplied: applied,
          video: video,
          where: '测试',
          setProperty: (name, value) async {
            calls.add([name, value]);
            if (throwOn.contains(name)) throw StateError('写入 $name 失败');
          },
        );
      }
      return calls;
    }

    test('从未设过的播放器放 SDR：一次 setProperty 都不调', () async {
      expect(await run([sdr(), sdr()]), isEmpty);
      expect(await run([null]), isEmpty);
    });

    test('HDR 后再 SDR：复位调用 4 次且值为 auto', () async {
      final calls = await run([hdr(), sdr()]);
      expect(calls.length, 8); // 先设 4 条 HDR，再复位 4 条
      expect(calls.take(4).map((c) => c[0]).toSet(), hdrToneMappingProperties.keys.toSet());
      final reset = calls.skip(4).toList();
      expect(reset.length, 4);
      expect(reset.map((c) => c[0]).toSet(), hdrToneMappingResetProperties.keys.toSet());
      expect(reset.every((c) => c[1] == 'auto'), isTrue);
    });

    test('复位时某条抛异常：其余仍写完，标记仍清除', () async {
      final calls = await run([hdr(), sdr()], throwOn: {'target-trc'});
      final reset = calls.skip(4).map((c) => c[0]).toList();
      // target-trc 抛了异常，但后面两条 target-prim 照样写入。
      expect(reset, ['tone-mapping', 'hdr-compute-peak', 'target-trc', 'target-prim']);
      // 复位后标记应清除：再来一次 SDR 不应该再调。
      final again = await run([hdr(), sdr(), sdr()]);
      expect(again.skip(8), isEmpty);
    });

    test('复位后再放 SDR：不再调用 setProperty', () async {
      final calls = await run([hdr(), sdr(), sdr(), sdr()]);
      expect(calls.length, 8); // 只有第一次 HDR 的 4 条和第一次复位的 4 条
    });

    test('HDR 之后再 HDR：不重复设置', () async {
      final calls = await run([hdr(), hdr()]);
      expect(calls.length, 4);
    });
  });

}
