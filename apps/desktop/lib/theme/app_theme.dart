// lib/theme/app_theme.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'tokens.dart';

ThemeData appTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? darkAppColors : lightAppColors;
  final fontFamily = switch (defaultTargetPlatform) {
    TargetPlatform.macOS => '.AppleSystemUIFont',
    _ => 'Inter',
  };
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
    fontFamily: fontFamily,
    extensions: [colors],
  );
  return base.copyWith(
    textTheme: _buildTextTheme(colors, fontFamily),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: colors.border.withValues(alpha: 0.75)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface2,
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    ),
    dividerTheme: DividerThemeData(color: colors.border, thickness: 1),
    iconTheme: IconThemeData(color: colors.textSecondary, size: 18),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(colors.textSecondary),
        overlayColor: WidgetStatePropertyAll(colors.surface3),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CsRadius.sm),
          ),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.xl),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface3,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.lg),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.surface3,
        borderRadius: BorderRadius.circular(CsRadius.sm),
      ),
      textStyle: TextStyle(color: colors.textPrimary, fontSize: 11),
      waitDuration: const Duration(milliseconds: 500),
    ),
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
      backgroundColor: colors.surface2,
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

TextTheme _buildTextTheme(AppColors colors, String fontFamily) => TextTheme(
  displayLarge: TextStyle(
    fontFamily: fontFamily,
    fontSize: 30,
    fontWeight: FontWeight.w600,
    height: 1.12,
    letterSpacing: -0.75,
    color: colors.textPrimary,
  ),
  displayMedium: TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.18,
    letterSpacing: -0.45,
    color: colors.textPrimary,
  ),
  titleLarge: TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.25,
    color: colors.textPrimary,
  ),
  titleMedium: TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
  bodyLarge: TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: colors.textPrimary,
  ),
  bodyMedium: TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: colors.textPrimary,
  ),
  labelLarge: TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
  labelMedium: TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
  labelSmall: TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: colors.textPrimary,
  ),
);

TextStyle numericTextStyle(TextStyle base) =>
    base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
