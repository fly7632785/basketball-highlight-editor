part of '../../mobile_ui.dart';

class _PlayerGroupsSheet extends StatefulWidget {
  const _PlayerGroupsSheet({required this.state, this.allowImport = true});
  final MobileAppState state;
  final bool allowImport;
  @override
  State<_PlayerGroupsSheet> createState() => _PlayerGroupsSheetState();
}

class _PlayerGroupsSheetState extends State<_PlayerGroupsSheet> {
  bool _busy = false;
  bool _failed = false;
  DiagnosticErrorRecord? _failure;

  Future<bool> _run(
    Future<bool> Function() action, {
    bool project = false,
  }) async {
    if (_busy) return false;
    final before = project
        ? widget.state.diagnosticError
        : widget.state.playerGroupError;
    setState(() {
      _busy = true;
      _failed = false;
      _failure = null;
    });
    final success = await action();
    if (!mounted) return success;
    final after = project
        ? widget.state.diagnosticError
        : widget.state.playerGroupError;
    setState(() {
      _busy = false;
      _failed = !success;
      _failure = identical(before, after) ? null : after;
    });
    return success;
  }

  Future<bool> _confirm(String title, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(context.bheText(title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.bheText('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(context.bheText(action)),
            ),
          ],
        ),
      ) ==
      true;

  Future<String?> _askName({String initial = ''}) => showDialog<String>(
    context: context,
    builder: (_) => _GroupNameDialog(state: widget.state, initial: initial),
  );

  Future<void> _saveCurrent() async {
    final name = await _askName();
    if (!mounted || name == null) return;
    var replace = false;
    if (widget.state.playerGroups.any((group) => group.name == name)) {
      if (!await _confirm('已有同名分组，是否替换？', '替换') || !mounted) return;
      replace = true;
    }
    await _run(
      () => widget.state.savePlayerGroup(name, replaceExisting: replace),
    );
  }

  Future<void> _manage(
    ({String name, List<String> players}) group,
    String action,
  ) async {
    if (action == 'edit') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _PlayerGroupEditor(state: widget.state, group: group),
        ),
      );
    } else if (action == 'delete') {
      if (!await _confirm('确认删除分组？', '删除') || !mounted) return;
      await _run(() => widget.state.deletePlayerGroup(group.name));
    } else if (action == 'rename') {
      final name = await _askName(initial: group.name);
      if (!mounted || name == null || name == group.name) return;
      await _run(() => widget.state.renamePlayerGroup(group.name, name));
    } else if (action == 'default') {
      final next = widget.state.defaultPlayerGroupName == group.name
          ? null
          : group.name;
      await _run(() => widget.state.setDefaultPlayerGroup(next));
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) => _SheetFrame(
        title: context.bheText('球员分组'),
        canClose: !_busy,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (widget.state.playerGroupDataInvalid)
              _InlineNotice(
                error: true,
                message: context.bheText('分组数据异常，无法修改'),
                action: TextButton(
                  onPressed: () => showMobileDiagnostics(
                    context,
                    error: widget.state.playerGroupError,
                  ),
                  child: Text(context.bheText('反馈')),
                ),
              ),
            if (_failed)
              _InlineNotice(
                error: true,
                message: context.bheText(
                  _failure == null ? '分组操作未完成' : '保存失败，请重试',
                ),
                action: _failure == null
                    ? null
                    : TextButton(
                        onPressed: () =>
                            showMobileDiagnostics(context, error: _failure),
                        child: Text(context.bheText('反馈')),
                      ),
              ),
            if (widget.state.playerGroups.isEmpty)
              Text(context.bheText('还没有分组。把当前项目的球员存为分组后，其他项目可以一键导入。')),
            if (widget.state.playerGroups.isNotEmpty)
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (index, group) in widget.state.playerGroups.indexed) ...[
                    if (index > 0) const Padding(padding: EdgeInsets.only(left: 16), child: Divider(height: 1)),
              ListTile(
                key: ValueKey('player-group-${group.name}'),
                contentPadding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                minTileHeight: 52,
                onTap: _busy || !widget.allowImport ? null : () async {
                  if (await _run(() => widget.state.importPlayers(group.players), project: true) && context.mounted) {
                    Navigator.pop(context);
                  }
                },
                title: Text(group.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  group.players.join('、'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.state.defaultPlayerGroupName == group.name)
                      Text(context.bheText('默认')),
                    if (widget.allowImport)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                if (await _run(
                                      () => widget.state.importPlayers(
                                        group.players,
                                      ),
                                      project: true,
                                    ) &&
                                    context.mounted) {
                                  Navigator.pop(context);
                                }
                              },
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        child: Text(context.bheText('导入')),
                      ),
                    PopupMenuButton<String>(
                      key: ValueKey('player-group-menu-${group.name}'),
                      enabled: !_busy,
                      tooltip: context.bheText('更多操作'),
                      onSelected: (action) => _manage(group, action),
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(context.bheText('编辑')),
                        ),
                        PopupMenuItem(
                          value: 'rename',
                          child: Text(context.bheText('重命名')),
                        ),
                        PopupMenuItem(
                          value: 'default',
                          child: Text(
                            context.bheText(
                              widget.state.defaultPlayerGroupName == group.name
                                  ? '取消默认'
                                  : '设为默认',
                            ),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(context.bheText('删除')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
                  ],
                ]),
              ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _busy || widget.state.project.players.isEmpty
                  ? null
                  : _saveCurrent,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(LucideIcons.save, size: 17),
              label: Text(context.bheText('把当前球员存为分组')),
            ),
          ],
        ),
      ),
    ),
  );
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog({required this.state, required this.initial});
  final MobileAppState state;
  final String initial;
  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.initial,
  );
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.bheText('分组名称')),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: InputDecoration(
        errorText: error == null ? null : context.bheText(error!),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.bheText('取消')),
      ),
      FilledButton(
        onPressed: () {
          final name = controller.text.trim();
          if (name.isEmpty) {
            setState(() => error = '分组名不能为空');
            return;
          }
          if (widget.initial.isNotEmpty &&
              name != widget.initial &&
              widget.state.playerGroups.any((group) => group.name == name)) {
            setState(() => error = '分组名已存在，请使用其他名称');
            return;
          }
          Navigator.pop(context, name);
        },
        child: Text(context.bheText('保存')),
      ),
    ],
  );
}
