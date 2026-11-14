part of '../../mobile_ui.dart';

class _PlayerTagSheet extends StatefulWidget {
  const _PlayerTagSheet({
    required this.state,
    required this.players,
    this.initialPlayer,
  });
  final MobileAppState state;
  final List<String> players;
  final String? initialPlayer;

  @override
  State<_PlayerTagSheet> createState() => _PlayerTagSheetState();
}

class _PlayerTagSheetState extends State<_PlayerTagSheet> {
  late final TextEditingController _input;
  late List<String> _players;
  late final int _session;
  String? _selected;
  bool _creating = false;
  bool _saving = false;
  bool _saveFailed = false;
  bool _failureHasDiagnostic = false;
  DiagnosticErrorRecord? _failureRecord;
  String _failureMessage = '保存失败，请重试';

  @override
  void initState() {
    super.initState();
    _session = widget.state.projectSession;
    widget.state.addListener(_onProjectState);
    _selected = widget.initialPlayer;
    _players = [...widget.players];
    _input = TextEditingController();
  }

  void _onProjectState() {
    if (!mounted || _saving || widget.state.projectSession == _session) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_saving &&
          widget.state.projectSession != _session &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
  }

  bool _closeIfStale() {
    if (widget.state.projectSession == _session) return false;
    Navigator.of(context).pop();
    return true;
  }

  @override
  void dispose() {
    widget.state.removeListener(_onProjectState);
    _input.dispose();
    super.dispose();
  }

  void _close(String value) {
    if (mounted && !_saving) Navigator.of(context).pop(value);
  }

  Future<void> _managePlayer(String player, String action) async {
    if (action == 'delete') {
      final count = widget.state.project.candidates
          .where((c) => c.player == player)
          .length;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(
            Localizations.localeOf(context).languageCode == 'en'
                ? '${context.bheText('删除')} “$player”?'
                : '${context.bheText('删除')}「$player」？',
          ),
          content: count == 0
              ? null
              : Text(
                  '${context.bheText('已标记的')} $count ${context.bheText('个片段会变成未标记。')}',
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.bheText('取消')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              style: TextButton.styleFrom(foregroundColor: BhePalette.error),
              child: Text(context.bheText('删除')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() {
        _saving = true;
        _saveFailed = false;
      });
      final previousDiagnostic = widget.state.diagnosticError;
      final success = await widget.state.removePlayer(player);
      if (!mounted) return;
      if (_closeIfStale()) return;
      setState(() {
        _saving = false;
        _saveFailed = !success;
        _failureHasDiagnostic = !identical(
          previousDiagnostic,
          widget.state.diagnosticError,
        );
        _failureRecord = _failureHasDiagnostic
            ? widget.state.diagnosticError
            : null;
        _failureMessage = _failureHasDiagnostic ? '保存失败，请重试' : '操作已取消';
      });
      if (!success) return;
      setState(() {
        _players = [...widget.state.project.players];
        if (_selected == player) _selected = null;
      });
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenamePlayerDialog(state: widget.state, player: player),
    );
    if (name == null || !mounted) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    final previousDiagnostic = widget.state.diagnosticError;
    final success = await widget.state.renamePlayer(player, name);
    if (!mounted) return;
    if (_closeIfStale()) return;
    setState(() {
      _saving = false;
      _saveFailed = !success;
      _failureHasDiagnostic = !identical(
        previousDiagnostic,
        widget.state.diagnosticError,
      );
      _failureRecord = _failureHasDiagnostic
          ? widget.state.diagnosticError
          : null;
      _failureMessage = _failureHasDiagnostic
          ? '保存失败，请重试'
          : widget.state.project.players.contains(name)
          ? '已有同名球员'
          : '操作已取消';
    });
    if (!success) return;
    setState(() {
      _players = [...widget.state.project.players];
      if (_selected == player) _selected = name;
    });
  }

  Future<void> _openGroups() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: false,
      isDismissible: false,
      builder: (_) => _PlayerGroupsSheet(state: widget.state),
    );
    if (mounted) setState(() => _players = [...widget.state.project.players]);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _SheetFrame(
        title: context.bheText('球员标签'),
        canClose: !_saving,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_saving) const LinearProgressIndicator(),
            if (_saveFailed)
              _InlineNotice(
                message: context.bheText(_failureMessage),
                error: true,
                action: !_failureHasDiagnostic
                    ? null
                    : TextButton(
                        onPressed: () => showMobileDiagnostics(
                          context,
                          error: _failureRecord,
                        ),
                        child: Text(context.bheText('反馈')),
                      ),
              ),
            if (_players.isEmpty)
              Text(
                context.bheText('还没有球员标签。'),
                style: Theme.of(context).textTheme.bodySmall,
              )
            else ...[
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (index, player) in _players.indexed) ...[
                    if (index > 0) const Padding(
                      padding: EdgeInsets.only(left: 16),
                      child: Divider(height: 1),
                    ),
                    Row(children: [
                      Expanded(child: InkWell(
                        key: ValueKey('player-select-$player'),
                        onTap: _saving ? null : () => _close(player),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 52),
                          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                          color: _selected == player ? BhePalette.orange.withValues(alpha: .10) : null,
                          child: Row(children: [
                            Expanded(child: Text(player, overflow: TextOverflow.ellipsis,
                              style: _selected == player ? const TextStyle(color: BhePalette.orange, fontWeight: FontWeight.bold) : null)),
                            if (_selected == player) const Icon(LucideIcons.check, size: 18, color: BhePalette.orange),
                          ]),
                        ),
                      )),
                      PopupMenuButton<String>(
                        key: ValueKey('player-menu-$player'),
                        tooltip: context.bheText('更多操作'),
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: const Icon(LucideIcons.ellipsis),
                        enabled: !_saving,
                        onSelected: (action) => _managePlayer(player, action),
                        itemBuilder: (context) => [
                          PopupMenuItem(value: 'rename', child: Text(context.bheText('重命名'))),
                          PopupMenuItem(value: 'delete', child: Text(context.bheText('删除'))),
                        ],
                      ),
                    ]),
                  ],
                ]),
              ),
            ],
            const SizedBox(height: 14),
            if (_creating)
              TextField(
                controller: _input,
                enabled: !_saving,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: context.bheText('新建球员标签'),
                  hintText: context.bheText('例如 #10 Kobe'),
                  prefixIcon: const Icon(LucideIcons.tag, size: 18),
                  suffixIcon: TextButton(
                    onPressed: _saving || _input.text.trim().isEmpty ? null : () => _close(_input.text.trim()),
                    child: Text(Localizations.localeOf(context).languageCode == 'zh' ? '添加' : 'Add'),
                  ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (value) { if (value.trim().isNotEmpty) _close(value.trim()); },
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => setState(() => _creating = true),
                      icon: const Icon(LucideIcons.plus, size: 17),
                      label: Text(context.bheText('新建球员标签')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _openGroups,
                    icon: const Icon(LucideIcons.users, size: 17),
                    label: Text(context.bheText('球员分组')),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _saving || _selected == null ? null : () => _close(''),
              child: Text(context.bheText('清除标签')),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RenamePlayerDialog extends StatefulWidget {
  const _RenamePlayerDialog({required this.state, required this.player});
  final MobileAppState state;
  final String player;
  @override
  State<_RenamePlayerDialog> createState() => _RenamePlayerDialogState();
}

class _RenamePlayerDialogState extends State<_RenamePlayerDialog> {
  late final TextEditingController controller = TextEditingController(
    text: widget.player,
  );
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.bheText('重命名球员')),
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
          final value = controller.text.trim();
          final problem = value.isEmpty
              ? '名称不能为空'
              : value != widget.player &&
                    widget.state.project.players.contains(value)
              ? '已有同名球员'
              : null;
          if (problem != null) {
            setState(() => error = problem);
            return;
          }
          Navigator.pop(context, value);
        },
        child: Text(context.bheText('保存')),
      ),
    ],
  );
}
