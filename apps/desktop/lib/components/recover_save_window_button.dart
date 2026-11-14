import 'dart:async';

import 'package:flutter/material.dart';
import '../core/native_file_dialog.dart';

import 'package:bhe_l10n/bhe_l10n.dart';

/// L224：用户切到别的应用后保存面板可能被盖住，界面看起来像卡在“准备输出位置”。
/// 8 秒还没结束就给出“找回保存窗口”按钮，点了让原生把面板重新提到最前。
class RecoverSaveWindowButton extends StatefulWidget {
  const RecoverSaveWindowButton({
    super.key,
    required this.visible,
    this.delay = const Duration(seconds: 8),
    this.onRecover,
  });

  final bool visible;
  final Duration delay;

  /// 注入用（测试/其他平台）；默认重新置顶 macOS 文件面板。
  final Future<void> Function()? onRecover;

  @override
  State<RecoverSaveWindowButton> createState() => _RecoverSaveWindowButtonState();
}

class _RecoverSaveWindowButtonState extends State<RecoverSaveWindowButton> {
  Timer? _timer;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(RecoverSaveWindowButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _sync();
  }

  void _sync() {
    _timer?.cancel();
    if (!widget.visible) {
      _expired = false;
      return;
    }
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _expired = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _recover() async {
    final action = widget.onRecover;
    if (action != null) {
      await action();
      return;
    }
    await refocusFileDialog();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible || !_expired) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextButton.icon(
        key: const Key('recover-save-window'),
        onPressed: _recover,
        icon: const Icon(Icons.open_in_new, size: 16),
        label: Text(context.bheText('找回保存窗口')),
      ),
    );
  }
}
