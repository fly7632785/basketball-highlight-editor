// lib/theme/app_colors.dart
import 'package:flutter/material.dart';

const darkAppColors = AppColors(
  background: Color(0xFF0B0E14), surface: Color(0xFF121620),
  surface2: Color(0xFF1A1F2B), surface3: Color(0xFF23242F),
  textPrimary: Color(0xFFE6E8EE), textSecondary: Color(0xFF9AA0AC), textTertiary: Color(0xFF6B7280),
  border: Color(0xFF23242F), borderStrong: Color(0xFF31343F),
  indigo: Color(0xFF5E6AD2), orange: Color(0xFFFF6B2C),
  goal: Color(0xFF3FB950), pending: Color(0xFFE3B341), excluded: Color(0xFF6B7280),
  success: Color(0xFF3FB950), error: Color(0xFFF85149), warning: Color(0xFFE3B341),
);

const lightAppColors = AppColors(
  background: Color(0xFFFAFAFA), surface: Color(0xFFFFFFFF),
  surface2: Color(0xFFF4F5F7), surface3: Color(0xFFE9EBEF),
  textPrimary: Color(0xFF15171C), textSecondary: Color(0xFF5A606B), textTertiary: Color(0xFF8B919B),
  border: Color(0xFFE5E7EB), borderStrong: Color(0xFFCBD0D8),
  indigo: Color(0xFF5E6AD2), orange: Color(0xFFF2601D),
  goal: Color(0xFF1F9E47), pending: Color(0xFFC28A1E), excluded: Color(0xFF71717A),
  success: Color(0xFF1F9E47), error: Color(0xFFDC2626), warning: Color(0xFFC28A1E),
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
    required this.background, required this.surface, required this.surface2, required this.surface3,
    required this.textPrimary, required this.textSecondary, required this.textTertiary,
    required this.border, required this.borderStrong,
    required this.indigo, required this.orange,
    required this.goal, required this.pending, required this.excluded,
    required this.success, required this.error, required this.warning,
  });

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? darkAppColors;

  @override
  AppColors copyWith({Color? background, Color? surface, Color? surface2, Color? surface3,
      Color? textPrimary, Color? textSecondary, Color? textTertiary,
      Color? border, Color? borderStrong, Color? indigo, Color? orange,
      Color? goal, Color? pending, Color? excluded,
      Color? success, Color? error, Color? warning}) =>
    AppColors(
      background: background ?? this.background, surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2, surface3: surface3 ?? this.surface3,
      textPrimary: textPrimary ?? this.textPrimary, textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary, border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong, indigo: indigo ?? this.indigo,
      orange: orange ?? this.orange, goal: goal ?? this.goal, pending: pending ?? this.pending,
      excluded: excluded ?? this.excluded, success: success ?? this.success,
      error: error ?? this.error, warning: warning ?? this.warning,
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
