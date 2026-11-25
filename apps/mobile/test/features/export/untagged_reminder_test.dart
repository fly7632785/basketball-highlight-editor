import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/export_settings_actions.dart';
import '../../support/mobile_video_fixture.dart';

const _channel = MethodChannel('com.bhe.bhe/mobile_media');

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

  Future<void> run(
    WidgetTester tester, {
    required List<String> players,
    required List<Candidate> candidates,
    required Future<void> Function(MobileVideoFixture fixture) body,
  }) async {
    final fixture = MobileVideoFixture();
    await tester.runAsync(fixture.init);
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          return call.method == 'registerMergeExport' ? true : null;
        });
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(const Size(360, 1400));
    try {
      final file = await tester.runAsync(
        () => fixture.file('original.mp4', 'original'),
      );
      fixture.state.project = fixture
          .project(file!.path)
          .copyWith(candidates: candidates, players: players);
      await tester.pumpWidget(BheMobileApp(appState: fixture.state));
      await tester.pump();
      await tester.tap(find.byTooltip('导出').first);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await body(fixture);
    } finally {
      VideoPlayerPlatform.instance = previous;
      await tester.binding.setSurfaceSize(null);
      tester.binding.platformDispatcher.clearLocaleTestValue();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
      await tester.runAsync(() => fixture.close());
    }
  }

  final withUntagged = [
    _c('a', 1, player: 'Alice'),
    _c('u1', 2),
    _c('u2', 3),
    _c('x', 4, excluded: true),
  ];

  testWidgets('asks first and goes back to review', (tester) async {
    await run(
      tester,
      players: const ['Alice'],
      candidates: withUntagged,
      body: (fixture) async {
        await chooseExportMode(tester, '合成一个视频', '完成');
        await tester.tap(find.text('开始导出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('untagged-reminder')), findsOneWidget);
        // The excluded untagged clip is not counted.
        expect(find.text('还有 2 个片段未标标签'), findsOneWidget);
        await tester.tap(find.text('返回审核'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('untagged-reminder')), findsNothing);
        expect(find.byKey(const ValueKey('export-stats')), findsNothing);
        expect(fixture.state.exporting, isFalse);
      },
    );
  });

  testWidgets('export anyway starts the export', (tester) async {
    await run(
      tester,
      players: const ['Alice'],
      candidates: withUntagged,
      body: (fixture) async {
        await chooseExportMode(tester, '合成一个视频', '完成');
        await tester.tap(find.text('开始导出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('仍然导出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('untagged-reminder')), findsNothing);
        expect(fixture.state.exporting, isTrue);
      },
    );
  });

  testWidgets('no reminder when nothing is tagged and there is no roster', (
    tester,
  ) async {
    await run(
      tester,
      players: const [],
      candidates: [_c('u1', 1), _c('u2', 2)],
      body: (fixture) async {
        await chooseExportMode(tester, '合成一个视频', '完成');
        await tester.tap(find.text('开始导出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('untagged-reminder')), findsNothing);
        expect(fixture.state.exporting, isTrue);
      },
    );
  });

  testWidgets('no reminder when filtered to one player', (tester) async {
    await run(
      tester,
      players: const ['Alice'],
      candidates: withUntagged,
      body: (fixture) async {
        await openExportScope(tester);
        await tester.tap(find.text('Alice  1'));
        await tester.pump();
        await finishExportSettings(tester, '完成');
        await chooseExportMode(tester, '合成一个视频', '完成');
        await tester.tap(find.text('开始导出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('untagged-reminder')), findsNothing);
        expect(fixture.state.exporting, isTrue);
      },
    );
  });

  testWidgets('no reminder in per-label mode', (tester) async {
    await run(
      tester,
      players: const ['Alice'],
      candidates: withUntagged,
      body: (fixture) async {
        await chooseExportMode(tester, '每个标签一个视频', '完成');
        await tester.tap(find.text('开始导出'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('untagged-reminder')), findsNothing);
        expect(fixture.state.exporting, isTrue);
      },
    );
  });
}
