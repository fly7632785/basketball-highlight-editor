import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 打包时由 `--dart-define=BHE_VERSION=<版本>` 注入，本地开发是 dev，不自动检查。
const mobileAppVersion = String.fromEnvironment(
  'BHE_VERSION',
  defaultValue: 'dev',
);

const _lastCheckKey = 'bhe.update-last-check-ms';
const _skippedVersionKey = 'bhe.update-skipped-version';

enum UpdateStatus { idle, checking, upToDate, available, downloading, ready, failed }

class AppUpdater extends ChangeNotifier {
  AppUpdater({this.currentVersion = mobileAppVersion});

  static const _channel = MethodChannel('com.bhe.bhe/mobile_update');

  final String currentVersion;
  UpdateStatus status = UpdateStatus.idle;
  UpdateManifest? manifest;
  int received = 0;
  File? file;
  String? error;
  HttpClient? _downloadClient;
  bool _cancelled = false;

  UpdatePackage? get package => manifest?.packages[currentUpdatePlatform()];

  void _set(UpdateStatus next, {String? error}) {
    status = next;
    this.error = error;
    notifyListeners();
  }

  /// 手动检查时不理会「跳过这个版本」。
  Future<void> check({bool manual = false}) async {
    if (status == UpdateStatus.checking || status == UpdateStatus.downloading) {
      return;
    }
    manifest = null;
    _set(UpdateStatus.checking);
    try {
      final latest = await fetchUpdateManifest();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
      final skipped =
          !manual && prefs.getString(_skippedVersionKey) == latest.version;
      manifest = latest;
      _set(
        isNewerVersion(latest.version, currentVersion) &&
                package != null &&
                !skipped
            ? UpdateStatus.available
            : UpdateStatus.upToDate,
      );
    } catch (e) {
      _set(UpdateStatus.failed, error: e.toString());
    }
  }

  /// 启动后自动检查，一天最多一次。返回是否发现了新版本。
  Future<bool> autoCheck() async {
    if (compareVersions(currentVersion, currentVersion) == null) return false;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastCheckKey) ?? 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    if (elapsed < const Duration(days: 1).inMilliseconds) return false;
    await check();
    return status == UpdateStatus.available;
  }

  Future<void> skip() async {
    final version = manifest?.version;
    if (version == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, version);
    _set(UpdateStatus.upToDate);
  }

  Future<void> download() async {
    final target = package;
    if (target == null) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    _downloadClient = client;
    _cancelled = false;
    received = 0;
    _set(UpdateStatus.downloading);
    try {
      final directory = Directory('${(await getTemporaryDirectory()).path}/updates');
      file = await downloadUpdate(
        target,
        directory,
        client: client,
        onProgress: (value, total) {
          if (value - received < total ~/ 200 && value < total) return;
          received = value;
          notifyListeners();
        },
      );
      received = target.size;
      _set(UpdateStatus.ready);
    } catch (e) {
      _cancelled
          ? _set(UpdateStatus.available)
          : _set(UpdateStatus.failed, error: e.toString());
    } finally {
      _downloadClient = null;
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _downloadClient?.close(force: true);
  }

  /// 交给系统安装器。没开「安装未知应用」权限时会先打开设置页，返回 false。
  Future<bool> install() async {
    final path = file?.path;
    if (path == null) return false;
    final result = await _channel.invokeMethod<String>('installApk', {
      'path': path,
    });
    return result == 'started';
  }
}
