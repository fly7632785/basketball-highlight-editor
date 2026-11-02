import '../../core/app_log.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_groups_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// Edits a local copy. Cancelling never mutates the saved group or a project.
class PlayerGroupEditor extends ConsumerStatefulWidget {
  const PlayerGroupEditor({required this.group, super.key});

  final PlayerGroup group;

  @override
  ConsumerState<PlayerGroupEditor> createState() => _PlayerGroupEditorState();
}

class _PlayerGroupEditorState extends ConsumerState<PlayerGroupEditor> {
  late final _name = TextEditingController(text: widget.group.name);
  final _newPlayer = TextEditingController();
  late final _players = List<String>.of(widget.group.players);
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    appLog('info', 'input', '打开球员分组输入框');
  }

  @override
  void dispose() {
    _name.dispose();
    _newPlayer.dispose();
    super.dispose();
  }

  bool _addPlayer() {
    final name = _newPlayer.text.trim();
    final error = name.isEmpty
        ? '球员名不能为空'
        : _players.contains(name)
        ? '分组内的球员不能重名'
        : null;
    setState(() {
      _error = error;
      if (error == null) {
        _players.add(name);
        _newPlayer.clear();
      }
    });
    return error == null;
  }

  Future<void> _save() async {
    if (_saving) return;
    // Do not silently discard a name typed just before clicking Save.
    if (_newPlayer.text.trim().isNotEmpty && !_addPlayer()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(playerGroupsProvider.notifier)
          .update(widget.group.name, name: _name.text, players: _players);
      if (mounted) Navigator.of(context).pop();
    } on PlayerGroupException catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final height = (MediaQuery.sizeOf(context).height * .55).clamp(
      240.0,
      480.0,
    );
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.md),
          side: BorderSide(color: c.borderStrong),
        ),
        title: Text(context.bheText('编辑球员分组')),
        content: SizedBox(
          width: 440,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('player-group-name'),
                controller: _name,
                enabled: !_saving,
                autofocus: true,
                decoration: InputDecoration(labelText: context.bheText('分组名称')),
              ),
              const SizedBox(height: Spacing.md),
              Text(
                context.bheText('拖动调整顺序，顺序对应球员快捷键（1–9、Q–P）。'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: Spacing.sm),
              Expanded(
                child: _players.isEmpty
                    ? Center(child: Text(context.bheText('还没有球员，请添加。')))
                    : ReorderableListView.builder(
                        key: const Key('player-group-players'),
                        buildDefaultDragHandles: false,
                        itemCount: _players.length,
                        onReorderItem: (oldIndex, newIndex) {
                          if (_saving) return;
                          setState(() {
                            final player = _players.removeAt(oldIndex);
                            _players.insert(newIndex, player);
                            _error = null;
                          });
                        },
                        itemBuilder: (context, index) {
                          final name = _players[index];
                          return ListTile(
                            key: ValueKey('group-editor-player-$name'),
                            contentPadding: EdgeInsets.zero,
                            leading: Text('${index + 1}'),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: ValueKey('group-editor-remove-$name'),
                                  tooltip: context.bheText('移除球员'),
                                  onPressed: _saving
                                      ? null
                                      : () => setState(() {
                                          _players.removeAt(index);
                                          _error = null;
                                        }),
                                  icon: const Icon(
                                    Icons.remove_circle_outline,
                                    size: 18,
                                  ),
                                ),
                                ReorderableDragStartListener(
                                  key: ValueKey('group-editor-drag-$name'),
                                  index: index,
                                  enabled: !_saving,
                                  child: Tooltip(
                                    message: context.bheText('拖动调整顺序'),
                                    child: const Padding(
                                      padding: EdgeInsets.all(Spacing.sm),
                                      child: Icon(Icons.drag_handle, size: 20),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('player-group-new-player'),
                      controller: _newPlayer,
                      enabled: !_saving,
                      decoration: InputDecoration(
                        labelText: context.bheText('球员姓名'),
                      ),
                      onSubmitted: _saving ? null : (_) => _addPlayer(),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  IconButton(
                    key: const Key('player-group-add-player'),
                    tooltip: context.bheText('添加球员'),
                    onPressed: _saving ? null : _addPlayer,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.sm),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.bheText(_error!),
                    style: TextStyle(color: c.error),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(context.bheText('取消')),
          ),
          FilledButton(
            key: const Key('player-group-save'),
            onPressed: _saving ? null : _save,
            child: Text(context.bheText('保存')),
          ),
        ],
      ),
    );
  }
}
