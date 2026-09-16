import 'dart:ui';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String bheLocalePrefsKey = 'bhe.locale';

class LocaleNotifier extends Notifier<Locale> {
  @override
  Locale build() {
    final systemLocale = PlatformDispatcher.instance.locale;
    _load();
    return BheLocale.fromSystem(systemLocale);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(bheLocalePrefsKey);
      if (saved != null) state = BheLocale.fromName(saved);
    } catch (_) {
      // 读取失败时保留系统语言，不影响应用启动。
    }
  }

  Future<void> set(Locale locale) async {
    final normalized = BheLocale.fromName(locale.toLanguageTag());
    state = normalized;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(bheLocalePrefsKey, normalized.toLanguageTag());
    } catch (_) {
      // 持久化失败时仍保留本次运行的语言选择。
    }
  }
}

final NotifierProvider<LocaleNotifier, Locale> appLocaleProvider =
    NotifierProvider<LocaleNotifier, Locale>(LocaleNotifier.new);
