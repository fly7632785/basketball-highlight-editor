// lib/theme/tokens.dart
abstract final class Spacing {
  static const double xs = 4, sm = 8, md = 16, lg = 24, xl = 32, xxl = 48;
}

abstract final class CsRadius {
  static const double xs = 4, sm = 8, md = 12, lg = 16, xl = 20, full = 999;
}

abstract final class DurationD {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
}

abstract final class Breakpoints {
  static const double sm = 640, md = 900, lg = 1180, xl = 1536;
}

abstract final class WorkspaceMetrics {
  static const double sidebarCollapsed = 60;
  static const double sidebarExpanded = 220;
  static const double globalBarHeight = 40;
  static const double pageBarHeight = 52;
  static const double inspectorWidth = 320;
}
