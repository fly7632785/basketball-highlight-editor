import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/app_log.dart';

const String playerGroupsPrefsKey = 'bhe.player_groups';
const String defaultPlayerGroupPrefsKey = 'bhe.default_player_group';

typedef PlayerGroup = ({String name, List<String> players});

class PlayerGroupsNotifier extends Notifier<List<PlayerGroup>> {
  late Future<void> _ready;
  Future<void> _pending = Future<void>.value();
  String? _defaultGroupName;
  bool _disposed = false;

  Future<void> get ready => _ready;

  String? get defaultGroupName =>
      state.any((group) => group.name == _defaultGroupName)
      ? _defaultGroupName
      : null;

  @override
  List<PlayerGroup> build() {
    ref.onDispose(() => _disposed = true);
    _ready = _load();
    return const [];
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(playerGroupsPrefsKey);
      final groups = <PlayerGroup>[
        for (final item in raw == null ? [] : jsonDecode(raw) as List)
          (
            name: (item as Map)['name'].toString(),
            players: [for (final name in item['players'] as List) '$name'],
          ),
      ];
      if (_disposed) return;
      _defaultGroupName = prefs.getString(defaultPlayerGroupPrefsKey);
      state = groups;
      if (defaultGroupName == null) {
        _defaultGroupName = null;
        await prefs.remove(defaultPlayerGroupPrefsKey);
      }
    } catch (error) {
      appLog('warn', 'player_groups_provider', '_load 忽略了错误: $error');
      // 分组读取失败时按没有分组处理，不影响审核。
    }
  }

  Future<void> save(String name, List<String> players) => _change(() {
    name = name.trim();
    if (name.isEmpty) throw const PlayerGroupException('分组名不能为空');
    state = [
      for (final group in state)
        if (group.name != name) group,
      (name: name, players: List<String>.unmodifiable(players)),
    ];
  });

  Future<void> setDefault(String? name) => _change(() {
    _defaultGroupName = state.any((group) => group.name == name) ? name : null;
    state = [...state];
  });

  Future<void> update(
    String originalName, {
    required String name,
    required List<String> players,
  }) => _change(() {
    final nextName = name.trim();
    if (nextName.isEmpty) throw const PlayerGroupException('分组名不能为空');
    if (!state.any((group) => group.name == originalName)) {
      throw const PlayerGroupException('球员分组已不存在，请重新选择');
    }
    if (state.any(
      (group) => group.name != originalName && group.name == nextName,
    )) {
      throw const PlayerGroupException('分组名已存在，请使用其他名称');
    }
    final nextPlayers = <String>[];
    final seen = <String>{};
    for (final player in players) {
      final trimmed = player.trim();
      if (trimmed.isEmpty) throw const PlayerGroupException('球员名不能为空');
      if (!seen.add(trimmed)) throw const PlayerGroupException('分组内的球员不能重名');
      nextPlayers.add(trimmed);
    }
    // Move the default in the same in-memory transition as the rename.
    if (_defaultGroupName == originalName) _defaultGroupName = nextName;
    state = [
      for (final group in state)
        if (group.name == originalName)
          (name: nextName, players: List<String>.unmodifiable(nextPlayers))
        else
          group,
    ];
  });

  Future<void> delete(String name) => _change(() {
    if (_defaultGroupName == name) _defaultGroupName = null;
    state = [
      for (final group in state)
        if (group.name != name) group,
    ];
  });

  Future<void> _change(void Function() change) {
    final operation = _pending.then((_) async {
      await ready;
      if (_disposed) return;
      change();
      await _persist();
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        playerGroupsPrefsKey,
        jsonEncode([
          for (final group in state)
            {'name': group.name, 'players': group.players},
        ]),
      );
      final defaultName = defaultGroupName;
      if (defaultName == null) {
        await prefs.remove(defaultPlayerGroupPrefsKey);
      } else {
        await prefs.setString(defaultPlayerGroupPrefsKey, defaultName);
      }
    } catch (error) {
      appLog('warn', 'player_groups_provider', '_persist 忽略了错误: $error');
      // 持久化失败时本次运行仍可使用分组。
    }
  }
}

class PlayerGroupException implements Exception {
  const PlayerGroupException(this.message);
  final String message;

  @override
  String toString() => message;
}

final NotifierProvider<PlayerGroupsNotifier, List<PlayerGroup>>
playerGroupsProvider =
    NotifierProvider<PlayerGroupsNotifier, List<PlayerGroup>>(
      PlayerGroupsNotifier.new,
    );

final defaultPlayerGroupProvider = Provider<String?>((ref) {
  ref.watch(playerGroupsProvider);
  return ref.read(playerGroupsProvider.notifier).defaultGroupName;
});
