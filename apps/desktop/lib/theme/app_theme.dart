// lib/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'tokens.dart';

ThemeData appTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? darkAppColors : lightAppColors;
  final scheme = ColorScheme.fromSeed(
    seedColor: colors.indigo,
    brightness: brightness,
    surface: colors.surface,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme.copyWith(
      primary: colors.indigo,
      onPrimary: Colors.white,
      secondary: colors.orange,
      onSecondary: Colors.white,
      surface: colors.surface,
      onSurface: colors.textPrimary,
    ),
    scaffoldBackgroundColor: colors.background,
    fontFamily: 'Inter',
    extensions: [colors],
  );
  return base.copyWith(
    textTheme: _buildTextTheme(colors),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .64),
      shadowColor: Colors.black.withValues(alpha: .28),
      elevation: 18,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: colors.borderStrong),
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: colors.textPrimary,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        height: 1.5,
        color: colors.textSecondary,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      iconColor: colors.indigo,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colors.indigo,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.sm),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CsRadius.sm),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.lg),
        side: BorderSide(color: colors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface3,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        borderSide: BorderSide(color: colors.indigo, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    ),
    dividerTheme: DividerThemeData(color: colors.border, thickness: 1),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surface3,
      labelStyle: TextStyle(
        color: colors.textPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.full),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.indigo.withValues(alpha: 0.15),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          color: colors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
  );
}

TextTheme _buildTextTheme(AppColors colors) => TextTheme(
  displayLarge: TextStyle(
    fontFamily: 'Inter',
    fontSize: 28,
    fontWeight: FontWeight.w500,
    height: 1.15,
    letterSpacing: -0.6,
    color: colors.textPrimary,
  ),
  displayMedium: TextStyle(
    fontFamily: 'Inter',
    fontSize: 22,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: -0.35,
    color: colors.textPrimary,
  ),
  titleLarge: TextStyle(
    fontFamily: 'Inter',
    fontSize: 18,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.15,
    color: colors.textPrimary,
  ),
  titleMedium: TextStyle(
    fontFamily: 'Inter',
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
  bodyLarge: TextStyle(
    fontFamily: 'Inter',
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: colors.textPrimary,
  ),
  bodyMedium: TextStyle(
    fontFamily: 'Inter',
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: colors.textPrimary,
  ),
  labelLarge: TextStyle(
    fontFamily: 'Inter',
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
  labelMedium: TextStyle(
    fontFamily: 'Inter',
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
  labelSmall: TextStyle(
    fontFamily: 'Inter',
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
);

TextStyle numericTextStyle(TextStyle base) =>
    base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
