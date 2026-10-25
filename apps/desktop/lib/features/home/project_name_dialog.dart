import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';
import '../../providers/project_state.dart';

/// 项目显示名编辑框。只改数据库里的 name，不动磁盘目录。
///
/// 返回保存成功后的新名字；取消或校验失败返回 null。
Future<String?> showProjectNameDialog(
  BuildContext context, {
  required String initialName,
  required Future<bool> Function(String name) onSubmit,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _ProjectNameDialog(
      initialName: initialName,
      onSubmit: onSubmit,
    ),
  );
}

class _ProjectNameDialog extends ConsumerStatefulWidget {
  const _ProjectNameDialog({required this.initialName, required this.onSubmit});

  final String initialName;
  final Future<bool> Function(String name) onSubmit;

  @override
  ConsumerState<_ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends ConsumerState<_ProjectNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(
        () => _error = l10n?.projectNameEmpty ?? '项目名称不能为空',
      );
      return;
    }
    if (name.length > projectNameMaxLength) {
      setState(
        () => _error =
            l10n?.projectNameTooLong(projectNameMaxLength) ??
            '项目名称最多 $projectNameMaxLength 个字符',
      );
      return;
    }
    if (name == widget.initialName) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.onSubmit(name);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(name);
    } else {
      setState(() {
        _saving = false;
        _error = l10n?.projectNameSaveFailed ?? '项目名称保存失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return AlertDialog(
      title: Text(l10n?.renameProject ?? '重命名项目'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_saving,
              maxLength: projectNameMaxLength,
              decoration: InputDecoration(
                labelText: l10n?.projectName ?? '项目名称',
                hintText: l10n?.projectNameHint ?? '例如：10 月 24 日 训练赛',
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _saving ? null : _submit(),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              l10n?.projectNameScopeHint ??
                  '只修改显示名称，项目文件夹和已导出的视频不受影响。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n?.cancel ?? '取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n?.save ?? '保存'),
        ),
      ],
    );
  }
}
