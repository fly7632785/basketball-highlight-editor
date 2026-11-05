import 'dart:async';
import 'dart:io';

class WindowsUpdateHelperProcess {
  const WindowsUpdateHelperProcess({required this.pid, required this.exitCode});

  final int pid;
  final Future<int> exitCode;
}

/// Windows PowerShell 5.1 can exit before running its script when launched
/// with Dart's detached modes. A normal Windows child survives its parent;
/// the helper's file handshake still controls when BHE may exit.
Future<WindowsUpdateHelperProcess> startWindowsUpdateHelper({
  required File helper,
  required File request,
  required Directory directory,
}) async {
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final process = await Process.start(
    '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      helper.path,
      '-RequestPath',
      request.path,
    ],
    workingDirectory: directory.path,
    mode: ProcessStartMode.normal,
  );
  final output = _captureOutput(
    process.stdout,
    File('${directory.path}/helper.stdout.log'),
  );
  final errors = _captureOutput(
    process.stderr,
    File('${directory.path}/helper.stderr.log'),
  );
  unawaited(process.stdin.close());
  return WindowsUpdateHelperProcess(
    pid: process.pid,
    exitCode: process.exitCode.then((code) async {
      await Future.wait([output, errors]);
      return code;
    }),
  );
}

Future<void> _captureOutput(Stream<List<int>> stream, File destination) async {
  try {
    await stream.pipe(destination.openWrite());
  } catch (_) {
    // Diagnostic writes must not interrupt the installation handshake.
  }
}
