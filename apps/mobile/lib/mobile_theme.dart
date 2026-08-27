// lib/mobile_theme.dart
// Theme constants and the bheTheme builder, extracted from mobile_ui.dart
// for maintainability. This file has no private class dependencies.

import 'package:flutter/material.dart';

abstract final class BhePalette {
  static const background = Color(0xFF0B0E14);
  static const surface = Color(0xFF121620);
  static const surface2 = Color(0xFF1A1F2B);
  static const surface3 = Color(0xFF23242F);
  static const text = Color(0xFFE6E8EE);
  static const textSecondary = Color(0xFF9AA0AC);
  static const textTertiary = Color(0xFF6B7280);
  static const border = Color(0xFF23242F);
  static const borderStrong = Color(0xFF31343F);
  static const orange = Color(0xFFFF6B2C);
  static const gold = Color(0xFFF0B35A);
  static const green = Color(0xFF3FB950);
  static const warning = Color(0xFFE3B341);
  static const error = Color(0xFFF85149);
}

ThemeData bheTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: BhePalette.orange,
        brightness: brightness,
        surface: dark ? BhePalette.surface : const Color(0xFFFFFFFF),
      ).copyWith(
        primary: dark ? BhePalette.orange : const Color(0xFFF2601D),
        onPrimary: Colors.white,
        secondary: dark ? BhePalette.gold : const Color(0xFFA86418),
        surface: dark ? BhePalette.surface : const Color(0xFFFFFFFF),
        onSurface: dark ? BhePalette.text : const Color(0xFF15171C),
        error: dark ? BhePalette.error : const Color(0xFFDC2626),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? BhePalette.background
        : const Color(0xFFFAFAFA),
    fontFamily: 'Inter',
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? BhePalette.background : const Color(0xFFFAFAFA),
      foregroundColor: dark ? BhePalette.text : const Color(0xFF15171C),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: dark ? BhePalette.surface : Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? BhePalette.surface : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: dark ? BhePalette.borderStrong : const Color(0xFFE5E7EB),
        ),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: dark ? BhePalette.orange : const Color(0xFFF2601D),
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: dark ? BhePalette.text : const Color(0xFF15171C),
        minimumSize: const Size(44, 44),
        side: BorderSide(
          color: dark ? BhePalette.borderStrong : const Color(0xFFCBD0D8),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: dark
            ? BhePalette.textSecondary
            : const Color(0xFF5A606B),
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? BhePalette.surface3 : const Color(0xFFF4F5F7),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(
          color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(
          color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(
          color: dark ? BhePalette.orange : const Color(0xFFF2601D),
          width: 1.5,
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? BhePalette.surface : Colors.white,
      indicatorColor: (dark ? BhePalette.orange : const Color(0xFFF2601D))
          .withValues(alpha: .16),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          color: dark ? BhePalette.textSecondary : const Color(0xFF5A606B),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? BhePalette.border : const Color(0xFFE5E7EB),
      thickness: 1,
      space: 1,
    ),
    textTheme: TextTheme(
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      headlineSmall: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      titleLarge: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      bodyLarge: TextStyle(
        fontSize: 14,
        height: 1.5,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        height: 1.45,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.45,
        color: dark ? BhePalette.textSecondary : const Color(0xFF5A606B),
      ),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.text : const Color(0xFF15171C),
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: dark ? BhePalette.textSecondary : const Color(0xFF5A606B),
      ),
    ),
  );
}
