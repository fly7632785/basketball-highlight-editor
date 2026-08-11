// test/components/cs_chips_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:desktop/components/cs_status_chip.dart';
import 'package:desktop/components/cs_metric_tile.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('goal chip shows 已确认 + check icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const CsStatusChip(status: ReviewStatus.goal),
      ),
    );
    expect(find.text('已确认'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);
  });
  testWidgets('metric tile shows label and tabular value', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const CsMetricTile(label: '进球', value: '4'),
      ),
    );
    expect(find.text('进球'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });
}
