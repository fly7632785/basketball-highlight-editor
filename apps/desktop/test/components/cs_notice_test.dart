// test/components/cs_notice_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:desktop/components/cs_notice.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('success notice shows title icon and close, tap dismisses', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Center(
          child: CsNotice(
            message: const NoticeMessage(
              id: '1',
              severity: NoticeSeverity.success,
              title: '保存成功',
            ),
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存成功'), findsOneWidget);
    expect(
      find.byIcon(CupertinoIcons.check_mark_circled_solid),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    expect(dismissed, isTrue);
  });
}
