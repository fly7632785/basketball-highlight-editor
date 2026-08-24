// test/components/cs_step_indicator_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:desktop/components/cs_step_indicator.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('renders indices for incomplete steps', (tester) async {
    final steps = <CsStep>[
      (index: '01', title: '导入', icon: LucideIcons.upload, completed: false),
      (index: '02', title: '审核', icon: LucideIcons.check, completed: false),
      (index: '03', title: '导出', icon: LucideIcons.download, completed: false),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: Center(child: CsStepIndicator(steps: steps)),
    ));
    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
    expect(find.text('03'), findsOneWidget);
  });
  testWidgets('completed step shows check icon', (tester) async {
    final steps = <CsStep>[
      (index: '01', title: '导入', icon: LucideIcons.check, completed: true),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: Center(child: CsStepIndicator(steps: steps)),
    ));
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
  });
}
