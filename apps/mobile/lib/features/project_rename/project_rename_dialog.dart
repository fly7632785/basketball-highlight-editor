part of '../../mobile_ui.dart';

Future<void> _showProjectRename(
  BuildContext context,
  MobileAppState state,
) async {
  final id = state.project.id;
  final value = await showDialog<String>(
    context: context,
    builder: (_) => _ProjectRenameDialog(name: state.project.name),
  );
  if (value == null || !context.mounted || state.project.id != id) return;
  final saved = await state.renameProject(value);
  if (!saved && context.mounted) {
    showBheToast(
      context,
      context.bheText('保存失败，请重试'),
      action: SnackBarAction(
        label: context.bheText('反馈'),
        onPressed: () =>
            showMobileDiagnostics(context, error: state.diagnosticError),
      ),
    );
  }
}

class _ProjectRenameDialog extends StatefulWidget {
  const _ProjectRenameDialog({required this.name});
  final String name;
  @override
  State<_ProjectRenameDialog> createState() => _ProjectRenameDialogState();
}

class _ProjectRenameDialogState extends State<_ProjectRenameDialog> {
  late final controller = TextEditingController(text: widget.name);
  bool invalid = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.bheText('重命名项目')),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: 40,
      decoration: InputDecoration(
        errorText: invalid ? context.bheText('名称不能为空') : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.bheText('取消')),
      ),
      FilledButton(
        onPressed: () {
          final value = controller.text.trim();
          if (value.isEmpty) {
            setState(() => invalid = true);
            return;
          }
          Navigator.pop(context, value);
        },
        child: Text(context.bheText('保存')),
      ),
    ],
  );
}
