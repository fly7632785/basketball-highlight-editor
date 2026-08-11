// lib/theme/app_colors.dart
import 'package:flutter/material.dart';

const darkAppColors = AppColors(
  background: Color(0xFF0F1115),
  surface: Color(0xFF181B21),
  surface2: Color(0xFF20242C),
  surface3: Color(0xFF2B303A),
  textPrimary: Color(0xFFF2F4F7),
  textSecondary: Color(0xFFB4BAC4),
  textTertiary: Color(0xFF7E8796),
  border: Color(0xFF2A2F38),
  borderStrong: Color(0xFF3A4250),
  indigo: Color(0xFF4D9DFF),
  orange: Color(0xFFFFA62B),
  goal: Color(0xFF48C774),
  pending: Color(0xFFF4C95D),
  excluded: Color(0xFF8D96A5),
  success: Color(0xFF48C774),
  error: Color(0xFFFF6B6B),
  warning: Color(0xFFF4C95D),
);

const lightAppColors = AppColors(
  background: Color(0xFFF2F2F7),
  surface: Color(0xFFFFFFFF),
  surface2: Color(0xFFF2F2F7),
  surface3: Color(0xFFE5E5EA),
  textPrimary: Color(0xFF1C1C1E),
  textSecondary: Color(0xFF636366),
  textTertiary: Color(0xFF8E8E93),
  border: Color(0xFFD1D1D6),
  borderStrong: Color(0xFFC7C7CC),
  indigo: Color(0xFF007AFF),
  orange: Color(0xFFFF9500),
  goal: Color(0xFF34C759),
  pending: Color(0xFFFF9500),
  excluded: Color(0xFF8E8E93),
  success: Color(0xFF34C759),
  error: Color(0xFFFF3B30),
  warning: Color(0xFFFF9500),
);

@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Color background, surface, surface2, surface3;
  final Color textPrimary, textSecondary, textTertiary;
  final Color border, borderStrong;
  final Color indigo, orange;
  final Color goal, pending, excluded;
  final Color success, error, warning;

  const AppColors({
    required this.background,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.border,
    required this.borderStrong,
    required this.indigo,
    required this.orange,
    required this.goal,
    required this.pending,
    required this.excluded,
    required this.success,
    required this.error,
    required this.warning,
  });

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? darkAppColors;

  @override
  AppColors copyWith({
    Color? background,
    Color? surface,
    Color? surface2,
    Color? surface3,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? border,
    Color? borderStrong,
    Color? indigo,
    Color? orange,
    Color? goal,
    Color? pending,
    Color? excluded,
    Color? success,
    Color? error,
    Color? warning,
  }) => AppColors(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surface2: surface2 ?? this.surface2,
    surface3: surface3 ?? this.surface3,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    indigo: indigo ?? this.indigo,
    orange: orange ?? this.orange,
    goal: goal ?? this.goal,
    pending: pending ?? this.pending,
    excluded: excluded ?? this.excluded,
    success: success ?? this.success,
    error: error ?? this.error,
    warning: warning ?? this.warning,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      indigo: Color.lerp(indigo, other.indigo, t)!,
      orange: Color.lerp(orange, other.orange, t)!,
      goal: Color.lerp(goal, other.goal, t)!,
      pending: Color.lerp(pending, other.pending, t)!,
      excluded: Color.lerp(excluded, other.excluded, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}
