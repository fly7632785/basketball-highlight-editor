import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

void main() {
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
  });
  tearDown(() => f.close());
  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('project rename fits $width $brightness $language', (
          tester,
        ) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          try {
            f.state.project = f.project('${f.root.path}/missing.mp4');
            f.state.recentProjects = [f.state.project];
            await tester.pumpWidget(BheMobileApp(appState: f.state));
            await tester.pump();
            if (brightness == Brightness.light) {
              tester
                  .widget<PopupMenuButton<String>>(
                    find.byType(PopupMenuButton<String>),
                  )
                  .onSelected!('theme');
              await tester.pump();
            }
            final ctx = tester.element(find.byType(Scaffold).first);
            final l10n = Localizations.of<BheLocalizations>(
              ctx,
              BheLocalizations,
            )!;
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('project-name-rename')))
                  .height,
              greaterThanOrEqualTo(48),
            );
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('project-name-rename')))
                  .width,
              greaterThanOrEqualTo(48),
            );
            await tester.tap(find.byKey(const ValueKey('project-name-rename')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.byKey(const ValueKey('project-action-renameProject')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
            await tester.enterText(find.byType(TextField).last, '   ');
            await tester.tap(find.text(l10n.text('保存')).last);
            await tester.pump();
            expect(find.text(l10n.text('名称不能为空')), findsOneWidget);
            await tester.enterText(find.byType(TextField).last, 'x' * 41);
            expect(
              tester
                  .widget<TextField>(find.byType(TextField).last)
                  .controller!
                  .text
                  .length,
              40,
            );
            await tester.enterText(find.byType(TextField).last, ' New name ');
            await tester.tap(find.text(l10n.text('保存')).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await waitProjectWrites(tester, f.state.pendingProjectWrites);
            expect(f.state.project.name, 'New name');
            expect(f.state.recentProjects.first.name, 'New name');
            await tester.tap(find.byKey(const ValueKey('project-name-rename')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.byKey(const ValueKey('project-action-renameProject')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              tester
                  .widget<TextField>(find.byType(TextField).last)
                  .controller!
                  .text,
              'New name',
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() => pumpEventQueue());
            tester.binding.platformDispatcher.clearLocaleTestValue();
            tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
            await tester.binding.setSurfaceSize(null);
          }
        });
      }
    }
  }
}
