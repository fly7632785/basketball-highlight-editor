import 'package:desktop/components/recover_save_window_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// L224：保存面板被盖住时，8 秒后才出现“找回保存窗口”，面板结束后消失。
void main() {
  Future<void> pump(WidgetTester tester, {required bool visible, void Function()? onTap}) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecoverSaveWindowButton(
          visible: visible,
          onRecover: () async => onTap?.call(),
        ),
      ),
    ));
  }

  testWidgets('前 8 秒不显示，8 秒后出现', (tester) async {
    await pump(tester, visible: true);
    expect(find.byKey(const Key('recover-save-window')), findsNothing);

    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(const Key('recover-save-window')), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('recover-save-window')), findsOneWidget);
  });

  testWidgets('面板结束（visible=false）时按钮消失', (tester) async {
    await pump(tester, visible: true);
    await tester.pump(const Duration(seconds: 9));
    expect(find.byKey(const Key('recover-save-window')), findsOneWidget);

    await pump(tester, visible: false);
    await tester.pump();
    expect(find.byKey(const Key('recover-save-window')), findsNothing);
  });

  testWidgets('点击会调找回动作', (tester) async {
    var taps = 0;
    await pump(tester, visible: true, onTap: () => taps++);
    await tester.pump(const Duration(seconds: 9));
    await tester.tap(find.byKey(const Key('recover-save-window')));
    await tester.pump();
    expect(taps, 1);
  });
}
