// test/components/cs_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/components/cs_card.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/theme/app_colors.dart';

void main() {
  testWidgets('default tier uses surface color', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: CsCard(child: const Text('hi')),
    ));
    final ac = tester.widget<AnimatedContainer>(
      find.descendant(of: find.byType(CsCard), matching: find.byType(AnimatedContainer)),
    );
    expect((ac.decoration as BoxDecoration).color, darkAppColors.surface);
  });
  testWidgets('onTap wraps tappable + calls back', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: CsCard(onTap: () => taps++, child: const Text('tap')),
    ));
    await tester.tap(find.text('tap'));
    expect(taps, 1);
  });
  testWidgets('selected accent paints left bar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: CsCard(selectedAccent: true, child: const Text('sel')),
    ));
    expect(
      find.descendant(of: find.byType(CsCard), matching: find.byType(Container)),
      findsOneWidget,
    );
  });
}
