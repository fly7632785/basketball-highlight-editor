import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../core/contact_actions.dart';
import '../core/diagnostics.dart';
import '../core/windows_update_installer.dart';
import 'project_state.dart';
import 'session_provider.dart';
import '../core/app_log.dart';

const updateLastCheckKey = 'update_last_check_ms';
const updateSkippedVersionKey = 'update_skipped_version';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  installing,
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

  String? get targetVersion => manifest?.versionFor(currentUpdatePlatform());

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

  bool get supportsInstallation => Platform.isWindows;

  Future<UpdateInstallSession> prepareInstall(
    File file,
    UpdatePackage package,
    String version,
  ) => const WindowsUpdateInstaller().prepare(
    archive: file,
    package: package,
    version: version,
    cache: Directory(updateDownloadDirectory(Platform.environment)),
  );

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

/// Kept injectable so tests never close the real window or engine.
class UpdateLifecycle {
  const UpdateLifecycle({
    required this.isBusy,
    required this.prepareForExit,
    required this.exit,
    required this.resume,
  });

  final bool Function() isBusy;
  final Future<bool> Function() prepareForExit;
  final Future<void> Function() exit;
  final Future<void> Function() resume;
}

bool updateBlockedByProject(ProjectState state) =>
    state.busy ||
    state.analysisRunning ||
    state.exportRunning ||
    state.analysisQueue.isNotEmpty && !state.queuePaused;

final updateLifecycleProvider = Provider<UpdateLifecycle>((ref) {
  return UpdateLifecycle(
    isBusy: () => updateBlockedByProject(ref.read(projectProvider)),
    prepareForExit: () async {
      if (!await ref.read(projectProvider.notifier).prepareForShutdown()) {
        return false;
      }
      await ref.read(engineBootstrapProvider.notifier).shutdownForUpdate();
      return true;
    },
    exit: () => windowManager.destroy(),
    resume: () =>
        ref.read(engineBootstrapProvider.notifier).resumeAfterUpdateFailure(),
  );
});

class UpdateNotifier extends Notifier<UpdateState> {
  HttpClient? _downloadClient;
  bool _cancelled = false;

  @override
  UpdateState build() => const UpdateState();

  /// 手动检查时不理会「跳过这个版本」。
  Future<void> check({bool manual = false}) async {
    if (state.status == UpdateStatus.checking ||
        state.status == UpdateStatus.downloading ||
        state.status == UpdateStatus.installing) {
      return;
    }
    state = const UpdateState(status: UpdateStatus.checking);
    appLog('info', 'update', '检查更新开始 manual=$manual');
    try {
      final manifest = await ref.read(updateServiceProvider).fetch();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        updateLastCheckKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      final skipped =
          !manual &&
          prefs.getString(updateSkippedVersionKey) ==
              manifest.versionFor(currentUpdatePlatform());
      final available =
          isNewerVersion(
            manifest.versionFor(currentUpdatePlatform()),
            ref.read(appVersionProvider),
          ) &&
          manifest.packages.containsKey(currentUpdatePlatform()) &&
          !skipped;
      state = UpdateState(
        status: available ? UpdateStatus.available : UpdateStatus.upToDate,
        manifest: manifest,
      );
      appLog(
        'info',
        'update',
        '检查更新结束 ${available ? '发现新版本 v${state.targetVersion}' : '已是最新'}',
      );
    } catch (error) {
      state = UpdateState(status: UpdateStatus.failed, error: error.toString());
      appLog('warn', 'update', '检查更新失败: $error');
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
    final version = state.targetVersion;
    if (version == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(updateSkippedVersionKey, version);
    state = UpdateState(
      status: UpdateStatus.upToDate,
      manifest: state.manifest,
    );
  }

  Future<void> download() async {
    if (state.status == UpdateStatus.downloading ||
        state.status == UpdateStatus.installing) {
      return;
    }
    final manifest = state.manifest;
    final package = state.package;
    if (manifest == null || package == null) return;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _downloadClient = client;
    _cancelled = false;
    state = UpdateState(status: UpdateStatus.downloading, manifest: manifest);
    appLog('info', 'update', '开始下载更新 v${manifest.versionFor(currentUpdatePlatform())} size=${package.size}');
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
      appLog('info', 'update', '下载更新完成');
    } catch (error) {
      state = _cancelled
          ? UpdateState(status: UpdateStatus.available, manifest: manifest)
          : UpdateState(
              status: UpdateStatus.failed,
              manifest: manifest,
              error: error.toString(),
            );
      appLog(
        _cancelled ? 'info' : 'warn',
        'update',
        _cancelled ? '下载更新已取消' : '下载更新失败: $error',
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
    if (file != null) {
      appLog('info', 'update', '打开更新包所在位置');
      await ref.read(updateServiceProvider).open(file);
    }
  }

  Future<void> install() async {
    if (state.status != UpdateStatus.ready) return;
    final ready = state;
    final file = ready.file;
    final package = ready.package;
    final service = ref.read(updateServiceProvider);
    if (file == null || package == null || !service.supportsInstallation) {
      return;
    }
    final lifecycle = ref.read(updateLifecycleProvider);
    if (lifecycle.isBusy()) return;
    appLog('info', 'update', '开始安装更新 v${ready.targetVersion}');
    state = UpdateState(
      status: UpdateStatus.installing,
      manifest: ready.manifest,
      file: file,
      received: ready.received,
    );
    UpdateInstallSession? session;
    var preparingExit = false;
    try {
      session = await service.prepareInstall(
        file,
        package,
        windowsInstallerVersion(ready.targetVersion!),
      );
      if (lifecycle.isBusy()) {
        throw const UpdateException('请等待当前操作结束后再安装更新');
      }
      preparingExit = true;
      if (!await lifecycle.prepareForExit()) {
        throw const UpdateException('退出前保存未完成，请重试');
      }
      await session.commit();
      await lifecycle.exit();
    } catch (error) {
      try {
        await session?.cancel();
      } catch (error) { appLog('warn', 'update_provider', 'install 忽略了错误: $error'); }
      if (preparingExit) {
        try {
          await lifecycle.resume();
        } catch (error) { appLog('warn', 'update_provider', 'install 忽略了错误: $error'); }
      }
      state = UpdateState(
        status: UpdateStatus.ready,
        manifest: ready.manifest,
        file: file,
        received: ready.received,
        error: error.toString(),
      );
      appLog('warn', 'update', '安装更新失败: $error');
    }
  }
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
