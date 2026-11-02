import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

abstract class UpdateInstallSession {
  Future<void> commit();
  Future<void> cancel();
}

/// The helper and its working directory must survive replacement of the app.
class WindowsUpdateInstaller {
  const WindowsUpdateInstaller();

  Future<UpdateInstallSession> prepare({
    required File archive,
    required UpdatePackage package,
    required String version,
    required Directory cache,
  }) async {
    if (!Platform.isWindows) {
      throw const UpdateException('此平台请手动打开安装包更新');
    }
    final executable = File(Platform.resolvedExecutable);
    if (executable.uri.pathSegments.last.toLowerCase() != 'bhe.exe') {
      throw const UpdateException('请在正式发布版 BHE 中安装更新');
    }
    await cache.create(recursive: true);
    final directory = await cache.createTemp('install-');
    final session = FileUpdateInstallSession(directory);
    try {
      final script = await rootBundle.loadString('assets/windows_update.ps1');
      final helper = await File(
        '${directory.path}/update.ps1',
      ).writeAsString(script, flush: true);
      final request = await File('${directory.path}/request.json')
          .writeAsString(
            jsonEncode({
              'archive': archive.absolute.path,
              'sha256': package.sha256,
              'size': package.size,
              'version': version,
              'installDirectory': executable.parent.path,
              'appPid': pid,
            }),
            flush: true,
          );
      // Use the OS copy, not a powershell.exe found in the application/PATH.
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await Process.start(
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
          '-LogDirectory',
          engineLogDirectory(Platform.environment),
        ],
        workingDirectory: directory.path,
        mode: ProcessStartMode.detached,
      );
      await session.waitUntilStarted();
      await session.waitUntilReady();
      return session;
    } catch (error) {
      appLog('warn', 'windows_update_installer', 'prepare 忽略了错误: $error');
      await session.cancel();
      rethrow;
    }
  }
}

/// File handshake avoids shell interpolation of Unicode paths and arguments.
class FileUpdateInstallSession implements UpdateInstallSession {
  FileUpdateInstallSession(this.directory);

  final Directory directory;

  Future<void> waitUntilStarted() =>
      _waitForMarker('started', const Duration(seconds: 20));

  Future<void> waitUntilReady({
    Duration timeout = const Duration(minutes: 15),
  }) => _waitForMarker('ready', timeout);

  Future<void> _waitForMarker(String marker, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final error = File('${directory.path}/error.txt');
      if (await error.exists()) {
        throw UpdateException(await error.readAsString());
      }
      if (await File('${directory.path}/$marker').exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const UpdateException('准备更新超时，请打开所在文件夹手动更新');
  }

  @override
  Future<void> commit() async {
    await File('${directory.path}/commit').writeAsString('commit', flush: true);
    // If the helper timed out during saving, keep BHE open.
    await _waitForMarker('accepted', const Duration(seconds: 10));
  }

  @override
  Future<void> cancel() =>
      File('${directory.path}/cancel').writeAsString('cancel', flush: true);
}
