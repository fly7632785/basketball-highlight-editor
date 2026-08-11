// test/components/cs_button_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:desktop/components/cs_button.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/theme/app_colors.dart';

Widget _wrapped(Widget child) => MaterialApp(
  theme: appTheme(Brightness.dark),
  home: Center(child: child),
);

void main() {
  testWidgets('primary renders system blue filled with label', (tester) async {
    await tester.pumpWidget(
      _wrapped(
        CsButton(
          variant: CsButtonVariant.primary,
          label: const Text('开始分析'),
          onPressed: () {},
        ),
      ),
    );
    final ac = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(CsButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((ac.decoration as BoxDecoration).color, darkAppColors.indigo);
    expect(find.text('开始分析'), findsOneWidget);
  });
  testWidgets('disabled when onPressed null', (tester) async {
    await tester.pumpWidget(
      _wrapped(
        CsButton(
          variant: CsButtonVariant.primary,
          label: const Text('x'),
          onPressed: null,
        ),
      ),
    );
    final gd = tester.widget<GestureDetector>(
      find.descendant(
        of: find.byType(CsButton),
        matching: find.byType(GestureDetector),
      ),
    );
    expect(gd.onTap, isNull);
  });
  testWidgets('loading shows spinner instead of icon', (tester) async {
    await tester.pumpWidget(
      _wrapped(
        CsButton(
          variant: CsButtonVariant.primary,
          icon: CupertinoIcons.play_fill,
          label: const Text('x'),
          onPressed: () {},
          isLoading: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.play_fill), findsNothing);
  });

  testWidgets('can be focused and activated with keyboard', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      _wrapped(
        CsButton(
          variant: CsButtonVariant.primary,
          label: const Text('开始分析'),
          onPressed: () => presses++,
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(presses, 1);
  });
}
