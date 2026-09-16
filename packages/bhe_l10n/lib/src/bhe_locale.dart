import 'package:flutter/material.dart';

class BheLocale {
  const BheLocale._();

  static const zh = Locale('zh', 'CN');
  static const en = Locale('en', 'US');
  static const supported = <Locale>[zh, en];

  static Locale fromSystem(Locale locale) {
    return locale.languageCode.toLowerCase() == 'zh' ? zh : en;
  }

  static Locale fromName(String? name) {
    return switch (name?.toLowerCase()) {
      'en' || 'en-us' => en,
      _ => zh,
    };
  }
}
