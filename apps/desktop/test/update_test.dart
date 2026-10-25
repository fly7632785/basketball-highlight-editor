import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:desktop/features/update/update_dialog.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/update_provider.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateManifest _manifest(String version) => UpdateManifest(
  version: version,
  publishedAt: '2026-10-24T08:00:00+00:00',
  notes: const {'zh': '应用内检查更新；修复多段项目审核页无法播放', 'en': 'In-app updates'},
  packages: {
    currentUpdatePlatform()!: UpdatePackage(
      url: Uri.parse('https://oss.example/BHE-v$version.dmg'),
      sha256: 'a' * 64,
      size: 400 * 1024 * 1024,
    ),
  },
);

class _FakeUpdateService extends UpdateService {
  _FakeUpdateService(this.manifest);

  final UpdateManifest manifest;
  int fetches = 0;
  final opened = <String>[];
  Completer<File>? pendingDownload;
  void Function(int, int)? progress;

  @override
  Future<UpdateManifest> fetch() async {
    fetches++;
    return manifest;
  }

  @override
  Future<File> download(
    UpdatePackage package,
    HttpClient client,
    void Function(int received, int total) onProgress,
  ) {
    progress = onProgress;
    pendingDownload = Completer<File>();
    return pendingDownload!.future;
  }

  @override
  Future<void> open(File file) async => opened.add(file.path);
}

class _IdleProject extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState();
}

ProviderContainer _container(_FakeUpdateService service, String current) {
  final container = ProviderContainer(
    overrides: [
      updateServiceProvider.overrideWithValue(service),
      appVersionProvider.overrideWithValue(current),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('auto check finds a newer version at most once a day', () async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    final container = _container(service, '0.1.10');
    final notifier = container.read(updateProvider.notifier);

    expect(await notifier.autoCheck(), isTrue);
    expect(container.read(updateProvider).status, UpdateStatus.available);
    expect(await notifier.autoCheck(), isFalse);
    expect(service.fetches, 1);
  });

  test('a development build never checks automatically', () async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    final container = _container(service, 'dev');
    expect(await container.read(updateProvider.notifier).autoCheck(), isFalse);
    expect(service.fetches, 0);
  });

  test('a skipped version stays quiet until checked by hand', () async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    final container = _container(service, '0.1.10');
    final notifier = container.read(updateProvider.notifier);
    await notifier.check();
    await notifier.skip();

    await notifier.check();
    expect(container.read(updateProvider).status, UpdateStatus.upToDate);
    await notifier.check(manual: true);
    expect(container.read(updateProvider).status, UpdateStatus.available);
  });

  test('the same version is up to date even with a build suffix', () async {
    final service = _FakeUpdateService(_manifest('0.1.10'));
    final container = _container(service, '0.1.10+234a9d7');
    await container.read(updateProvider.notifier).check(manual: true);
    expect(container.read(updateProvider).status, UpdateStatus.upToDate);
  });

  testWidgets('the dialog downloads the package and opens it', (tester) async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateServiceProvider.overrideWithValue(service),
          appVersionProvider.overrideWithValue('0.1.10'),
          projectProvider.overrideWith(_IdleProject.new),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: UpdateDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新版本 v0.1.11'), findsOneWidget);
    expect(find.text('· 应用内检查更新'), findsOneWidget);
    expect(find.text('· 修复多段项目审核页无法播放'), findsOneWidget);
    expect(find.textContaining('当前版本 v0.1.10 · 400 MB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-download')));
    await tester.pump();
    service.progress!(100 * 1024 * 1024, 400 * 1024 * 1024);
    await tester.pump();
    expect(find.text('已下载 100 / 400 MB'), findsOneWidget);

    service.pendingDownload!.complete(File('/tmp/BHE-v0.1.11.dmg'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('update-open')));
    await tester.pump();
    expect(service.opened, ['/tmp/BHE-v0.1.11.dmg']);
  });
}
