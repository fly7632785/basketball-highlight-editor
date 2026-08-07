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
    textTheme: _buildTextTheme(),
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
      labelStyle: TextStyle(color: colors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CsRadius.full)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.indigo.withValues(alpha: 0.15),
      labelTextStyle: WidgetStatePropertyAll(TextStyle(
        color: colors.textSecondary, fontSize: 11, fontWeight: FontWeight.w500,
      )),
    ),
  );
}

TextTheme _buildTextTheme() => const TextTheme(
  displayLarge:  TextStyle(fontFamily: 'Inter', fontSize: 32, fontWeight: FontWeight.w600, height: 1.15, letterSpacing: -0.8),
  displayMedium: TextStyle(fontFamily: 'Inter', fontSize: 24, fontWeight: FontWeight.w600, height: 1.2, letterSpacing: -0.5),
  titleLarge:    TextStyle(fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.2),
  titleMedium:   TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w600),
  bodyLarge:     TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w400, height: 1.5),
  bodyMedium:    TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.w400, height: 1.5),
  labelLarge:    TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.w500),
  labelMedium:   TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w500),
  labelSmall:    TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w500),
);

TextStyle numericTextStyle(TextStyle base) =>
    base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
