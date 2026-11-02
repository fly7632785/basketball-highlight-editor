import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app_log.dart';
import 'diagnostics.dart' show appVersion;

/// 界面线程卡顿的判定：监控定时器本该每 [interval] 触发一次，实际间隔超出
/// [threshold] 就算卡顿，返回卡了多久（毫秒）；否则返回 null。
int? uiStallMilliseconds({
  required Duration elapsed,
  required Duration interval,
  required Duration threshold,
}) {
  final late = elapsed - interval;
  return late >= threshold ? late.inMilliseconds : null;
}

/// 一行「会话开始」日志：版本、系统、屏幕和缩放。用户反馈的日志里先看这一行，
/// 就知道是哪个版本、什么系统、窗口多大、缩放多少。
String sessionStartLine({
  required String version,
  required String mode,
  required String os,
  required String arch,
  required int cpus,
  required String locale,
  required List<String> displays,
  required double textScale,
}) =>
    '会话开始 version=$version mode=$mode os=$os arch=$arch cpus=$cpus '
    'locale=$locale textScale=$textScale displays=[${displays.join('; ')}]';

String describeViews(Iterable<ui.FlutterView> views) => [
  for (final view in views)
    'view${view.viewId} physical=${view.physicalSize.width.round()}x${view.physicalSize.height.round()} '
        'dpr=${view.devicePixelRatio}',
].join('; ');

/// 启动时调用一次：写「会话开始」，并开始记录窗口尺寸/缩放变化、前后台切换，
/// 以及界面线程卡顿（Windows「点了没反应」这类问题靠它定位卡在哪一步之后）。
class AppDiagnostics with WidgetsBindingObserver {
  AppDiagnostics._();

  static AppDiagnostics? _instance;

  static void start() {
    if (_instance != null) return;
    final diagnostics = AppDiagnostics._();
    _instance = diagnostics;
    final binding = WidgetsBinding.instance;
    binding.addObserver(diagnostics);
    final dispatcher = binding.platformDispatcher;
    appLog(
      'info',
      'app',
      sessionStartLine(
        version: appVersion,
        mode: kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
        os: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        arch: '${Abi.current()}',
        cpus: Platform.numberOfProcessors,
        locale: Platform.localeName,
        displays: [describeViews(dispatcher.views)],
        textScale: dispatcher.textScaleFactor,
      ),
    );
    diagnostics._startWatchdog();
  }

  static const _interval = Duration(milliseconds: 250);
  static const _stallThreshold = Duration(milliseconds: 1500);

  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastTick = Duration.zero;
  bool _foreground = true;
  Timer? _metricsDebounce;

  void _startWatchdog() {
    _lastTick = _clock.elapsed;
    Timer.periodic(_interval, (_) {
      final now = _clock.elapsed;
      final elapsed = now - _lastTick;
      _lastTick = now;
      // 窗口在后台/最小化时系统会降频定时器，不算卡顿。
      if (!_foreground) return;
      final stalled = uiStallMilliseconds(
        elapsed: elapsed,
        interval: _interval,
        threshold: _stallThreshold,
      );
      if (stalled != null) {
        appLog(
          'warn',
          'ui',
          '界面线程卡顿约 $stalled ms；卡顿前最后记录的一步：$lastAppLogLine',
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _lastTick = _clock.elapsed;
    appLog('info', 'app', '应用状态 ${state.name}');
  }

  @override
  void didChangeMetrics() {
    _metricsDebounce?.cancel();
    _metricsDebounce = Timer(const Duration(milliseconds: 500), () {
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      appLog(
        'info',
        'app',
        '窗口或缩放变化 ${describeViews(dispatcher.views)} textScale=${dispatcher.textScaleFactor}',
      );
    });
  }
}

/// 日志里描述一段视频：只写分辨率、帧率、编码、时长、大小和扩展名，不写路径。
String describeVideoForLog(Map<String, dynamic>? video) {
  if (video == null) return '(无)';
  final path = video['source_path']?.toString() ?? '';
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 || dot < path.length - 6 ? '?' : path.substring(dot + 1).toLowerCase();
  return 'id=${video['id']} ${video['width']}x${video['height']} '
      'fps=${video['fps']} video=${video['video_codec']} audio=${video['audio_codec']} '
      'rotation=${video['rotation']} duration_ms=${video['duration_ms']} '
      'size=${video['source_size_bytes']} ext=$ext';
}

/// 播放器出错、mpv 报错都写进日志；[where] 说明是哪个页面的播放器。
Player createLoggedPlayer(String where) {
  final player = Player();
  player.stream.error.listen((error) {
    appLog('error', 'player', '$where 播放器报错: $error');
  });
  player.stream.log.listen((entry) {
    if (entry.level == 'error' || entry.level == 'fatal') {
      appLog('error', 'player', '$where mpv ${entry.prefix}: ${entry.text.trim()}');
    }
  });
  return player;
}

/// 带耗时地记录打开视频：播放器 open 慢或失败时，日志里能看出是哪个文件类型、卡了多久。
Future<void> openLoggedMedia(Player player, String where, String path) async {
  final watch = Stopwatch()..start();
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '?' : path.substring(dot + 1).toLowerCase();
  try {
    await player.open(Media(Uri.file(path).toString()), play: false);
    appLog('info', 'player', '$where 打开视频 ext=$ext 用时 ${watch.elapsedMilliseconds}ms');
  } catch (error) {
    appLog('error', 'player', '$where 打开视频失败 ext=$ext 用时 ${watch.elapsedMilliseconds}ms: $error');
    rethrow;
  }
}
