import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openExportScope(WidgetTester tester) =>
    openExportControl(tester, 'export-scope');

Future<void> openExportControl(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  final settings = find.byKey(const ValueKey('export-settings'));
  final scrollable = find.descendant(
    of: settings,
    matching: find.byType(Scrollable),
  );
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(control, 125, scrollable: scrollable);
  await tester.pump();
  await tester.tap(control);
  await settleExportRoute(tester);
}

Future<void> chooseExportMode(
  WidgetTester tester,
  String label,
  String done,
) async {
  await openExportControl(tester, 'export-mode');
  final option = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(label),
  );
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pump();
  await finishExportSettings(tester, done);
}

Future<void> finishExportSettings(WidgetTester tester, String done) async {
  final action = find.text(done);
  await tester.ensureVisible(action);
  await tester.tap(action);
  await settleExportRoute(tester);
}

Future<void> settleExportRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}
