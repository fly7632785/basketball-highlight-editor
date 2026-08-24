// test/theme/app_theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/theme/app_colors.dart';

void main() {
  test('dark theme wires dark colors and typography', () {
    final t = appTheme(Brightness.dark);
    expect(t.brightness, Brightness.dark);
    expect(t.extensions[AppColors], darkAppColors);
    expect(t.textTheme.displayLarge?.fontWeight, FontWeight.w500);
  });
  test('numericTextStyle has tabular figures', () {
    final fs = numericTextStyle(const TextStyle());
    expect(fs.fontFeatures?.any((f) => f.feature == 'tnum'), isTrue);
  });
}
