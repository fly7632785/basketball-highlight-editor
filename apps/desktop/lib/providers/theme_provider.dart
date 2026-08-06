// lib/providers/theme_provider.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式持久化。
///
/// `build()` 同步返回默认 `ThemeMode.system`,随后异步读 SharedPreferences
/// 校正状态;`set(ThemeMode)` 写回 prefs 并更新 state。键名 `courtside.theme_mode`,
/// 值为 `ThemeMode.name`(system/light/dark)。
class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const String _prefsKey = 'courtside.theme_mode';

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final mode = _parseThemeMode(raw);
      if (mode != null && mode != state) {
        state = mode;
      }
    } catch (_) {
      // 读取失败时保持默认 system。
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, mode.name);
    } catch (_) {
      // 持久化失败时仍保留本次 state(内存生效,下次启动回退默认)。
    }
  }

  static ThemeMode? _parseThemeMode(String? raw) {
    switch (raw) {
      case 'system':
        return ThemeMode.system;
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return null;
    }
  }
}

final NotifierProvider<ThemeModeNotifier, ThemeMode> themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
