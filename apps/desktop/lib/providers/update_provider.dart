import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/contact_actions.dart';
import '../core/diagnostics.dart';

const updateLastCheckKey = 'update_last_check_ms';
const updateSkippedVersionKey = 'update_skipped_version';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  failed,
}

class UpdateState {
  const UpdateState({
    this.status = UpdateStatus.idle,
    this.manifest,
    this.received = 0,
    this.file,
    this.error,
  });

  final UpdateStatus status;
  final UpdateManifest? manifest;
  final int received;
  final File? file;
  final String? error;

  UpdatePackage? get package => manifest?.packages[currentUpdatePlatform()];
}

String updateDownloadDirectory(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
  if (Platform.isMacOS) return '$home/Library/Caches/BHE/updates';
  if (Platform.isWindows) return '${env['LOCALAPPDATA'] ?? home}\\BHE\\updates';
  return '${env['XDG_CACHE_HOME'] ?? '$home/.cache'}/bhe/updates';
}

/// 取更新信息、下载和打开安装包；测试里替换成假的。
class UpdateService {
  const UpdateService();

  Future<UpdateManifest> fetch() => fetchUpdateManifest();

  Future<File> download(
    UpdatePackage package,
    HttpClient client,
    void Function(int received, int total) onProgress,
  ) {
    return downloadUpdate(
      package,
      Directory(updateDownloadDirectory(Platform.environment)),
      client: client,
      onProgress: onProgress,
    );
  }

  Future<void> open(File file) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', file.path]);
      return;
    }
    await openExternalUri(file.path);
  }
}

/// 当前 App 版本，测试里替换。
final appVersionProvider = Provider<String>((_) => appVersion);

final updateServiceProvider = Provider<UpdateService>(
  (_) => const UpdateService(),
);

class UpdateNotifier extends Notifier<UpdateState> {
  HttpClient? _downloadClient;
  bool _cancelled = false;

  @override
  UpdateState build() => const UpdateState();

  /// 手动检查时不理会「跳过这个版本」。
  Future<void> check({bool manual = false}) async {
    if (state.status == UpdateStatus.checking ||
        state.status == UpdateStatus.downloading) {
      return;
    }
    state = const UpdateState(status: UpdateStatus.checking);
    try {
      final manifest = await ref.read(updateServiceProvider).fetch();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        updateLastCheckKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      final skipped =
          !manual &&
          prefs.getString(updateSkippedVersionKey) == manifest.version;
      final available =
          isNewerVersion(manifest.version, ref.read(appVersionProvider)) &&
          manifest.packages.containsKey(currentUpdatePlatform()) &&
          !skipped;
      state = UpdateState(
        status: available ? UpdateStatus.available : UpdateStatus.upToDate,
        manifest: manifest,
      );
    } catch (error) {
      state = UpdateState(status: UpdateStatus.failed, error: error.toString());
    }
  }

  /// 启动后自动检查，一天最多一次；开发版不检查。返回是否发现了新版本。
  Future<bool> autoCheck() async {
    final current = ref.read(appVersionProvider);
    if (compareVersions(current, current) == null) return false;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(updateLastCheckKey) ?? 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    if (elapsed < const Duration(days: 1).inMilliseconds) return false;
    await check();
    return state.status == UpdateStatus.available;
  }

  Future<void> skip() async {
    final version = state.manifest?.version;
    if (version == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(updateSkippedVersionKey, version);
    state = UpdateState(
      status: UpdateStatus.upToDate,
      manifest: state.manifest,
    );
  }

  Future<void> download() async {
    final manifest = state.manifest;
    final package = state.package;
    if (manifest == null || package == null) return;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _downloadClient = client;
    _cancelled = false;
    state = UpdateState(status: UpdateStatus.downloading, manifest: manifest);
    var reported = 0;
    try {
      final file = await ref.read(updateServiceProvider).download(
        package,
        client,
        (received, total) {
          if (received - reported < total ~/ 200 && received < total) return;
          reported = received;
          state = UpdateState(
            status: UpdateStatus.downloading,
            manifest: manifest,
            received: received,
          );
        },
      );
      state = UpdateState(
        status: UpdateStatus.ready,
        manifest: manifest,
        received: package.size,
        file: file,
      );
    } catch (error) {
      state = _cancelled
          ? UpdateState(status: UpdateStatus.available, manifest: manifest)
          : UpdateState(
              status: UpdateStatus.failed,
              manifest: manifest,
              error: error.toString(),
            );
    } finally {
      _downloadClient = null;
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _downloadClient?.close(force: true);
  }

  Future<void> openPackage() async {
    final file = state.file;
    if (file != null) await ref.read(updateServiceProvider).open(file);
  }
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
