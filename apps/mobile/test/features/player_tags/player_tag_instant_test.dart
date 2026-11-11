import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

void main() {
  late MobileVideoFixture f;
  setUp(() async { f = MobileVideoFixture(); await f.init(); });
  tearDown(() => f.close());
  testWidgets('select, clear, add, and undo apply immediately', (tester) async {
    final old = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() async { VideoPlayerPlatform.instance = old; tester.binding.platformDispatcher.clearLocaleTestValue(); await tester.binding.setSurfaceSize(null); });
    f.state.project = f.project('${f.root.path}/missing.mp4').copyWith(players: ['Alice', 'Bob']);
    await tester.pumpWidget(BheMobileApp(appState: f.state));
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations)!;
    await tester.ensureVisible(find.text(l10n.reviewCount(1)));
    await tester.pump();
    await tester.tap(find.text(l10n.reviewCount(1)));
    await tester.pump();
    Future<void> open(String player) async {
      await tester.tap(find.byTooltip(l10n.text('球员：$player')));
      await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    }
    await open('Alice');
    expect(find.text(l10n.text('应用标签')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-select-Alice')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(f.state.project.candidates.single.player, 'Alice');
    await open('Alice');
    await tester.tap(find.byKey(const ValueKey('player-select-Bob')));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    await waitProjectWrites(tester, f.state.pendingProjectWrites);
    await tester.pump();
    expect(f.state.project.candidates.single.player, 'Bob');
    await tester.pump(const Duration(milliseconds: 400));
    await open('Bob');
    await tester.tap(find.text(l10n.text('清除标签')));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 400));
    await waitProjectWrites(tester, f.state.pendingProjectWrites);
    await tester.pump();
    expect(f.state.project.candidates.single.player, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
