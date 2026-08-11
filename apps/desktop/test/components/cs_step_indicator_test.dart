// test/components/cs_step_indicator_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:desktop/components/cs_step_indicator.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('renders indices for incomplete steps', (tester) async {
    final steps = <CsStep>[
      (
        index: '01',
        title: '导入',
        icon: CupertinoIcons.arrow_up_to_line,
        completed: false,
      ),
      (
        index: '02',
        title: '审核',
        icon: CupertinoIcons.check_mark,
        completed: false,
      ),
      (
        index: '03',
        title: '导出',
        icon: CupertinoIcons.arrow_down_to_line,
        completed: false,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Center(child: CsStepIndicator(steps: steps)),
      ),
    );
    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
    expect(find.text('03'), findsOneWidget);
  });
  testWidgets('completed step shows check icon', (tester) async {
    final steps = <CsStep>[
      (
        index: '01',
        title: '导入',
        icon: CupertinoIcons.check_mark,
        completed: true,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Center(child: CsStepIndicator(steps: steps)),
      ),
    );
    expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);
  });
}
