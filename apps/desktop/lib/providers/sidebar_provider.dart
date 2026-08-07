import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 侧栏展开状态。
///
/// 首次使用默认展开；用户手动调整或点击“新建项目”后的状态会持久化，
/// 后续进入审核页时不再被路由自动覆盖。
class SidebarStateNotifier extends Notifier<bool> {
  static const String _prefsKey = 'courtside.sidebar_extended';

  bool _userChanged = false;

  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  void toggle() => _set(!state);

  void collapseForProjectCreation() => _set(false);

  void _set(bool extended) {
    _userChanged = true;
    state = extended;
    unawaited(_persist(extended));
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_userChanged) return;
      final value = prefs.getBool(_prefsKey);
      if (value != null) state = value;
    } catch (_) {
      // 读取失败时保持默认展开。
    }
  }

  Future<void> _persist(bool extended) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, extended);
    } catch (_) {
      // 持久化失败时仍保留本次内存状态。
    }
  }
}

final NotifierProvider<SidebarStateNotifier, bool> sidebarExtendedProvider =
    NotifierProvider<SidebarStateNotifier, bool>(SidebarStateNotifier.new);
