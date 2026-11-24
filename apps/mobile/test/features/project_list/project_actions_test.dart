import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  late MobileVideoFixture f;
  setUp(() async { f = MobileVideoFixture(); await f.init(); });
  tearDown(() => f.close());
  testWidgets('project panel groups actions and more menu has five entries', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(BheMobileApp(appState: f.state)); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('project-name-rename'))); await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('project-action-projects')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-action-import')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-action-delete')), findsNothing);
    await tester.binding.handlePopRoute(); await tester.pump(const Duration(milliseconds: 400));
    f.state.project = f.project('${f.root.path}/missing.mp4');
    f.state.notifyListeners(); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('project-name-rename'))); await tester.pump(const Duration(milliseconds: 400));
    for (final id in ['projects', 'renameProject', 'projectInfo', 'import', 'closeProject', 'delete']) {
      expect(find.byKey(ValueKey('project-action-$id')), findsOneWidget);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('project-action-projectInfo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('项目信息'), findsOneWidget);
    expect(find.text('原视频文件名'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('project-name-rename')));
    await tester.pump(const Duration(milliseconds: 400));
    final materials = tester.widgetList<Material>(find.byType(Material));
    expect(materials.any((m) => m.clipBehavior == Clip.antiAlias && m.borderRadius == BorderRadius.circular(12)), isTrue);
    await tester.binding.handlePopRoute(); await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(PopupMenuButton<String>).first); await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(5));
    await tester.binding.handlePopRoute(); await tester.pump(const Duration(milliseconds: 400));
    final l10n = Localizations.of<BheLocalizations>(tester.element(find.byType(Scaffold).first), BheLocalizations)!;
    await tester.ensureVisible(find.text(l10n.reviewCount(1))); await tester.pump();
    await tester.tap(find.text(l10n.reviewCount(1))); await tester.pump();
    expect(find.byKey(const ValueKey('review-undo-top')), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('review-undo-bottom'))).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
