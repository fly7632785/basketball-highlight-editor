import 'dart:io' show Platform;

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 审核页的单键快捷键。键盘处理（review_screen 的 `_handleShortcut`）和新手引导、
/// 「快捷键一览」都读这一张表，改键只改这里。
enum ReviewShortcutAction {
  playPause,
  seekBack,
  seekForward,
  previousCandidate,
  nextCandidate,
  include,
  exclude,
  undo,
  loop,
  annotations,
  toggleMute,
  volumeDown,
  volumeUp,
}

class ReviewShortcut {
  const ReviewShortcut(this.action, this.label, this.keys, {this.note});

  final ReviewShortcutAction action;

  /// 中文原文，显示时经 `bheText` 翻译。
  final String label;
  final List<LogicalKeyboardKey> keys;

  /// 补充说明（中文原文），例如 Shift 的细调。
  final String? note;

  /// 需要同时按 Cmd（Mac）/ Ctrl（Windows）。
  bool get needsCommand => action == ReviewShortcutAction.undo;
}

const List<ReviewShortcut> reviewShortcuts = [
  ReviewShortcut(ReviewShortcutAction.playPause, '播放 / 暂停', [
    LogicalKeyboardKey.space,
  ]),
  ReviewShortcut(
    ReviewShortcutAction.seekBack,
    '后退 2 秒',
    [LogicalKeyboardKey.arrowLeft],
    note: '加 Shift 后退 0.1 秒',
  ),
  ReviewShortcut(
    ReviewShortcutAction.seekForward,
    '前进 2 秒',
    [LogicalKeyboardKey.arrowRight],
    note: '加 Shift 前进 0.1 秒',
  ),
  ReviewShortcut(ReviewShortcutAction.previousCandidate, '上一个候选', [
    LogicalKeyboardKey.arrowUp,
  ]),
  ReviewShortcut(ReviewShortcutAction.nextCandidate, '下一个候选', [
    LogicalKeyboardKey.arrowDown,
  ]),
  ReviewShortcut(ReviewShortcutAction.include, '保留这个候选', [
    LogicalKeyboardKey.keyC,
    LogicalKeyboardKey.enter,
  ]),
  ReviewShortcut(ReviewShortcutAction.exclude, '排除这个候选', [
    LogicalKeyboardKey.keyX,
    LogicalKeyboardKey.backquote,
    LogicalKeyboardKey.backspace,
  ]),
  ReviewShortcut(ReviewShortcutAction.undo, '撤销上一步审核', [
    LogicalKeyboardKey.keyZ,
  ]),
  ReviewShortcut(ReviewShortcutAction.loop, '循环播放当前片段', [
    LogicalKeyboardKey.keyL,
  ]),
  ReviewShortcut(ReviewShortcutAction.annotations, '显示 / 隐藏识别标注', [
    LogicalKeyboardKey.keyA,
  ]),
  ReviewShortcut(ReviewShortcutAction.toggleMute, '静音 / 取消静音', [
    LogicalKeyboardKey.keyM,
  ]),
  ReviewShortcut(ReviewShortcutAction.volumeDown, '音量 -10%', [
    LogicalKeyboardKey.minus,
  ]),
  ReviewShortcut(ReviewShortcutAction.volumeUp, '音量 +10%', [
    // 主键盘的 = （Shift 就是 +）和数字键盘的 + 都能用。
    LogicalKeyboardKey.equal,
    LogicalKeyboardKey.add,
  ]),
];

/// 按键对应的审核动作；不是快捷键返回 null。组合键（Cmd/Ctrl+Z）由调用方先判断修饰键。
ReviewShortcutAction? reviewShortcutActionFor(
  LogicalKeyboardKey key, {
  required bool commandPressed,
}) {
  for (final shortcut in reviewShortcuts) {
    if (shortcut.needsCommand != commandPressed) continue;
    if (shortcut.keys.contains(key)) return shortcut.action;
  }
  return null;
}

/// 球员标签快捷键：第 0 项清除标签，其余按球员顺序选第 N 个。
const List<(LogicalKeyboardKey, LogicalKeyboardKey)> reviewPlayerKeys = [
  (LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0),
  (LogicalKeyboardKey.digit1, LogicalKeyboardKey.numpad1),
  (LogicalKeyboardKey.digit2, LogicalKeyboardKey.numpad2),
  (LogicalKeyboardKey.digit3, LogicalKeyboardKey.numpad3),
  (LogicalKeyboardKey.digit4, LogicalKeyboardKey.numpad4),
  (LogicalKeyboardKey.digit5, LogicalKeyboardKey.numpad5),
  (LogicalKeyboardKey.digit6, LogicalKeyboardKey.numpad6),
  (LogicalKeyboardKey.digit7, LogicalKeyboardKey.numpad7),
  (LogicalKeyboardKey.digit8, LogicalKeyboardKey.numpad8),
  (LogicalKeyboardKey.digit9, LogicalKeyboardKey.numpad9),
  // 第 10 个以后用 Q 到 P 这一排字母。
  (LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyQ),
  (LogicalKeyboardKey.keyW, LogicalKeyboardKey.keyW),
  (LogicalKeyboardKey.keyE, LogicalKeyboardKey.keyE),
  (LogicalKeyboardKey.keyR, LogicalKeyboardKey.keyR),
  (LogicalKeyboardKey.keyT, LogicalKeyboardKey.keyT),
  (LogicalKeyboardKey.keyY, LogicalKeyboardKey.keyY),
  (LogicalKeyboardKey.keyU, LogicalKeyboardKey.keyU),
  (LogicalKeyboardKey.keyI, LogicalKeyboardKey.keyI),
  (LogicalKeyboardKey.keyO, LogicalKeyboardKey.keyO),
  (LogicalKeyboardKey.keyP, LogicalKeyboardKey.keyP),
];

/// 「调整范围」窗口里的快捷键（窗口自己处理，和审核页那张表不是一回事）。
const rangeSetStartKey = LogicalKeyboardKey.keyI;
const rangeSetEndKey = LogicalKeyboardKey.keyO;

String keyCapLabel(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';
  if (key == LogicalKeyboardKey.space) return 'Space';
  if (key == LogicalKeyboardKey.enter) return 'Enter';
  if (key == LogicalKeyboardKey.backspace) return 'Backspace';
  return key.keyLabel.toUpperCase();
}

/// 一行快捷键的按键文字，例如「C / Enter」「⌘+Z」。
String shortcutKeysText(ReviewShortcut shortcut, {required bool isMac}) {
  final caps = [for (final key in shortcut.keys) keyCapLabel(key)];
  if (shortcut.needsCommand) {
    return '${isMac ? '⌘' : 'Ctrl'}+${caps.join(' / ')}';
  }
  return caps.join(' / ');
}

/// 球员标签快捷键的说明文字（按键范围从表里推出，不手写）。
String playerShortcutKeysText() {
  final digits = reviewPlayerKeys
      .skip(1)
      .take(9)
      .map((pair) => keyCapLabel(pair.$1))
      .toList();
  final letters = reviewPlayerKeys
      .skip(10)
      .map((pair) => keyCapLabel(pair.$1))
      .toList();
  return '${digits.first}–${digits.last}、${letters.first}–${letters.last}';
}

/// 「调整范围」窗口里的几个快捷键，和 [rangeSetStartKey] 等常量对应。
List<(String, String)> rangeEditorShortcutRows() => [
  ('Space', '播放 / 暂停'),
  (keyCapLabel(rangeSetStartKey), '把当前位置设为开始'),
  (keyCapLabel(rangeSetEndKey), '把当前位置设为结束'),
  ('← / →', '前后 1 秒'),
];

/// 一览里的每一行：(按键文字, 说明)，说明已按当前语言翻译。
List<(String, String)> reviewShortcutRows(
  BuildContext context, {
  bool? isMac,
}) {
  final mac = isMac ?? Platform.isMacOS;
  return [
    for (final shortcut in reviewShortcuts)
      (
        shortcutKeysText(shortcut, isMac: mac),
        shortcut.note == null
            ? context.bheText(shortcut.label)
            : '${context.bheText(shortcut.label)}（${context.bheText(shortcut.note!)}）',
      ),
    (playerShortcutKeysText(), context.bheText('给片段选第 N 个球员')),
    (keyCapLabel(reviewPlayerKeys.first.$1), context.bheText('清除球员标签')),
  ];
}

/// 新手引导里用的多行文字。
String reviewShortcutGuideText(BuildContext context, {bool? isMac}) => [
  for (final (keys, label) in reviewShortcutRows(context, isMac: isMac))
    '$keys   $label',
].join('\n');

Future<void> showReviewShortcutsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      Widget section(String title, List<(String, String)> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              context.bheText(title),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final (keys, label) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(
                      keys,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Expanded(child: Text(label)),
                ],
              ),
            ),
        ],
      );
      return AlertDialog(
        key: const Key('shortcuts-dialog'),
        title: Text(context.bheText('快捷键一览')),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                section('审核页', reviewShortcutRows(context)),
                section('调整范围窗口', [
                  for (final (keys, label) in rangeEditorShortcutRows())
                    (keys, context.bheText(label)),
                ]),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.bheText('关闭')),
          ),
        ],
      );
    },
  );
}
