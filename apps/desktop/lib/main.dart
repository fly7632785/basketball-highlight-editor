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
    titleBarStyle: TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setBrightness(brightness);
    await windowManager.show();
    await windowManager.focus();
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
