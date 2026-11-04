import 'dart:io';

import 'package:desktop/features/import_video/hoop_example.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('示例图随包、体积很小', () {
    for (final example in HoopExample.values) {
      final file = File(example.asset);
      expect(file.existsSync(), isTrue, reason: example.asset);
      expect(file.lengthSync(), lessThan(30 * 1024), reason: example.asset);
    }
  });

  testWidgets('三张示例图都能加载，带中文说明', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HoopExampleGallery())),
    );
    final context = tester.element(find.byType(HoopExampleGallery));
    await tester.runAsync(() async {
      for (final example in HoopExample.values) {
        await precacheImage(AssetImage(example.asset), context);
      }
    });
    await tester.pump();
    for (final example in shotExamples) {
      expect(find.byKey(ValueKey('hoop-example-${example.name}')), findsOneWidget);
      expect(find.text(example.caption), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('「看示例」对话框能打开和关闭', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showHoopExampleDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hoop-example-dialog')), findsOneWidget);
    expect(find.text('框选示例'), findsOneWidget);
    for (final example in HoopExample.values) {
      expect(find.byKey(ValueKey('hoop-example-${example.name}')), findsOneWidget);
    }
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hoop-example-dialog')), findsNothing);
  });
}
