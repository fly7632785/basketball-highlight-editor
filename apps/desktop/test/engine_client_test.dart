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
    ] else ...<String>['python3', 'python', '$cwd/../../.venv/bin/python'],
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
  test(
    'matches out-of-order preview and player responses by request id',
    () async {
      final directory = await Directory.systemTemp.createTemp('bhe-engine-');
      addTearDown(() => directory.delete(recursive: true));
      _writeFakeEngine(directory, '''
import json, sys
pending = []
for line in sys.stdin:
    pending.append(json.loads(line))
    if len(pending) == 2:
        for request in reversed(pending):
            print(json.dumps({"request_id": request["request_id"], "ok": True,
                              "payload": {"command": request["command"]}}), flush=True)
        pending.clear()
''');
      final client = EngineClient();
      addTearDown(client.dispose);
      await client.start(
        workingDirectory: directory.path,
        enginePythonPath: directory.path,
        pythonExecutable: _resolvePython(),
      );
      final preview = client.request('extract_preview', {});
      final player = client.request('create_player', {});
      expect((await player)['command'], 'create_player');
      expect((await preview)['command'], 'extract_preview');
    },
  );

  test('writes start, stderr, failed requests and exit to the log file', () async {
    final directory = await Directory.systemTemp.createTemp('bhe-engine-');
    addTearDown(() => directory.delete(recursive: true));
    _writeFakeEngine(directory, '''
import json, sys
print("ffmpeg not found", file=sys.stderr, flush=True)
request = json.loads(sys.stdin.readline())
print(json.dumps({"request_id": request["request_id"], "ok": False,
                  "error": {"code": "MEDIA_TOOL_MISSING", "message": "ffmpeg"}}), flush=True)
''');
    final logFile = File('${directory.path}/logs/engine.log');
    final client = EngineClient(logFile: logFile);
    addTearDown(client.dispose);
    await client.start(
      workingDirectory: directory.path,
      enginePythonPath: directory.path,
      pythonExecutable: _resolvePython(),
    );
    await expectLater(
      client.request('inspect_video', {}),
      throwsA(isA<EngineException>()),
    );
    while (client.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final log = logFile.readAsStringSync();
    expect(log, contains('start python='));
    expect(log, contains('stderr: ffmpeg not found'));
    expect(log, contains('inspect_video failed: {"code":"MEDIA_TOOL_MISSING"'));
    expect(log, contains('exit code=0'));
  });

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
