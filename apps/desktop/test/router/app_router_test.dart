// test/router/app_router_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/components/cs_bottom_nav.dart';
import 'package:desktop/components/cs_sidebar_shell.dart';
import 'package:desktop/core/engine_client.dart';
import 'package:desktop/providers/session_provider.dart';
import 'package:desktop/providers/theme_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/router/app_router.dart';

void main() {
  group('appRouterProvider', () {
    test('initial location is /home', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);
      expect(router.routeInformationProvider.value.uri.path, '/home');
    });

    test('go("/review") updates location', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);
      router.go('/review');
      expect(router.routeInformationProvider.value.uri.path, '/review');
    });

    test('go("/export") updates location', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);
      router.go('/export');
      expect(router.routeInformationProvider.value.uri.path, '/export');
    });
  });

  group('CsScaffold responsive', () {
    testWidgets('more menu exposes the log folder directly', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpHarness(tester);
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      expect(find.text('打开日志目录'), findsOneWidget);
    });

    testWidgets('close project remains clickable while a save is pending', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifier = _BusyProjectNotifier();
      await _pumpHarness(tester, notifier: notifier);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_RouterHost)),
      );
      container.read(appRouterProvider).go('/import');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭当前项目'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('关闭项目'));
      await tester.pumpAndSettle();
      expect(notifier.closeCalls, 1);
      expect(
        container
            .read(appRouterProvider)
            .routeInformationProvider
            .value
            .uri
            .path,
        '/home',
      );
    });

    testWidgets('wide window renders CsSidebarShell', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpHarness(tester);

      expect(find.byType(CsSidebarShell), findsOneWidget);
      expect(find.byType(CsBottomNav), findsNothing);
    });

    testWidgets('narrow window renders CsBottomNav', (tester) async {
      tester.view.physicalSize = const Size(700, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpHarness(tester);

      expect(find.byType(CsBottomNav), findsOneWidget);
      expect(find.byType(CsSidebarShell), findsNothing);
    });
  });
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  ProjectNotifier? notifier,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        if (notifier != null) projectProvider.overrideWith(() => notifier),
        engineBootstrapProvider.overrideWith(() => _StubEngine()),
        engineClientProvider.overrideWithValue(_StubClient()),
        themeModeProvider.overrideWith(() => _StubTheme()),
      ],
      child: const _RouterHost(),
    ),
  );
  await tester.pumpAndSettle();
}

class _BusyProjectNotifier extends ProjectNotifier {
  int closeCalls = 0;

  @override
  ProjectState build() =>
      const ProjectState(busy: true, video: {'id': 'video-1'});

  @override
  Future<void> loadRecentProjects() async {}

  @override
  Future<bool> closeProjectSafely() async {
    closeCalls++;
    state = const ProjectState();
    return true;
  }
}

class _StubEngine extends EngineBootstrapNotifier {
  @override
  AsyncValue<bool> build() => const AsyncData<bool>(true);
}

class _StubTheme extends ThemeModeNotifier {
  @override
  ThemeMode build() => ThemeMode.system;
}

class _StubClient extends EngineClient {
  @override
  bool get isRunning => true;

  @override
  Future<Map<String, dynamic>> request(
    String command,
    Map<String, dynamic> payload,
  ) async => <String, dynamic>{'ok': true, 'payload': <String, dynamic>{}};
}

class _RouterHost extends ConsumerWidget {
  const _RouterHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      routerConfig: ref.watch(appRouterProvider),
      theme: ThemeData(),
      darkTheme: ThemeData(brightness: Brightness.dark),
    );
  }
}
