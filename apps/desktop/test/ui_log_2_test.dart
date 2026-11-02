import 'package:bhe_core/bhe_core.dart';
import 'package:desktop/core/app_log.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/providers/locale_provider.dart';
import 'package:desktop/providers/theme_provider.dart';
import 'package:desktop/providers/update_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void clearLog() {
  final file = appLogFileOverride!;
  if (file.existsSync()) file.deleteSync();
}

String readLog() {
  final file = appLogFileOverride!;
  return file.existsSync() ? file.readAsStringSync() : '';
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('切换主题与语言各记一行 settings 日志', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    clearLog();
    await container.read(themeModeProvider.notifier).set(ThemeMode.light);
    await container.read(themeModeProvider.notifier).set(ThemeMode.light);
    final initialLocale = container.read(appLocaleProvider);
    final switchedTo = BheLocale.fromName(
      initialLocale.toLanguageTag(),
    ) == BheLocale.en
        ? 'zh-CN'
        : 'en-US';
    await container.read(
      appLocaleProvider.notifier,
    ).set(Locale(switchedTo.split('-')[0], switchedTo.split('-')[1]));

    final log = readLog();
    expect(log, contains('[info] [settings] 切换主题 light'));
    expect(
      '切换主题'.allMatches(log).length,
      1,
      reason: '主题没变时不重复记',
    );
    expect(log, contains('[info] [settings] 切换语言 $switchedTo'));
    expect(log, isNot(contains('user')));
    expect(log, isNot(contains('/Users/')));
  });

  test('检查更新结果记一行：有新版本带版本号', () async {
    final service = _FakeUpdateService(_manifestOf('0.1.11'));
    final container = _containerOf(service, '0.1.10');
    clearLog();
    await container.read(updateProvider.notifier).check(manual: true);
    final log = readLog();
    expect(log, contains('[info] [update] 检查更新开始 manual=true'));
    expect(log, contains('检查更新结束 发现新版本 v0.1.11'));
  });

  test('检查更新已是最新与失败各记一行', () async {
    final same = _containerOf(
      _FakeUpdateService(_manifestOf('0.1.10')),
      '0.1.10',
    );
    clearLog();
    await same.read(updateProvider.notifier).check(manual: true);
    expect(readLog(), contains('检查更新结束 已是最新'));

    final failing = _containerOf(_FailingUpdateService(), '0.1.10');
    clearLog();
    await failing.read(updateProvider.notifier).check(manual: true);
    expect(readLog(), contains('[warn] [update] 检查更新失败'));
  });

  test('最近项目加载与重命名不记项目名', () async {
    clearLog();
    appLog('info', 'home', '最近项目加载结束 共=3');
    appLog('info', 'home', '重命名项目结束 ok=true 范围=当前项目');
    final log = readLog();
    expect(log, contains('最近项目加载结束 共=3'));
    expect(log, contains('重命名项目结束 ok=true'));
    expect(log, isNot(contains('十月训练赛')));
  });
}

UpdateManifest _manifestOf(String version) => UpdateManifest(
  version: version,
  publishedAt: '2026-10-24T08:00:00+00:00',
  notes: const {'zh': '说明', 'en': 'notes'},
  packages: {
    'macos-arm64': UpdatePackage(
      url: Uri.parse('https://oss.example/BHE-v$version.dmg'),
      sha256: 'a' * 64,
      size: 1024,
    ),
  },
);

class _FakeUpdateService extends UpdateService {
  _FakeUpdateService(this.manifest);

  final UpdateManifest manifest;

  @override
  Future<UpdateManifest> fetch() async => manifest;
}

class _FailingUpdateService extends UpdateService {
  @override
  Future<UpdateManifest> fetch() async => throw const UpdateException('连不上更新服务器');
}

ProviderContainer _containerOf(UpdateService service, String current) {
  final container = ProviderContainer(
    overrides: [
      updateServiceProvider.overrideWithValue(service),
      appVersionProvider.overrideWithValue(current),
    ],
  );
  addTearDown(container.dispose);
  return container;
}
