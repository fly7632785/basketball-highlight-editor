// test/theme/app_colors_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/theme/app_colors.dart';

void main() {
  test('dark colors match the editor workspace palette', () {
    expect(darkAppColors.indigo, const Color(0xFF4D9DFF));
    expect(darkAppColors.orange, const Color(0xFFFFA62B));
    expect(darkAppColors.background, const Color(0xFF0F1115));
    expect(darkAppColors.surface, const Color(0xFF181B21));
  });
  test('semantic colors distinct', () {
    expect(darkAppColors.goal, const Color(0xFF48C774));
    expect(darkAppColors.pending, const Color(0xFFF4C95D));
    expect(darkAppColors.excluded, const Color(0xFF8D96A5));
  });
  test('light palette preserves its orange accent', () {
    expect(lightAppColors.orange, const Color(0xFFFF9500));
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
