// test/providers/session_theme_provider_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:desktop/core/engine_client.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/providers/session_provider.dart';
import 'package:desktop/providers/theme_provider.dart';

void main() {
  group('findRuntimeRoot', () {
    late Directory tmpDir;
    late String runtimeRoot;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('runtime_root_test_');
      runtimeRoot = tmpDir.path;
      Directory('$runtimeRoot/engine/python').createSync(recursive: true);
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('BHE_RUNTIME_ROOT 命中且 engine/python 存在时返回该路径', () {
      final result = findRuntimeRoot(
        env: <String, String>{'BHE_RUNTIME_ROOT': runtimeRoot},
        resolvedExecutable: '/dummy/app',
        currentDir: '/elsewhere',
      );
      expect(result, runtimeRoot);
    });

    test('BHE_REPO_ROOT 命中时返回该路径', () {
      final result = findRuntimeRoot(
        env: <String, String>{'BHE_REPO_ROOT': runtimeRoot},
        resolvedExecutable: '/dummy/app',
        currentDir: '/elsewhere',
      );
      expect(result, runtimeRoot);
    });

    test('BHE_RUNTIME_ROOT 优先级高于 BHE_REPO_ROOT', () {
      final result = findRuntimeRoot(
        env: <String, String>{
          'BHE_REPO_ROOT': '/nonexistent/repo',
          'BHE_RUNTIME_ROOT': runtimeRoot,
        },
        resolvedExecutable: '/dummy/app',
        currentDir: '/elsewhere',
      );
      expect(result, runtimeRoot);
    });

    test('env 无 runtime 相关且无候选存在时返回 null', () {
      final result = findRuntimeRoot(
        env: const <String, String>{},
        resolvedExecutable: '/nonexistent/app',
        currentDir: '/nonexistent/nowhere',
      );
      expect(result, isNull);
    });

    test('currentDir 自身是 runtime 根时返回 currentDir', () {
      final result = findRuntimeRoot(
        env: const <String, String>{},
        resolvedExecutable: '/dummy/app',
        currentDir: runtimeRoot,
      );
      expect(result, runtimeRoot);
    });

    test('从 apps/desktop 嵌套目录向上找到项目根目录', () {
      final nestedDir = Directory('$runtimeRoot/apps/desktop')
        ..createSync(recursive: true);
      final result = findRuntimeRoot(
        env: const <String, String>{},
        resolvedExecutable: '/dummy/app',
        currentDir: nestedDir.path,
      );
      expect(result, runtimeRoot);
    });

    test('appContents/Resources/runtime 候选命中时返回该路径', () {
      // 构造 <tmp>/Foo.app/Contents/Resources/runtime/engine/python
      final appDir = Directory('${tmpDir.path}/Foo.app/Contents')
        ..createSync(recursive: true);
      final resourcesRuntime = '${appDir.path}/Resources/runtime';
      Directory('$resourcesRuntime/engine/python').createSync(recursive: true);
      final executable = File('${appDir.path}/MacOS/Foo')
        ..createSync(recursive: true);
      final result = findRuntimeRoot(
        env: const <String, String>{},
        resolvedExecutable: executable.path,
        currentDir: '/elsewhere',
      );
      expect(result, resourcesRuntime);
    });

    test('从 macOS Debug app 包路径向上找到开发仓库运行时', () {
      final executable = File(
        '$runtimeRoot/build/macos/Build/Products/Debug/desktop.app/Contents/MacOS/desktop',
      )..createSync(recursive: true);

      final result = findRuntimeRoot(
        env: const <String, String>{},
        resolvedExecutable: executable.path,
        currentDir: '/elsewhere',
      );

      expect(result, runtimeRoot);
    });
  });

  group('findPython', () {
    late Directory tmpDir;
    late String runtimeRoot;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('runtime_python_test_');
      runtimeRoot = tmpDir.path;
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('BHE_PYTHON 指向存在文件时返回该路径', () {
      final pythonFile = File('${tmpDir.path}/custom_python')
        ..createSync(recursive: true);
      final result = findPython(
        runtimeRoot,
        env: <String, String>{'BHE_PYTHON': pythonFile.path},
      );
      expect(result, pythonFile.path);
    });

    test('runtimeRoot 内置 Python 布局存在时返回该路径', () {
      // macOS 打包布局为 python/bin/python3;Windows venv 布局为
      // .venv/Scripts/python.exe。按当前平台构造对应候选。
      final relative = Platform.isWindows
          ? '/.venv/Scripts/python.exe'
          : '/python/bin/python3';
      final pythonFile = File('$runtimeRoot$relative')
        ..createSync(recursive: true);
      final result = findPython(runtimeRoot, env: const <String, String>{});
      expect(result, pythonFile.path);
    });

    test('候选均不存在且无 BHE_ALLOW_SYSTEM_PYTHON 时抛 SessionStateException', () {
      expect(
        () => findPython(runtimeRoot, env: const <String, String>{}),
        throwsA(isA<SessionStateException>()),
      );
    });

    test('BHE_ALLOW_SYSTEM_PYTHON=1 时回退系统 Python 命令', () {
      final result = findPython(
        runtimeRoot,
        env: const <String, String>{'BHE_ALLOW_SYSTEM_PYTHON': '1'},
      );
      expect(result, Platform.isWindows ? 'python' : 'python3');
    });
  });

  group('engineBootstrapProvider', () {
    test('build() 初值为 loading', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(engineBootstrapProvider).isLoading, isTrue);
    });

    // ensure() 依赖 Platform.environment/Directory.current,无法在测试中注入;
    // 这里用 FakeEngineClient 短路子进程,宽松断言 ensure 完结后 state 已结算。
    // 沙盒外运行时：命中开发机默认项目路径
    // 候选时为 AsyncData(true);无 runtime 时为 AsyncError。
    test('ensure() 完结后 state 不再 loading', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          engineClientProvider.overrideWithValue(FakeEngineClient()),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(engineBootstrapProvider.notifier);
      await notifier.ensure();
      final state = container.read(engineBootstrapProvider);
      expect(state.isLoading, isFalse);
    });

    test('concurrent ensure shares one engine startup', () async {
      final client = FakeEngineClient(
        startDelay: const Duration(milliseconds: 20),
      );
      final container = ProviderContainer(
        overrides: <Override>[engineClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(engineBootstrapProvider.notifier);

      await Future.wait([notifier.ensure(), notifier.ensure()]);

      expect(client.startCalls, 1);
      expect(client.helloCalls, 1);
    });
  });

  group('themeModeProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('默认 ThemeMode.dark', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(themeModeProvider), ThemeMode.dark);
    });

    test('set(dark) 更新 state 并持久化', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(themeModeProvider.notifier);
      await notifier.set(ThemeMode.dark);
      expect(container.read(themeModeProvider), ThemeMode.dark);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('courtside.theme_mode'), 'dark');
    });

    test('set(light) 后 state 为 light', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(themeModeProvider.notifier).set(ThemeMode.light);
      expect(container.read(themeModeProvider), ThemeMode.light);
    });

    test('已持久化的值在新建 container 中通过 _load 应用', () async {
      // 先写入 dark
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('courtside.theme_mode', 'dark');
      // SharedPreferences 单例缓存:setMockInitialValues 后的实例已持有新值
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 触发 build → _load() 异步执行
      container.read(themeModeProvider);
      // 等待 _load 完成
      await Future<void>.delayed(Duration.zero);
      expect(container.read(themeModeProvider), ThemeMode.dark);
    });
  });
}

class FakeEngineClient extends EngineClient {
  FakeEngineClient({this.startDelay = Duration.zero});

  final Duration startDelay;
  int startCalls = 0;
  int helloCalls = 0;
  bool running = false;

  @override
  bool get isRunning => running;

  @override
  Future<void> start({
    required String workingDirectory,
    required String enginePythonPath,
    String pythonExecutable = 'python3',
    String? extraPath,
  }) async {
    startCalls++;
    await Future<void>.delayed(startDelay);
    running = true;
  }

  @override
  Future<Map<String, dynamic>> request(
    String command,
    Map<String, dynamic> payload,
  ) async {
    if (command == 'hello') {
      helloCalls++;
      return <String, dynamic>{};
    }
    throw StateError('unexpected command: $command');
  }
}
