// lib/providers/theme_provider.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式持久化。
///
/// `build()` 同步返回默认 `ThemeMode.dark`,随后异步读 SharedPreferences
/// 校正状态;`set(ThemeMode)` 写回 prefs 并更新 state。键名 `courtside.theme_mode`,
/// 值为 `ThemeMode.name`(system/light/dark)。
const String themeModePrefsKey = 'courtside.theme_mode';

Future<ThemeMode> loadSavedThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return _parseThemeMode(prefs.getString(themeModePrefsKey));
  } catch (_) {
    return ThemeMode.dark;
  }
}

ThemeMode _parseThemeMode(String? raw) {
  switch (raw) {
    case 'system':
      return ThemeMode.system;
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.dark;
  }
}

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static ThemeMode? startupMode;

  @override
  ThemeMode build() {
    final initialMode = startupMode ?? ThemeMode.dark;
    startupMode = null;
    _load();
    return initialMode;
  }

  Future<void> _load() async {
    final mode = await loadSavedThemeMode();
    if (mode != state) {
      state = mode;
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(themeModePrefsKey, mode.name);
    } catch (_) {
      // 持久化失败时仍保留本次 state(内存生效,下次启动回退默认)。
    }
  }
}

final NotifierProvider<ThemeModeNotifier, ThemeMode> themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
