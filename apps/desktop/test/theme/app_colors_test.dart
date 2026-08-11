// test/theme/app_colors_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/theme/app_colors.dart';

void main() {
  test('dark brand colors match spec', () {
    expect(darkAppColors.indigo, const Color(0xFF5E6AD2));
    expect(darkAppColors.orange, const Color(0xFFFF6B2C));
    expect(darkAppColors.background, const Color(0xFF0B0E14));
    expect(darkAppColors.surface, const Color(0xFF121620));
  });
  test('semantic colors distinct', () {
    expect(darkAppColors.goal, const Color(0xFF3FB950));
    expect(darkAppColors.pending, const Color(0xFFE3B341));
    expect(darkAppColors.excluded, const Color(0xFF6B7280));
  });
  test('light orange darkened for contrast', () {
    expect(lightAppColors.orange, const Color(0xFFF2601D));
  });
  testWidgets('of(context) returns theme extension', (tester) async {
    late AppColors captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [darkAppColors]),
        home: Builder(
          builder: (c) {
            captured = AppColors.of(c);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(captured.indigo, darkAppColors.indigo);
  });
}
