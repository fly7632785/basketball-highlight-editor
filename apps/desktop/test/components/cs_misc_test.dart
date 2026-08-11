// test/components/cs_misc_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/cupertino.dart';
import 'package:desktop/components/cs_empty_state.dart';
import 'package:desktop/components/cs_skeleton.dart';
import 'package:desktop/components/cs_progress_track.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('empty state renders title and action', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const CsEmptyState(
          icon: CupertinoIcons.tray,
          title: '空',
          description: '没数据',
        ),
      ),
    );
    expect(find.text('空'), findsOneWidget);
    expect(find.text('没数据'), findsOneWidget);
  });
  testWidgets('skeleton renders a box', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const CsSkeleton(width: 100, height: 20),
      ),
    );
    expect(find.byType(CsSkeleton), findsOneWidget);
  });
  testWidgets('progress track determinate shows value', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const CsProgressTrack(value: 0.5),
      ),
    );
    final linear = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(linear.value, 0.5);
  });
}
