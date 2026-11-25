import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/export/export_modes.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/export_settings_actions.dart';
import '../../support/mobile_video_fixture.dart';

Candidate _c(String id, int n, {String? player, bool excluded = false}) =>
    Candidate(
      id: id,
      startMs: n * 1000,
      endMs: n * 1000 + 800,
      eventMs: n * 1000 + 400,
      player: player,
      selection: excluded
          ? CandidateSelection.excluded
          : CandidateSelection.included,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExportScope', () {
    final alice = _c('a', 1, player: 'Alice');
    final bob = _c('b', 2, player: 'Bob');
    final blank = _c('u1', 3, player: '  ');
    final none = _c('u2', 4);

    test('all matches everything', () {
      for (final c in [alice, bob, blank, none]) {
        expect(ExportScope.all.matches(c), isTrue);
      }
    });

    test('only keeps the chosen labels and leaves untagged out by default', () {
      const scope = ExportScope.only({'Alice'});
      expect(scope.matches(alice), isTrue);
      expect(scope.matches(bob), isFalse);
      expect(scope.matches(blank), isFalse);
      expect(scope.matches(none), isFalse);
    });

    test('several labels plus untagged', () {
      const scope = ExportScope.only({'Alice', 'Bob'}, includeUntagged: true);
      expect(scope.matches(alice), isTrue);
      expect(scope.matches(bob), isTrue);
      expect(scope.matches(blank), isTrue);
      expect(scope.matches(none), isTrue);
    });

    test('an empty selection normalizes back to everything', () {
      expect(const ExportScope.only({}).normalized.active, isFalse);
      expect(
        const ExportScope.only({}, includeUntagged: true).normalized.active,
        isTrue,
      );
      expect(const ExportScope.only({'Alice'}).normalized.active, isTrue);
    });
  });

  testWidgets('export scope chips are multi-select and drive the summary', (
    tester,
  ) async {
    final fixture = MobileVideoFixture();
    await tester.runAsync(fixture.init);
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(const Size(360, 1400));
    try {
      final file = await tester.runAsync(
        () => fixture.file('original.mp4', 'original'),
      );
      fixture.state.project = fixture
          .project(file!.path)
          .copyWith(
            players: const ['Alice', 'Bob', 'Carol'],
            candidates: [
              _c('a1', 1, player: 'Alice'),
              _c('a2', 2, player: 'Alice'),
              _c('b1', 3, player: 'Bob'),
              _c('c1', 4, player: 'Carol'),
              _c('u1', 5),
              _c('x1', 6, player: 'Bob', excluded: true),
            ],
          );
      await tester.pumpWidget(BheMobileApp(appState: fixture.state));
      await tester.pump();
      await tester.tap(find.byTooltip('导出').first);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await openExportScope(tester);
      // Counts only cover kept clips.
      expect(find.text('全部标签  5'), findsOneWidget);
      expect(find.text('Alice  2'), findsOneWidget);
      expect(find.text('Bob  1'), findsOneWidget);
      expect(find.text('Carol  1'), findsOneWidget);
      expect(find.text('未标记  1'), findsOneWidget);
      await finishExportSettings(tester, '完成');

      await chooseExportMode(tester, '每个标签一个视频', '完成');
      expect(find.textContaining('将导出 3 个视频 · 共 4 段'), findsOneWidget);
      await openExportScope(tester);
      expect(find.text('未标记  1'), findsNothing);
      expect(find.textContaining('没标签的 1 段不导出'), findsOneWidget);

      await tester.tap(find.text('Alice  2'));
      await tester.pump();
      await tester.tap(find.text('Bob  1'));
      await tester.pump();
      await finishExportSettings(tester, '完成');
      expect(find.textContaining('将导出 2 个视频 · 共 3 段'), findsOneWidget);

      // Merge mode still supports explicit inclusion of untagged clips.
      await chooseExportMode(tester, '合成一个视频', '完成');
      await openExportScope(tester);
      await tester.tap(find.text('未标记  1'));
      await tester.pump();
      await finishExportSettings(tester, '完成');
      expect(find.textContaining('将导出 1 个视频 · 共 4 段'), findsOneWidget);

      // Deselecting everything falls back to the whole project.
      await openExportScope(tester);
      for (final choice in ['Alice  2', 'Bob  1', '未标记  1']) {
        await tester.tap(find.text(choice));
        await tester.pump();
      }
      await finishExportSettings(tester, '完成');
      expect(find.textContaining('将导出 1 个视频 · 共 5 段'), findsOneWidget);

      // The "all" chip clears a selection in one tap.
      await openExportScope(tester);
      await tester.tap(find.text('Carol  1'));
      await tester.pump();
      await finishExportSettings(tester, '完成');
      expect(find.textContaining('将导出 1 个视频 · 共 1 段'), findsOneWidget);
      await openExportScope(tester);
      await tester.tap(find.text('全部标签  5'));
      await tester.pump();
      await finishExportSettings(tester, '完成');
      expect(find.textContaining('将导出 1 个视频 · 共 5 段'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      VideoPlayerPlatform.instance = previous;
      await tester.binding.setSurfaceSize(null);
      tester.binding.platformDispatcher.clearLocaleTestValue();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
      await tester.runAsync(() => fixture.close());
    }
  });
}
