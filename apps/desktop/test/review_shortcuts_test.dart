import 'package:desktop/features/review/review_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('每个审核动作在表里恰好出现一次，按键不重复', () {
    final actions = reviewShortcuts.map((item) => item.action).toList();
    expect(actions.toSet().length, actions.length);
    expect(actions.toSet(), ReviewShortcutAction.values.toSet());
    final keys = [
      for (final item in reviewShortcuts)
        if (!item.needsCommand) ...item.keys,
    ];
    expect(keys.toSet().length, keys.length);
  });

  test('按键查表得到的动作就是键盘处理会执行的动作', () {
    ReviewShortcutAction? of(LogicalKeyboardKey key, {bool command = false}) =>
        reviewShortcutActionFor(key, commandPressed: command);
    expect(of(LogicalKeyboardKey.space), ReviewShortcutAction.playPause);
    expect(of(LogicalKeyboardKey.arrowUp), ReviewShortcutAction.previousCandidate);
    expect(of(LogicalKeyboardKey.arrowDown), ReviewShortcutAction.nextCandidate);
    expect(of(LogicalKeyboardKey.arrowLeft), ReviewShortcutAction.seekBack);
    expect(of(LogicalKeyboardKey.arrowRight), ReviewShortcutAction.seekForward);
    expect(of(LogicalKeyboardKey.keyC), ReviewShortcutAction.include);
    expect(of(LogicalKeyboardKey.enter), ReviewShortcutAction.include);
    expect(of(LogicalKeyboardKey.keyX), ReviewShortcutAction.exclude);
    expect(of(LogicalKeyboardKey.backspace), ReviewShortcutAction.exclude);
    expect(of(LogicalKeyboardKey.keyL), ReviewShortcutAction.loop);
    expect(of(LogicalKeyboardKey.keyA), ReviewShortcutAction.annotations);
    // 撤销必须带 Cmd/Ctrl；单按 Z 什么都不做。
    expect(of(LogicalKeyboardKey.keyZ, command: true), ReviewShortcutAction.undo);
    expect(of(LogicalKeyboardKey.keyZ), isNull);
    expect(of(LogicalKeyboardKey.keyC, command: true), isNull);
    // 球员标签键不在这张表里，由单独的键位表处理。
    expect(of(LogicalKeyboardKey.digit1), isNull);
  });

  test('Mac 显示 ⌘，Windows 显示 Ctrl', () {
    final undo = reviewShortcuts.firstWhere(
      (item) => item.action == ReviewShortcutAction.undo,
    );
    expect(shortcutKeysText(undo, isMac: true), '⌘+Z');
    expect(shortcutKeysText(undo, isMac: false), 'Ctrl+Z');
    final include = reviewShortcuts.firstWhere(
      (item) => item.action == ReviewShortcutAction.include,
    );
    expect(shortcutKeysText(include, isMac: true), 'C / Enter');
  });

  test('球员标签键位说明来自键位表', () {
    expect(playerShortcutKeysText(), '1–9、Q–P');
    expect(reviewPlayerKeys.length, 20);
  });

  test('调整范围窗口的快捷键常量就是文字里写的 I / O', () {
    expect(keyCapLabel(rangeSetStartKey), 'I');
    expect(keyCapLabel(rangeSetEndKey), 'O');
  });

  testWidgets('快捷键一览列出表里的每个动作和调整范围窗口的键', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showReviewShortcutsDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcuts-dialog')), findsOneWidget);
    for (final shortcut in reviewShortcuts) {
      expect(find.textContaining(shortcut.label), findsWidgets, reason: shortcut.label);
    }
    expect(find.text('1–9、Q–P'), findsOneWidget);
    expect(find.text('把当前位置设为开始'), findsOneWidget);
  });
}
