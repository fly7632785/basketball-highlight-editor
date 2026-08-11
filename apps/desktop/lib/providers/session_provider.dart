// lib/providers/session_provider.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine_client.dart';
import '../core/engine_session.dart';
import '../core/project_session.dart';

/// 单进程内共享的 EngineClient。Provider dispose 时关闭子进程。
final Provider<EngineClient> engineClientProvider = Provider<EngineClient>((
  ref,
) {
  final client = EngineClient();
  ref.onDispose(client.dispose);
  return client;
});

/// 纯函数:解析 Engine 运行根目录。
///
/// 从 app.dart:_findRuntimeRoot 抽出,接受 env 注入(不直接读
/// Platform.environment),便于测试候选解析分支。
String? findRuntimeRoot({
  required Map<String, String> env,
  required String resolvedExecutable,
  required String currentDir,
}) {
  final configured = env['BHE_REPO_ROOT'];
  final configuredRuntime = env['BHE_RUNTIME_ROOT'];
  final executable = File(resolvedExecutable);
  final appContents = executable.parent.parent;
  final candidates = <String>[
    if (configuredRuntime != null && configuredRuntime.isNotEmpty)
      configuredRuntime,
    if (configured != null && configured.isNotEmpty) configured,
    '${appContents.path}/Resources/runtime',
  ];

  var executableDirectory = executable.parent;
  for (var depth = 0; depth <= 10; depth++) {
    candidates.add(executableDirectory.path);
    final parent = executableDirectory.parent;
    if (parent.path == executableDirectory.path) break;
    executableDirectory = parent;
  }

  var directory = Directory(currentDir);
  for (var depth = 0; depth <= 6; depth++) {
    candidates.add(directory.path);
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }

  for (final path in candidates) {
    if (Directory('$path/engine/python').existsSync()) return path;
  }
  return null;
}

/// 纯函数:解析 Python 可执行文件路径。
///
/// 从 app.dart:_findPython 抽出,接受 env 注入,便于测试候选与 fallback 分支。
String findPython(String runtimeRoot, {required Map<String, String> env}) {
  final configured = env['BHE_PYTHON'];
  final candidates = <String>[
    if (configured != null && configured.isNotEmpty) configured,
    '$runtimeRoot/python/bin/python3',
    '$runtimeRoot/.venv/bin/python',
    '$runtimeRoot/.venv/bin/python3',
  ];
  for (final path in candidates) {
    if (File(path).existsSync() || !path.contains(Platform.pathSeparator)) {
      return path;
    }
  }
  if (env['BHE_ALLOW_SYSTEM_PYTHON'] == '1') {
    return 'python3';
  }
  throw const SessionStateException(
    '未找到 Python 运行时。请设置 BHE_PYTHON，或把 Python 放入应用运行时目录。',
  );
}

/// Engine 启动状态。
///
/// 迁移自 app.dart:_ensureEngine。`build()` 初值 loading,`ensure()`
/// 用 `AsyncValue.guard` 包裹原启动逻辑(findRuntimeRoot→findPython→
/// client.start→engine.hello),失败时 state 转为 AsyncError。
class EngineBootstrapNotifier extends Notifier<AsyncValue<bool>> {
  Future<void>? _ensureInFlight;

  @override
  AsyncValue<bool> build() => const AsyncValue<bool>.loading();

  /// 等价 app.dart:_ensureEngine。已就绪时直接返回,否则重新跑启动流程。
  Future<void> ensure() {
    final client = ref.read(engineClientProvider);
    if (state.valueOrNull == true && client.isRunning) {
      return Future<void>.value();
    }
    final current = _ensureInFlight;
    if (current != null) return current;
    final future = _ensure();
    _ensureInFlight = future;
    return future.whenComplete(() {
      if (identical(_ensureInFlight, future)) _ensureInFlight = null;
    });
  }

  Future<void> _ensure() async {
    final client = ref.read(engineClientProvider);
    state = const AsyncValue<bool>.loading();
    state = await AsyncValue.guard(() async {
      final env = Platform.environment;
      final runtimeRoot = findRuntimeRoot(
        env: env,
        resolvedExecutable: Platform.resolvedExecutable,
        currentDir: Directory.current.path,
      );
      if (runtimeRoot == null) {
        throw const SessionStateException(
          '未找到本地 Engine 运行目录。开发环境请从项目根目录启动，正式版本请先完成运行时打包。',
        );
      }
      final pythonPath = findPython(runtimeRoot, env: env);
      final runtimeBin = Directory('$runtimeRoot/bin').existsSync()
          ? '$runtimeRoot/bin'
          : null;
      await client.start(
        workingDirectory: runtimeRoot,
        enginePythonPath: '$runtimeRoot/engine/python',
        pythonExecutable: pythonPath,
        extraPath: runtimeBin,
      );
      await EngineSession(client).hello();
      return true;
    });
  }

  void markUnavailable(Object error, [StackTrace? stackTrace]) {
    state = AsyncValue<bool>.error(error, stackTrace ?? StackTrace.current);
  }
}

final NotifierProvider<EngineBootstrapNotifier, AsyncValue<bool>>
engineBootstrapProvider =
    NotifierProvider<EngineBootstrapNotifier, AsyncValue<bool>>(
      EngineBootstrapNotifier.new,
    );
