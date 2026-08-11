import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/session_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1440, 900),
    minimumSize: Size(1180, 720),
    center: true,
    backgroundColor: Color(0xFF0B0E14),
    titleBarStyle: TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setBrightness(Brightness.dark);
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
