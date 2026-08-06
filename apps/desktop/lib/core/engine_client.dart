import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine_session.dart';

class EngineException implements Exception {
  const EngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class EngineClient implements EngineTransport {
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  int _requestSequence = 0;

  bool get isRunning => _process != null;

  Future<void> start({
    required String workingDirectory,
    required String enginePythonPath,
    String pythonExecutable = 'python3',
    String? extraPath,
  }) async {
    if (isRunning) return;
    final environment = Map<String, String>.from(Platform.environment);
    environment['PYTHONPATH'] = enginePythonPath;
    if (extraPath != null && extraPath.isNotEmpty) {
      final existingPath = environment['PATH'];
      environment['PATH'] = [
        extraPath,
        if (existingPath != null && existingPath.isNotEmpty) existingPath,
      ].join(Platform.isWindows ? ';' : ':');
    }
    _process = await Process.start(
      pythonExecutable,
      ['-m', 'basketball_engine'],
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _process!.stderr.transform(utf8.decoder).listen((_) {});
    _process!.exitCode.then((_) => _closePending());
  }

  @override
  Future<Map<String, dynamic>> request(
    String command,
    Map<String, dynamic> payload,
  ) async {
    if (!isRunning) {
      throw const EngineException('ENGINE_NOT_RUNNING', 'Engine 尚未启动');
    }
    final requestId = 'dart-${++_requestSequence}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    _process!.stdin.writeln(
      jsonEncode({
        'protocol_version': '1.0',
        'type': 'request',
        'request_id': requestId,
        'command': command,
        'payload': payload,
      }),
    );
    final response = await completer.future;
    if (response['ok'] != true) {
      final error = response['error'];
      if (error is Map) {
        throw EngineException('${error['code']}', '${error['message']}');
      }
      throw const EngineException('ENGINE_ERROR', 'Engine 返回未知错误');
    }
    final payloadValue = response['payload'];
    return payloadValue is Map<String, dynamic>
        ? payloadValue
        : <String, dynamic>{};
  }

  Future<void> dispose() async {
    await _stdoutSubscription?.cancel();
    _process?.kill();
    _closePending();
    _process = null;
  }

  void _handleLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;
      final requestId = decoded['request_id'];
      if (requestId is! String) return;
      final completer = _pending.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(decoded);
      }
    } on FormatException {
      // Engine stdout is a strict JSONL channel; malformed lines are ignored here.
    }
  }

  void _closePending() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const EngineException('ENGINE_EXITED', 'Engine 进程已退出'),
        );
      }
    }
    _pending.clear();
  }
}
