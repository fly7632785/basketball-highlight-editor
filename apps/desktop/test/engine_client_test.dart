import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/engine_client.dart';

/// 解析可用于运行假 Engine 的 Python 解释器。
///
/// 当前 shell 的 PATH 可能尚未包含新装的解释器,因此依次探测系统命令与
/// 仓库 .venv 中的解释器。
String _resolvePython() {
  final cwd = Directory.current.path;
  final candidates = <String>[
    if (Platform.isWindows) ...<String>[
      'python',
      '$cwd\\..\\..\\.venv\\Scripts\\python.exe',
    ] else ...<String>[
      'python3',
      'python',
      '$cwd/../../.venv/bin/python',
    ],
  ];
  for (final candidate in candidates) {
    try {
      final result = Process.runSync(candidate, const <String>['--version']);
      if (result.exitCode == 0) return candidate;
    } on ProcessException {
      // 尝试下一个候选。
    }
  }
  fail('未找到可运行假 Engine 的 Python 解释器');
}

/// 在 [directory] 下生成一个假的 basketball_engine 包。
///
/// [mainSource] 为 __main__.py 内容;EngineClient 会以
/// `python -m basketball_engine` 启动并通过 PYTHONPATH 找到该包。
void _writeFakeEngine(Directory directory, String mainSource) {
  final package = Directory('${directory.path}/basketball_engine')
    ..createSync();
  File('${package.path}/__init__.py').writeAsStringSync('');
  File('${package.path}/__main__.py').writeAsStringSync(mainSource);
}

void main() {
  test('clears running state when the engine process exits', () async {
    final directory = await Directory.systemTemp.createTemp('bhe-engine-');
    addTearDown(() => directory.delete(recursive: true));
    _writeFakeEngine(directory, 'raise SystemExit(0)\n');

    final client = EngineClient();
    addTearDown(client.dispose);
    await client.start(
      workingDirectory: directory.path,
      enginePythonPath: directory.path,
      pythonExecutable: _resolvePython(),
    );

    for (var attempt = 0; attempt < 50 && client.isRunning; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await Future<void>.delayed(Duration.zero);
    }

    expect(client.isRunning, isFalse);
  });

  test('times out a request when the engine stops responding', () async {
    final directory = await Directory.systemTemp.createTemp('bhe-engine-');
    addTearDown(() => directory.delete(recursive: true));
    _writeFakeEngine(
      directory,
      'import sys, time\n'
      'for line in sys.stdin:\n'
      '    time.sleep(5)\n',
    );

    final client = EngineClient(
      requestTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(client.dispose);
    await client.start(
      workingDirectory: directory.path,
      enginePythonPath: directory.path,
      pythonExecutable: _resolvePython(),
    );

    await expectLater(
      client.request('hello', const <String, dynamic>{}),
      throwsA(
        isA<EngineException>().having(
          (error) => error.code,
          'code',
          'ENGINE_TIMEOUT',
        ),
      ),
    );
  });
}
