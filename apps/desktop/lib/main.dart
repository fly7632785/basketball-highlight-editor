import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/session_provider.dart';
import 'providers/theme_provider.dart';
import 'theme/app_colors.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final themeMode = await loadSavedThemeMode();
  ThemeModeNotifier.startupMode = themeMode;
  final brightness = switch (themeMode) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
  };
  final colors = brightness == Brightness.light
      ? lightAppColors
      : darkAppColors;
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(1440, 900),
    minimumSize: const Size(1180, 720),
    center: true,
    backgroundColor: colors.background,
    // Windows 隐藏原生标题栏由应用自绘(消除 Win10 灰色边框);
    // macOS 保持原生标题栏,避免红绿灯按钮叠在内容上。
    titleBarStyle: Platform.isWindows
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (Platform.isWindows) {
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(false);
    }
    await windowManager.setBrightness(brightness);
    // 等首帧渲染完成后再显示窗口,避免深色主题下露出原生白底
    // (Windows 上 debug 首帧较慢,白屏会被放大)。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.show();
      await windowManager.focus();
    });
  });
  final container = ProviderContainer();
  // 后台预热 Engine（Python 子进程），打开项目时若已就绪则跳过冷启动。
  container.read(engineBootstrapProvider.notifier).ensure();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CourtsideApp(),
    ),
  );
}
