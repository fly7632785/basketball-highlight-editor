import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/engine_client.dart';

void main() {
  test('clears running state when the engine process exits', () async {
    final directory = await Directory.systemTemp.createTemp('bhe-engine-');
    addTearDown(() => directory.delete(recursive: true));
    final launcher = File('${directory.path}/fake-engine');
    await launcher.writeAsString('#!/bin/sh\nexit 0\n');
    await Process.run('chmod', ['+x', launcher.path]);

    final client = EngineClient();
    addTearDown(client.dispose);
    await client.start(
      workingDirectory: directory.path,
      enginePythonPath: directory.path,
      pythonExecutable: launcher.path,
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
    final launcher = File('${directory.path}/fake-engine');
    await launcher.writeAsString(
      '#!/bin/sh\nwhile IFS= read -r line; do sleep 5; done\n',
    );
    await Process.run('chmod', ['+x', launcher.path]);

    final client = EngineClient(
      requestTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(client.dispose);
    await client.start(
      workingDirectory: directory.path,
      enginePythonPath: directory.path,
      pythonExecutable: launcher.path,
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
