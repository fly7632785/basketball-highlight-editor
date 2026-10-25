import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String playerGroupsPrefsKey = 'bhe.player_groups';

typedef PlayerGroup = ({String name, List<String> players});

class PlayerGroupsNotifier extends Notifier<List<PlayerGroup>> {
  @override
  List<PlayerGroup> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(playerGroupsPrefsKey);
      if (raw == null) return;
      state = [
        for (final item in jsonDecode(raw) as List)
          (
            name: (item as Map)['name'].toString(),
            players: [for (final name in item['players'] as List) '$name'],
          ),
      ];
    } catch (_) {
      // 分组读取失败时按没有分组处理，不影响审核。
    }
  }

  Future<void> save(String name, List<String> players) async {
    state = [
      for (final group in state)
        if (group.name != name) group,
      (name: name, players: players),
    ];
    await _persist();
  }

  Future<void> delete(String name) async {
    state = [
      for (final group in state)
        if (group.name != name) group,
    ];
    await _persist();
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
    } catch (_) {
      // 持久化失败时本次运行仍可使用分组。
    }
  }
}

final NotifierProvider<PlayerGroupsNotifier, List<PlayerGroup>>
playerGroupsProvider =
    NotifierProvider<PlayerGroupsNotifier, List<PlayerGroup>>(
      PlayerGroupsNotifier.new,
    );
