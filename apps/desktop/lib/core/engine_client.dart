import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'engine_session.dart';
import 'app_log.dart';

class EngineException implements Exception {
  const EngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class EngineClient implements EngineTransport {
  EngineClient({
    this.requestTimeout = const Duration(minutes: 2),
    this.onUnexpectedExit,
    this.logFile,
  });

  final Duration requestTimeout;

  /// 引擎启动参数、stderr、失败请求与退出记录;超过 2MB 时轮换为 `.1`。
  final File? logFile;

  /// 引擎进程意外退出(非 dispose 触发)时回调,携带退出码与 stderr 尾部。
  void Function(int exitCode, String stderrTail)? onUnexpectedExit;
  bool _disposedIntentionally = false;
  Future<void>? _disposeInFlight;
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  Future<void> _writeQueue = Future<void>.value();
  int _requestSequence = 0;
  String _stderrTail = '';

  bool get isRunning => _process != null;

  Future<void> start({
    required String workingDirectory,
    required String enginePythonPath,
    String pythonExecutable = 'python3',
    String? extraPath,
  }) async {
    await _disposeInFlight;
    if (isRunning) return;
    _disposedIntentionally = false;
    final environment = Map<String, String>.from(Platform.environment);
    environment['PYTHONPATH'] = enginePythonPath;
    environment['PYTHONIOENCODING'] = 'utf-8';
    // Keep the packaged runtime read-only; generated files block safe updates.
    if (Platform.isWindows) environment['PYTHONDONTWRITEBYTECODE'] = '1';
    // 让 Engine 内部的 Python 代码能稳定定位 runtime/bin 下的媒体工具，
    // 不依赖 macOS 从 Finder 启动 App 时不完整的 PATH。
    environment['BHE_RUNTIME_ROOT'] = workingDirectory;
    if (extraPath != null && extraPath.isNotEmpty) {
      final existingPath = environment['PATH'];
      environment['PATH'] = [
        extraPath,
        if (existingPath != null && existingPath.isNotEmpty) existingPath,
      ].join(Platform.isWindows ? ';' : ':');
    }
    log('start python=$pythonExecutable cwd=$workingDirectory');
    final Process process;
    try {
      process = await Process.start(
        pythonExecutable,
        ['-m', 'basketball_engine'],
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false,
      );
    } on Object catch (error) {
      log('start failed: $error');
      rethrow;
    }
    _process = process;
    _stderrTail = '';
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStderrLine);
    process.exitCode.then((exitCode) {
      log('exit code=$exitCode');
      if (!identical(_process, process)) return;
      _process = null;
      _stdoutSubscription = null;
      _stderrSubscription = null;
      final detail = _stderrTail.trim();
      _closePending(
        EngineException(
          'ENGINE_EXITED',
          detail.isEmpty
              ? 'Engine 进程已退出（exitCode=$exitCode）'
              : 'Engine 进程已退出（exitCode=$exitCode）：$detail',
        ),
      );
      if (!_disposedIntentionally) {
        onUnexpectedExit?.call(exitCode, detail);
      }
    });
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
    try {
      await _enqueueWrite(
        jsonEncode({
          'protocol_version': '1.0',
          'type': 'request',
          'request_id': requestId,
          'command': command,
          'payload': payload,
        }),
      );
    } catch (error) {
      _pending.remove(requestId);
      throw EngineException('ENGINE_WRITE_FAILED', '无法向 Engine 发送请求：$error');
    }
    final response = await completer.future.timeout(
      _timeoutFor(command),
      onTimeout: () {
        _pending.remove(requestId);
        log('$command timed out');
        throw EngineException('ENGINE_TIMEOUT', '请求处理超时：$command');
      },
    );
    if (response['ok'] != true) {
      final error = response['error'];
      log('$command failed: ${jsonEncode(error)}');
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

  Duration _timeoutFor(String command) {
    return requestTimeout;
  }

  Future<void> dispose() => _disposeInFlight ??= _dispose();

  Future<void> _dispose() async {
    _disposedIntentionally = true;
    final process = _process;
    try {
      if (process != null) {
        // Keep draining stdout/stderr while the service shuts down.
        try {
          await process.stdin.close().timeout(const Duration(seconds: 6));
          await process.exitCode.timeout(const Duration(seconds: 6));
        } on Object catch (error) {
          appLog('warn', 'engine_client', '_dispose 忽略了错误: $error');
          process.kill();
          // Returning before exit would let the updater race locked DLLs.
          await process.exitCode.timeout(const Duration(seconds: 6));
        }
      }
      if (identical(_process, process)) _process = null;
      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _stdoutSubscription = null;
      _stderrSubscription = null;
      _closePending(const EngineException('ENGINE_DISPOSED', 'Engine 已关闭'));
    } finally {
      _disposeInFlight = null;
    }
  }

  Future<void> _enqueueWrite(String line) {
    final write = _writeQueue.catchError((Object _) {}).then((_) async {
      final process = _process;
      if (process == null) {
        throw const EngineException('ENGINE_NOT_RUNNING', 'Engine 尚未启动');
      }
      process.stdin.writeln(line);
      await process.stdin.flush();
    });
    _writeQueue = write;
    return write;
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

  void _handleStderrLine(String line) {
    log('stderr: $line');
    final next = _stderrTail.isEmpty ? line : '$_stderrTail\n$line';
    _stderrTail = next.length <= 4000
        ? next
        : next.substring(next.length - 4000);
  }

  void log(String message) {
    final file = logFile;
    if (file != null) appendEngineLog(message, file: file);
  }

  void _closePending(EngineException error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
  }
}
