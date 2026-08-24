// lib/theme/tokens.dart
abstract final class Spacing {
  static const double xs = 4, sm = 8, md = 16, lg = 24, xl = 32, xxl = 48;
}

abstract final class CsRadius {
  static const double xs = 4, sm = 6, md = 8, lg = 12, xl = 16, full = 999;
}

abstract final class DurationD {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
}

abstract final class Breakpoints {
  static const double sm = 640, md = 900, lg = 1280, xl = 1536;
}
