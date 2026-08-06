// test/components/cs_button_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:desktop/components/cs_button.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/theme/app_colors.dart';

Widget _wrapped(Widget child) => MaterialApp(
  theme: appTheme(Brightness.dark),
  home: Center(child: child),
);

void main() {
  testWidgets('primary renders orange filled with label', (tester) async {
    await tester.pumpWidget(_wrapped(
      CsButton(variant: CsButtonVariant.primary, label: const Text('开始分析'), onPressed: () {}),
    ));
    final material = tester.widget<Material>(find.ancestor(of: find.text('开始分析'), matching: find.byType(Material)));
    expect((material.color as Paint).color, darkAppColors.orange);
  });
  testWidgets('disabled when onPressed null', (tester) async {
    await tester.pumpWidget(_wrapped(
      CsButton(variant: CsButtonVariant.primary, label: const Text('x'), onPressed: null),
    ));
    final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(btn.onPressed, isNull);
  });
  testWidgets('loading shows spinner instead of icon', (tester) async {
    await tester.pumpWidget(_wrapped(
      CsButton(variant: CsButtonVariant.primary, icon: LucideIcons.play,
        label: const Text('x'), onPressed: () {}, isLoading: true),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(LucideIcons.play), findsNothing);
  });
}
