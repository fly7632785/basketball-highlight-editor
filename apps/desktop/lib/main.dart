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
